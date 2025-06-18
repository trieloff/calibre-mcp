#!/bin/bash

# Calibre MCP Server
# A bash-based MCP server for searching and reading Calibre ebook library

set -euo pipefail

# Configuration
CALIBRE_LIBRARY="$HOME/Calibre Library"
CALIBREDB="/Applications/calibre.app/Contents/MacOS/calibredb"
LOG_FILE="/tmp/calibre-mcp-requests.log"

# Ensure log file exists
touch "$LOG_FILE"

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Send JSON-RPC response
send_response() {
    local response="$1"
    echo "$response"
    log "Response: $response"
}

# Error response
error_response() {
    local id="$1"
    local code="$2"
    local message="$3"
    local response
    response=$(jq -cn --argjson id "$id" --argjson code "$code" --arg message "$message" '{
        jsonrpc: "2.0",
        id: $id,
        error: {
            code: $code,
            message: $message
        }
    }')
    send_response "$response"
}

# Success response
success_response() {
    local id="$1"
    local result="$2"
    local response
    response=$(jq -cn --argjson id "$id" --argjson result "$result" '{
        jsonrpc: "2.0",
        id: $id,
        result: $result
    }')
    send_response "$response"
}

# Run command with timeout
run_with_timeout() {
    local timeout_seconds="$1"
    shift
    local cmd=("$@")
    
    # Run command in background
    "${cmd[@]}" &
    local pid=$!
    
    # Wait for command or timeout
    local count=0
    while kill -0 $pid 2>/dev/null; do
        if [[ $count -ge $timeout_seconds ]]; then
            kill -TERM $pid 2>/dev/null
            wait $pid 2>/dev/null
            return 124  # timeout exit code
        fi
        sleep 1
        ((count++))
    done
    
    # Get exit status
    wait $pid
    return $?
}

# Parse epub URL: epub://author/title@id#start:end
parse_epub_url() {
    local url="$1"
    
    # Remove epub:// prefix
    url="${url#epub://}"
    
    # Extract book ID (required)
    if [[ "$url" =~ @([0-9]+) ]]; then
        BOOK_ID="${BASH_REMATCH[1]}"
    else
        return 1
    fi
    
    # Extract line range (optional)
    if [[ "$url" =~ \#([0-9]+):([0-9]+)$ ]]; then
        START_LINE="${BASH_REMATCH[1]}"
        END_LINE="${BASH_REMATCH[2]}"
    else
        START_LINE=""
        END_LINE=""
    fi
    
    # Extract author/title (for validation/display)
    local author_title_part="${url%%@*}"
    AUTHOR_TITLE="$(printf '%s' "$author_title_part" | jq -rR @uri | sed 's/%2F/\//g')"
    
    return 0
}

# Create epub URL from book data and line numbers
create_epub_url() {
    local author="$1" title="$2" id="$3" start="$4" end="$5"
    local enc_author enc_title
    enc_author=$(printf '%s' "$author" | jq -rR @uri)
    enc_title=$(printf '%s' "$title" | jq -rR @uri)
    
    local url="epub://${enc_author}/${enc_title}@${id}"
    if [[ -n "$start" && -n "$end" ]]; then
        url="${url}#${start}:${end}"
    fi
    echo "$url"
}

# Extract paragraphs with context around line number
extract_paragraph_context() {
    local file_path="$1"
    local target_line="$2"
    local context_paragraphs="${3:-3}"
    
    if [[ ! -f "$file_path" ]]; then
        echo "File not found: $file_path" >&2
        return 1
    fi
    
    # Find paragraph boundaries (blank lines)
    local temp_paragraphs=$(mktemp)
    awk 'BEGIN { para=1; line=1 } 
         /^$/ { para++; line++; next }
         { print line ":" para ":" $0; line++ }' "$file_path" > "$temp_paragraphs"
    
    # Find which paragraph contains target line
    local target_para
    target_para=$(awk -F: -v target="$target_line" '$1 == target { print $2; exit }' "$temp_paragraphs")
    
    if [[ -z "$target_para" ]]; then
        rm -f "$temp_paragraphs"
        echo "Line $target_line not found" >&2
        return 1
    fi
    
    # Extract context paragraphs
    local start_para end_para
    start_para=$((target_para - context_paragraphs))
    end_para=$((target_para + context_paragraphs))
    
    if [[ $start_para -lt 1 ]]; then
        start_para=1
    fi
    
    # Get lines for the paragraph range
    awk -F: -v start="$start_para" -v end="$end_para" \
        '$2 >= start && $2 <= end { print $1 ":" $3 }' "$temp_paragraphs" | \
        sort -n | cut -d: -f2-
    
    rm -f "$temp_paragraphs"
}

# Parse query into metadata filters and content terms
parse_hybrid_query() {
    local query="$1"
    
    # Extract metadata filters (field:value patterns)
    METADATA_FILTERS=""
    CONTENT_TERMS=""
    
    # Split query into parts and identify field:value patterns
    local remaining_terms=()
    local words
    read -ra words <<< "$query"
    
    for word in "${words[@]}"; do
        if [[ "$word" =~ ^(author|title|tag|series|publisher|format|date|pubdate|rating|comments|identifiers): ]]; then
            # This is a metadata filter
            if [[ -n "$METADATA_FILTERS" ]]; then
                METADATA_FILTERS="$METADATA_FILTERS $word"
            else
                METADATA_FILTERS="$word"
            fi
        else
            # This is a content term
            remaining_terms+=("$word")
        fi
    done
    
    # Join remaining terms for content search
    if [[ ${#remaining_terms[@]} -gt 0 ]]; then
        CONTENT_TERMS="${remaining_terms[*]}"
    fi
    
    # Return 0 if hybrid, 1 if metadata-only, 2 if content-only
    if [[ -n "$METADATA_FILTERS" && -n "$CONTENT_TERMS" ]]; then
        return 0  # hybrid
    elif [[ -n "$METADATA_FILTERS" ]]; then
        return 1  # metadata-only
    else
        return 2  # content-only
    fi
}

# Detect if query uses advanced search syntax
is_advanced_query() {
    local query="$1"
    parse_hybrid_query "$query"
    local result=$?
    [[ $result -eq 1 ]]  # metadata-only
}

# Hybrid search: filter by metadata then search content
search_books_hybrid() {
    local metadata_filters="$1"
    local content_terms="$2"
    local limit="${3:-50}"
    
    log "Hybrid search: metadata='$metadata_filters' content='$content_terms'"
    
    # First, get books matching metadata filters
    local filtered_books
    filtered_books=$(search_books_metadata "$metadata_filters" 999)  # Get all matching books
    
    if [[ $(echo "$filtered_books" | jq length) -eq 0 ]]; then
        echo "[]"
        return
    fi
    
    # Extract book IDs and create lookup
    local book_ids
    book_ids=$(echo "$filtered_books" | jq -r '.[].id' | tr '\n' ',' | sed 's/,$//')
    
    # Now search content within these specific books
    local results_file=$(mktemp)
    local match_count=0
    
    # Calculate balanced limits for hybrid search too
    local sqrt_limit
    sqrt_limit=$(awk -v limit="$limit" 'BEGIN { print int(sqrt(limit) + 0.5) }')
    
    # Process each filtered book
    while IFS= read -r book_data && [[ $match_count -lt $limit ]]; do
        local book_id title authors
        book_id=$(echo "$book_data" | jq -r '.id')
        title=$(echo "$book_data" | jq -r '.title')
        authors=$(echo "$book_data" | jq -r '.authors')
        
        # Get text file path from full_formats
        local txt_path
        txt_path=$(echo "$book_data" | jq -r '.full_formats[]? | select(endswith(".txt"))' 2>/dev/null || echo "")
        
        if [[ -n "$txt_path" && -f "$txt_path" ]]; then
            # Search for content term matches in this specific book (up to sqrt_limit per book)
            local book_matches=0
            while IFS= read -r match_line && [[ $match_count -lt $limit ]] && [[ $book_matches -lt $sqrt_limit ]]; do
                if [[ -n "$match_line" ]]; then
                    local line_num match_text
                    line_num=$(echo "$match_line" | cut -d: -f1)
                    match_text=$(echo "$match_line" | cut -d: -f2-)
                    
                    # Calculate broader context line range for URL (5 lines before/after)
                    local context_start context_end
                    context_start=$((line_num - 5))
                    context_end=$((line_num + 5))
                    if [[ $context_start -lt 1 ]]; then context_start=1; fi
                    
                    # Create epub URL with broader context range
                    local epub_url
                    epub_url=$(create_epub_url "$authors" "$title" "$book_id" "$context_start" "$context_end")
                    
                    # Output result with just the matching line
                    jq -cn --arg id "$book_id" --arg title "$title" --arg authors "$authors" \
                          --arg text "$match_text" --arg url "$epub_url" --argjson line "$line_num" '{
                        id: $id,
                        title: $title,
                        authors: $authors,
                        text: $text,
                        url: $url,
                        line_number: $line
                    }' >> "$results_file"
                    
                    ((match_count++))
                    ((book_matches++))
                fi
            done < <(grep -i -n "$content_terms" "$txt_path" 2>/dev/null | head -n "$sqrt_limit")
        fi
    done < <(echo "$filtered_books" | jq -c '.[]')
    
    # Combine results
    local final_results="[]"
    if [[ -s "$results_file" ]]; then
        final_results=$(jq -s '.' < "$results_file")
    fi
    
    rm -f "$results_file"
    echo "$final_results"
}

# Search books using calibredb metadata search
search_books_metadata() {
    local query="$1"
    local limit="${2:-50}"
    
    # Get book IDs from search with timeout
    local book_ids
    local temp_file=$(mktemp)
    
    # Run search command with timeout
    if run_with_timeout 10 "$CALIBREDB" search --library-path="$CALIBRE_LIBRARY" --limit="$limit" "$query" > "$temp_file" 2>&1; then
        book_ids=$(cat "$temp_file" | grep -v "Another calibre program" || echo "")
    else
        log "Metadata search timed out or failed"
        book_ids=""
    fi
    rm -f "$temp_file"
    
    if [[ -z "$book_ids" ]]; then
        echo "[]"
        return
    fi
    
    # Convert comma-separated IDs to search query
    local id_query="id:${book_ids//,/ OR id:}"
    
    # Get detailed metadata for found books
    local books_json
    temp_file=$(mktemp)
    
    if run_with_timeout 10 "$CALIBREDB" list --library-path="$CALIBRE_LIBRARY" --fields=id,title,authors,series,tags,publisher,pubdate,formats,identifiers,comments --for-machine --search="$id_query" > "$temp_file" 2>&1; then
        books_json=$(cat "$temp_file" | grep -v "Another calibre program" || echo "[]")
    else
        log "List timed out or failed"
        books_json="[]"
    fi
    rm -f "$temp_file"
    
    # Process each book to add epub URLs
    echo "$books_json" | jq '[.[] | {
        id: .id,
        title: .title,
        authors: .authors,
        series: .series,
        tags: .tags,
        publisher: .publisher,
        published: .pubdate,
        epub_url: ("epub://" + (.authors | @uri) + "/" + (.title | @uri) + "@" + (.id | tostring)),
        formats: [.formats[] | split("/")[-1]],
        full_formats: .formats,
        has_text: ([.formats[] | select(endswith(".txt"))] | length > 0),
        description: (.comments | if . then (. | gsub("<[^>]+>"; "") | split("\n")[0:2] | join(" ") | .[0:200] + "...") else null end)
    }]'
}

# Search books using calibredb fts_search (full-text search)
search_books_fulltext() {
    local query="$1"
    local limit="${2:-50}"
    local fuzzy_query="${3:-}"
    
    log "Starting fulltext search for: $query"
    
    # Run FTS search without timeout to avoid cropped JSON
    local fts_results
    local temp_file=$(mktemp)
    
    if "$CALIBREDB" fts_search --library-path="$CALIBRE_LIBRARY" --output-format=json --do-not-match-on-related-words "$query" > "$temp_file" 2>&1; then
        fts_results=$(cat "$temp_file" | grep -v "Another calibre program" | jq '.[0:20]' || echo "[]")
    else
        log "FTS search failed"
        fts_results="[]"
    fi
    rm -f "$temp_file"
    
    if [[ $(echo "$fts_results" | jq length) -eq 0 ]]; then
        log "No FTS results found"
        echo "[]"
        return
    fi
    
    log "Found $(echo "$fts_results" | jq length) FTS results"
    
    # Calculate balanced limits: sqrt of limit for both books and matches per book
    local sqrt_limit
    sqrt_limit=$(awk -v limit="$limit" 'BEGIN { print int(sqrt(limit) + 0.5) }')
    
    # Get unique book IDs (limit based on sqrt)
    local unique_books
    unique_books=$(echo "$fts_results" | jq -r --argjson max "$sqrt_limit" '[.[].book_id] | unique[0:$max]')
    
    # Get book metadata with full formats
    local book_ids_query
    book_ids_query=$(echo "$unique_books" | jq -r 'join(" OR id:")')
    local id_query="id:$book_ids_query"
    
    local books_json
    temp_file=$(mktemp)
    if "$CALIBREDB" list --library-path="$CALIBRE_LIBRARY" --fields=id,title,authors,formats --for-machine --search="$id_query" > "$temp_file" 2>&1; then
        books_json=$(cat "$temp_file" | grep -v "Another calibre program" || echo "[]")
    else
        log "Failed to get book metadata"
        books_json="[]"
    fi
    rm -f "$temp_file"
    
    log "Got metadata for $(echo "$books_json" | jq length) books"
    
    # Now search for actual content in text files
    local results_file=$(mktemp)
    local match_count=0
    
    # Convert space-separated query into regex pattern for OR matching
    local grep_pattern
    grep_pattern=$(echo "$query" | sed 's/ /|/g')
    
    # Process each book to find actual matches
    while IFS= read -r book_data && [[ $match_count -lt $limit ]]; do
        local book_id title authors
        book_id=$(echo "$book_data" | jq -r '.id')
        title=$(echo "$book_data" | jq -r '.title')
        authors=$(echo "$book_data" | jq -r '.authors')
        
        # Get text file path
        local txt_path
        txt_path=$(echo "$book_data" | jq -r '.formats[]? | select(endswith(".txt"))' 2>/dev/null || echo "")
        
        if [[ -n "$txt_path" && -f "$txt_path" ]]; then
            # Search for content matches in this book (up to sqrt_limit per book)
            local book_matches=0
            while IFS= read -r match_line && [[ $match_count -lt $limit ]] && [[ $book_matches -lt $sqrt_limit ]]; do
                if [[ -n "$match_line" ]]; then
                    local line_num match_text
                    line_num=$(echo "$match_line" | cut -d: -f1)
                    match_text=$(echo "$match_line" | cut -d: -f2-)
                    
                    # Calculate broader context line range for URL (5 lines before/after)
                    local context_start context_end
                    context_start=$((line_num - 5))
                    context_end=$((line_num + 5))
                    if [[ $context_start -lt 1 ]]; then context_start=1; fi
                    
                    # Create epub URL with broader context range
                    local epub_url
                    epub_url=$(create_epub_url "$authors" "$title" "$book_id" "$context_start" "$context_end")
                    
                    # Output result with the matching line
                    jq -cn --arg id "$book_id" --arg title "$title" --arg authors "$authors" \
                          --arg text "$match_text" --arg url "$epub_url" --argjson line "$line_num" '{
                        id: $id,
                        title: $title,
                        authors: $authors,
                        text: $text,
                        url: $url,
                        line_number: $line
                    }' >> "$results_file"
                    
                    ((match_count++))
                    ((book_matches++))
                fi
            done < <(grep -E -i -n "$grep_pattern" "$txt_path" 2>/dev/null | head -n "$sqrt_limit")
        fi
    done < <(echo "$books_json" | jq -c '.[]')
    
    # Combine results
    local final_results="[]"
    if [[ -s "$results_file" ]]; then
        final_results=$(jq -s '.' < "$results_file")
    fi
    
    rm -f "$results_file"
    log "Created $(echo "$final_results" | jq length) final results"
    echo "$final_results"
}

# Unified search function
search_unified() {
    local query="$1"
    local limit="${2:-50}"
    local fuzzy_query="${3:-}"
    
    # Parse query to determine search type
    local METADATA_FILTERS CONTENT_TERMS
    parse_hybrid_query "$query"
    local search_type=$?
    
    case $search_type in
        0)  # hybrid search
            log "Using hybrid search for: metadata='$METADATA_FILTERS' content='$CONTENT_TERMS'"
            search_books_hybrid "$METADATA_FILTERS" "$CONTENT_TERMS" "$limit"
            ;;
        1)  # metadata-only
            log "Using metadata search for: $query"
            search_books_metadata "$query" "$limit"
            ;;
        2)  # content-only
            log "Using full-text search for: $query"
            search_books_fulltext "$query" "$limit" "$fuzzy_query"
            ;;
    esac
}

# Fetch content using epub URL scheme
fetch_by_epub_url() {
    local url="$1"
    
    # Parse epub URL
    local BOOK_ID START_LINE END_LINE AUTHOR_TITLE
    if ! parse_epub_url "$url"; then
        echo '{"error": "Invalid epub URL format. Expected: epub://author/title@id#start:end"}'
        return 1
    fi
    
    # Get book metadata
    local book_json
    local temp_file=$(mktemp)
    
    if run_with_timeout 10 "$CALIBREDB" list --library-path="$CALIBRE_LIBRARY" --fields=id,title,authors,formats --for-machine --search="id:$BOOK_ID" > "$temp_file" 2>&1; then
        book_json=$(cat "$temp_file" | grep -v "Another calibre program" || echo "[]")
    else
        log "Get book metadata timed out or failed"
        echo '{"error": "Failed to fetch book metadata"}'
        rm -f "$temp_file"
        return 1
    fi
    rm -f "$temp_file"
    
    if [[ $(echo "$book_json" | jq length) -eq 0 ]]; then
        echo '{"error": "Book not found"}'
        return 1
    fi
    
    # Extract text file path
    local txt_path
    txt_path=$(echo "$book_json" | jq -r '.[0].formats[]? | select(endswith(".txt"))' 2>/dev/null || echo "")
    
    if [[ -z "$txt_path" ]] || [[ ! -f "$txt_path" ]]; then
        echo '{"error": "No text format available for this book"}'
        return 1
    fi
    
    # Get book info
    local title authors
    title=$(echo "$book_json" | jq -r '.[0].title // "Unknown"')
    authors=$(echo "$book_json" | jq -r '.[0].authors // "Unknown"')
    
    # Extract content based on line range
    local content
    if [[ -n "$START_LINE" && -n "$END_LINE" ]]; then
        # Extract specific line range
        content=$(sed -n "${START_LINE},${END_LINE}p" "$txt_path" 2>/dev/null || echo "")
        if [[ -z "$content" ]]; then
            echo '{"error": "No content found in specified line range"}'
            return 1
        fi
    else
        # Extract first few paragraphs if no range specified
        content=$(extract_paragraph_context "$txt_path" 1 5 2>/dev/null || head -n 50 "$txt_path" 2>/dev/null || echo "")
    fi
    
    # Create response
    jq -cn --argjson id "$BOOK_ID" --arg title "$title" --arg authors "$authors" \
           --arg content "$content" --arg url "$url" \
           --arg start "${START_LINE:-}" --arg end "${END_LINE:-}" '{
        book_id: $id,
        title: $title,
        authors: $authors,
        content: $content,
        url: $url,
        line_range: {
            start: ($start | if . == "" then null else tonumber end),
            end: ($end | if . == "" then null else tonumber end)
        }
    }'
}

# Initialize response
handle_initialize() {
    local id="$1"
    local response
    response=$(jq -cn '{
        protocolVersion: "2024-11-05",
        serverInfo: {
            name: "calibre-mcp",
            version: "2.0.0",
            description: "Calibre ebook library search and content access server. Provides full-text search across your personal ebook collection with precise content retrieval."
        },
        capabilities: {
            tools: {},
            resources: {},
            prompts: {}
        }
    }')
    success_response "$id" "$response"
}

# List available tools
handle_tools_list() {
    local id="$1"
    local tools
    tools=$(jq -cn '[
        {
            name: "search",
            description: "Search the Calibre ebook library. Supports both full-text content search (default) and metadata search using field syntax. Returns results with epub:// URLs for precise content access. Results are distributed across books using square root of limit (e.g., limit=25 returns up to 5 matches from 5 different books). WARNING: Full-text returns actual matching lines - set limit appropriately to manage tokens.",
            inputSchema: {
                type: "object",
                properties: {
                    query: {
                        type: "string",
                        description: "Search query. For full-text: use natural language (\"machine learning\"). For metadata: use field syntax (author:Asimov, title:\"Foundation\", tag:fiction). Supports boolean operators (and, or, not) and wildcards."
                    },
                    limit: {
                        type: "integer",
                        description: "Maximum number of results (default: 50). Uses square root distribution: sqrt(limit) books × sqrt(limit) matches per book. Examples: limit=9 returns 3 books×3 matches, limit=25 returns 5×5, limit=100 returns 10×10. Keep low for full-text to manage tokens.",
                        default: 50
                    },
                    fuzzy_fallback: {
                        type: "string",
                        description: "Alternative search terms if exact query fails. Use related keywords separated by spaces."
                    }
                },
                required: ["query"]
            },
            outputSchema: {
                type: "object",
                properties: {
                    content: {
                        type: "array",
                        items: {
                            type: "object",
                            properties: {
                                type: { type: "string" },
                                text: { type: "string" }
                            }
                        }
                    },
                    results: {
                        type: "array",
                        items: {
                            type: "object",
                            properties: {
                                id: { type: "string" },
                                title: { type: "string" },
                                text: { type: "string" },
                                url: { type: "string" }
                            }
                        }
                    }
                }
            }
        },
        {
            name: "fetch",
            description: "Fetch specific content from a book using epub:// URL. Can retrieve exact line ranges or book sections. Use URLs from search results for precise content access.",
            inputSchema: {
                type: "object",
                properties: {
                    url: {
                        type: "string",
                        description: "epub:// URL from search results. Format: epub://author/title@bookid#startline:endline. Line range is optional."
                    }
                },
                required: ["url"]
            },
            outputSchema: {
                type: "object",
                properties: {
                    content: {
                        type: "array",
                        items: {
                            type: "object",
                            properties: {
                                type: { type: "string" },
                                text: { type: "string" }
                            }
                        }
                    },
                    book_id: { type: "integer" },
                    title: { type: "string" },
                    authors: { type: "string" },
                    url: { type: "string" }
                }
            }
        }
    ]')
    
    success_response "$id" "{ \"tools\": $tools }"
}

# Format dual response for cross-client compatibility
format_dual_response() {
    local search_results="$1"
    local query="$2"
    local search_type="${3:-search}"
    
    local count
    count=$(echo "$search_results" | jq length)
    
    if [[ "$count" -eq 0 ]]; then
        # No results
        jq -cn --arg query "$query" '{
            content: [
                {
                    type: "text",
                    text: ("No results found for: " + $query)
                }
            ],
            results: []
        }'
        return
    fi
    
    # Format content for Claude (readable text)
    local content_text
    if [[ "$search_type" == "fulltext" || "$search_type" == "hybrid" ]]; then
        content_text="Found $count content match(es) for '$query':\n\n$(echo "$search_results" | jq -r '.[] | "• " + .title + " by " + .authors + "\n  Match: " + (.text[0:150] // .text) + "...\n  URL: " + .url + "\n"')"
    else
        content_text="Found $count book(s) matching '$query':\n\n$(echo "$search_results" | jq -r '.[] | "• " + .title + " by " + .authors + "\n  URL: " + (.epub_url // ("epub://" + (.authors | @uri) + "/" + (.title | @uri) + "@" + (.id | tostring))) + "\n  " + (if .description then "Description: " + .description else "" end) + "\n"')"
    fi
    
    # Format results for OpenAI (structured data)
    local openai_results
    if [[ "$search_type" == "fulltext" || "$search_type" == "hybrid" ]]; then
        openai_results=$(echo "$search_results" | jq '[.[] | {
            id: (.id | tostring),
            title: .title,
            text: .text,
            url: .url
        }]')
    else
        openai_results=$(echo "$search_results" | jq '[.[] | {
            id: (.id | tostring),
            title: .title,
            text: (.description // (.title + " by " + .authors)),
            url: (.epub_url // ("epub://" + (.authors | @uri) + "/" + (.title | @uri) + "@" + (.id | tostring)))
        }]')
    fi
    
    # Combine both formats
    jq -cn --arg text "$content_text" --argjson results "$openai_results" '{
        content: [
            {
                type: "text",
                text: $text
            }
        ],
        results: $results
    }'
}

# Handle tool calls
handle_tools_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"
    
    case "$tool_name" in
        "search")
            local query limit fuzzy_fallback
            query=$(echo "$arguments" | jq -r '.query // empty')
            limit=$(echo "$arguments" | jq -r '.limit // 50')
            fuzzy_fallback=$(echo "$arguments" | jq -r '.fuzzy_fallback // empty')
            
            if [[ -z "$query" ]]; then
                error_response "$id" -32602 "Missing required parameter: query"
                return
            fi
            
            # Use unified search
            local results search_type
            results=$(search_unified "$query" "$limit" "$fuzzy_fallback")
            
            # Determine search type for response formatting
            local TEMP_METADATA_FILTERS=""
            local TEMP_CONTENT_TERMS=""
            
            # Parse query directly without using global variables
            local temp_query="$query"
            local temp_words
            read -ra temp_words <<< "$temp_query"
            
            for temp_word in "${temp_words[@]}"; do
                if [[ "$temp_word" =~ ^(author|title|tag|series|publisher|format|date|pubdate|rating|comments|identifiers): ]]; then
                    TEMP_METADATA_FILTERS="$temp_word"
                else
                    TEMP_CONTENT_TERMS="$TEMP_CONTENT_TERMS $temp_word"
                fi
            done
            
            # Determine search type
            if [[ -n "$TEMP_METADATA_FILTERS" && -n "$TEMP_CONTENT_TERMS" ]]; then
                search_type="hybrid"
            elif [[ -n "$TEMP_METADATA_FILTERS" ]]; then
                search_type="metadata"
            else
                search_type="fulltext"
            fi
            
            # Format dual response
            local mcp_result
            mcp_result=$(format_dual_response "$results" "$query" "$search_type")
            success_response "$id" "$mcp_result"
            ;;
            
        "fetch")
            local url
            url=$(echo "$arguments" | jq -r '.url // empty')
            
            if [[ -z "$url" ]]; then
                error_response "$id" -32602 "Missing required parameter: url"
                return
            fi
            
            local result
            result=$(fetch_by_epub_url "$url")
            
            # Check if it's an error
            if echo "$result" | jq -e '.error' >/dev/null 2>&1; then
                error_response "$id" -32603 "$(echo "$result" | jq -r '.error')"
            else
                # Format as dual response
                local title authors content url_param
                title=$(echo "$result" | jq -r '.title // "Unknown"')
                authors=$(echo "$result" | jq -r '.authors // "Unknown"')
                content=$(echo "$result" | jq -r '.content // ""')
                url_param=$(echo "$result" | jq -r '.url // ""')
                
                local content_text="Content from '$title' by $authors:\n\n$content"
                
                local mcp_result
                mcp_result=$(jq -cn --arg text "$content_text" --argjson fetch_data "$result" '{
                    content: [
                        {
                            type: "text",
                            text: $text
                        }
                    ],
                    book_id: $fetch_data.book_id,
                    title: $fetch_data.title,
                    authors: $fetch_data.authors,
                    url: $fetch_data.url
                }')
                success_response "$id" "$mcp_result"
            fi
            ;;
            
        *)
            error_response "$id" -32601 "Unknown tool: $tool_name"
            ;;
    esac
}

# Main request processing loop
main() {
    log "Calibre MCP Server started"
    
    while IFS= read -r line; do
        log "Request: $line"
        
        # Parse JSON-RPC request
        local method id params
        method=$(echo "$line" | jq -r '.method // empty' 2>/dev/null || echo "")
        id=$(echo "$line" | jq '.id // null' 2>/dev/null || echo "null")
        params=$(echo "$line" | jq '.params // {}' 2>/dev/null || echo "{}")
        
        if [[ -z "$method" ]]; then
            error_response "$id" -32700 "Parse error"
            continue
        fi
        
        case "$method" in
            "initialize")
                handle_initialize "$id"
                ;;
            "tools/list")
                handle_tools_list "$id"
                ;;
            "tools/call")
                local tool_name arguments
                tool_name=$(echo "$params" | jq -r '.name // empty')
                arguments=$(echo "$params" | jq '.arguments // {}')
                handle_tools_call "$id" "$tool_name" "$arguments"
                ;;
            "notifications/initialized")
                # Ignore this notification
                ;;
            "resources/list")
                # OpenAI compatibility - return empty resources
                success_response "$id" '{ "resources": [] }'
                ;;
            "prompts/list")
                # OpenAI compatibility - return empty prompts
                success_response "$id" '{ "prompts": [] }'
                ;;
            *)
                error_response "$id" -32601 "Method not found: $method"
                ;;
        esac
    done
}

# Run the server
main