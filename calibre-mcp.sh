#!/bin/bash

# Calibre MCP Server
# A bash-based MCP server for searching and reading Calibre ebook library

set -euo pipefail

# Configuration
CALIBRE_LIBRARY="/Users/trieloff/Calibre Library"
CALIBREDB="/Applications/calibre.app/Contents/MacOS/calibredb"
LOG_FILE="requests.log"

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

# Search books using calibredb search
search_books() {
    local query="$1"
    local limit="${2:-50}"
    
    # Get book IDs from search with timeout
    local book_ids
    local temp_file=$(mktemp)
    
    # Run search command with timeout
    if run_with_timeout 10 "$CALIBREDB" search --library-path="$CALIBRE_LIBRARY" --limit="$limit" "$query" > "$temp_file" 2>&1; then
        book_ids=$(cat "$temp_file" | grep -v "Another calibre program" || echo "")
    else
        log "Search timed out or failed"
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
    
    # Process each book to add links and simplify format
    echo "$books_json" | jq '[.[] | {
        id: .id,
        title: .title,
        authors: .authors,
        series: .series,
        tags: .tags,
        publisher: .publisher,
        published: .pubdate,
        calibre_link: "calibre://show-book/Calibre_Library/\(.id)",
        formats: [.formats[] | split("/")[-1]],
        has_text: ([.formats[] | select(endswith(".txt"))] | length > 0),
        description: (.comments | if . then (. | gsub("<[^>]+>"; "") | split("\n")[0:2] | join(" ") | .[0:200] + "...") else null end)
    }]'
}

# Get book excerpt using grep on markdown file
get_book_excerpt() {
    local book_id="$1"
    local keyword="$2"
    local context_lines="${3:-5}"
    
    # Get book metadata to find file path
    local book_json
    local temp_file=$(mktemp)
    
    if run_with_timeout 10 "$CALIBREDB" list --library-path="$CALIBRE_LIBRARY" --fields=id,title,authors,formats --for-machine --search="id:$book_id" > "$temp_file" 2>&1; then
        book_json=$(cat "$temp_file" | grep -v "Another calibre program" || echo "[]")
    else
        log "Get book metadata timed out or failed"
        book_json="[]"
    fi
    rm -f "$temp_file"
    
    # Extract text file path
    local txt_path
    txt_path=$(echo "$book_json" | jq -r '.[0].formats[]? | select(endswith(".txt"))' 2>/dev/null || echo "")
    
    if [[ -z "$txt_path" ]] || [[ ! -f "$txt_path" ]]; then
        echo '{"error": "No text format available for this book"}'
        return
    fi
    
    # Get book info
    local title authors
    title=$(echo "$book_json" | jq -r '.[0].title // "Unknown"')
    authors=$(echo "$book_json" | jq -r '.[0].authors // "Unknown"')
    
    # Search for keyword with context
    local excerpts
    if [[ -n "$keyword" ]]; then
        # Use grep with context, limit results
        excerpts=$(grep -i -C "$context_lines" "$keyword" "$txt_path" 2>/dev/null | head -200 || echo "")
    else
        # If no keyword, get beginning of book
        excerpts=$(head -50 "$txt_path" 2>/dev/null || echo "")
    fi
    
    # Create response
    jq -cn --arg id "$book_id" --arg title "$title" --arg authors "$authors" --arg keyword "$keyword" --arg excerpts "$excerpts" --arg path "$txt_path" '{
        book_id: ($id | tonumber),
        title: $title,
        authors: $authors,
        keyword: $keyword,
        excerpts: $excerpts,
        file_path: $path
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
            version: "1.0.0"
        },
        capabilities: {
            tools: {}
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
            name: "search-fulltext",
            description: "Search books using Calibre full-text search",
            inputSchema: {
                type: "object",
                properties: {
                    query: {
                        type: "string",
                        description: "Search query (can use Calibre search syntax)"
                    },
                    limit: {
                        type: "integer",
                        description: "Maximum number of results (default: 50)",
                        default: 50
                    }
                },
                required: ["query"]
            }
        },
        {
            name: "search-author",
            description: "Search books by author name",
            inputSchema: {
                type: "object",
                properties: {
                    author: {
                        type: "string",
                        description: "Author name (partial match supported)"
                    },
                    limit: {
                        type: "integer",
                        description: "Maximum number of results (default: 50)",
                        default: 50
                    }
                },
                required: ["author"]
            }
        },
        {
            name: "search-title",
            description: "Search books by title",
            inputSchema: {
                type: "object",
                properties: {
                    title: {
                        type: "string",
                        description: "Book title (partial match supported)"
                    },
                    limit: {
                        type: "integer",
                        description: "Maximum number of results (default: 50)",
                        default: 50
                    }
                },
                required: ["title"]
            }
        },
        {
            name: "get-excerpt",
            description: "Get text excerpt from a book (requires book to have .txt format)",
            inputSchema: {
                type: "object",
                properties: {
                    book_id: {
                        type: "integer",
                        description: "Calibre book ID"
                    },
                    keyword: {
                        type: "string",
                        description: "Keyword to search for in the book (optional, if not provided returns beginning)"
                    },
                    context_lines: {
                        type: "integer",
                        description: "Number of context lines around matches (default: 5)",
                        default: 5
                    }
                },
                required: ["book_id"]
            }
        }
    ]')
    
    success_response "$id" "{ \"tools\": $tools }"
}

# Handle tool calls
handle_tools_call() {
    local id="$1"
    local tool_name="$2"
    local arguments="$3"
    
    case "$tool_name" in
        "search-fulltext")
            local query limit
            query=$(echo "$arguments" | jq -r '.query // empty')
            limit=$(echo "$arguments" | jq -r '.limit // 50')
            
            if [[ -z "$query" ]]; then
                error_response "$id" -32602 "Missing required parameter: query"
                return
            fi
            
            # Use FTS search if available, fallback to regular search
            local results
            results=$(search_books "$query" "$limit")
            success_response "$id" "{ \"books\": $results }"
            ;;
            
        "search-author")
            local author limit
            author=$(echo "$arguments" | jq -r '.author // empty')
            limit=$(echo "$arguments" | jq -r '.limit // 50')
            
            if [[ -z "$author" ]]; then
                error_response "$id" -32602 "Missing required parameter: author"
                return
            fi
            
            local results
            results=$(search_books "authors:\"$author\"" "$limit")
            success_response "$id" "{ \"books\": $results }"
            ;;
            
        "search-title")
            local title limit
            title=$(echo "$arguments" | jq -r '.title // empty')
            limit=$(echo "$arguments" | jq -r '.limit // 50')
            
            if [[ -z "$title" ]]; then
                error_response "$id" -32602 "Missing required parameter: title"
                return
            fi
            
            local results
            results=$(search_books "title:\"$title\"" "$limit")
            success_response "$id" "{ \"books\": $results }"
            ;;
            
        "get-excerpt")
            local book_id keyword context_lines
            book_id=$(echo "$arguments" | jq -r '.book_id // empty')
            keyword=$(echo "$arguments" | jq -r '.keyword // empty')
            context_lines=$(echo "$arguments" | jq -r '.context_lines // 5')
            
            if [[ -z "$book_id" ]]; then
                error_response "$id" -32602 "Missing required parameter: book_id"
                return
            fi
            
            local result
            result=$(get_book_excerpt "$book_id" "$keyword" "$context_lines")
            
            # Check if it's an error
            if echo "$result" | jq -e '.error' >/dev/null 2>&1; then
                error_response "$id" -32603 "$(echo "$result" | jq -r '.error')"
            else
                success_response "$id" "$result"
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
            *)
                error_response "$id" -32601 "Method not found: $method"
                ;;
        esac
    done
}

# Run the server
main