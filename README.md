# calibre-mcp

A Model Context Protocol (MCP) server for searching and reading books from your Calibre ebook library.

## Features

- **Full-text search** with automatic phrase matching and fuzzy fallback
- **Search by author** or **title** with partial matching
- **Extract text excerpts** from books with keyword highlighting and pagination
- Pure bash implementation using `calibredb` CLI
- Returns Calibre deep links (`calibre://`) and file URLs (`file://`)
- Robust timeout handling for macOS compatibility

## Prerequisites

- [Calibre](https://calibre-ebook.com/) installed at `/Applications/calibre.app`
- A Calibre library at `~/Calibre Library`
- Text (.txt) exports of your books for excerpt functionality
- Bash 4.0 or later

## Installation

1. Clone this repository:
```bash
git clone https://github.com/trieloff/calibre-mcp.git
cd calibre-mcp
```

2. Make the script executable:
```bash
chmod +x calibre-mcp.sh
```

## Usage

### With MCP Inspector

Test the server using the MCP Inspector:

```bash
npx @modelcontextprotocol/inspector /path/to/calibre-mcp.sh
```

### With Claude Desktop

Add to your Claude Desktop configuration:

```json
{
  "mcpServers": {
    "calibre": {
      "command": "/path/to/calibre-mcp.sh"
    }
  }
}
```

## Available Tools

### search-fulltext

Search books using Calibre's full-text search engine.

**Parameters:**
- `query` (required): Search query. Multi-word queries are automatically phrase-searched
- `limit` (optional): Maximum results (default: 50)
- `fuzzy_fallback` (optional): Fallback query with related terms if exact search fails

**Example:**
```json
{
  "query": "machine learning",
  "fuzzy_fallback": "AI artificial intelligence ML neural networks deep learning"
}
```

### search-author

Search books by author name with partial matching.

**Parameters:**
- `author` (required): Author name (partial match supported)
- `limit` (optional): Maximum results (default: 50)

### search-title

Search books by title with partial matching.

**Parameters:**
- `title` (required): Book title (partial match supported)
- `limit` (optional): Maximum results (default: 50)

### get-excerpt

Extract text excerpts from books with keyword context.

**Parameters:**
- `book_id` (required): Calibre book ID
- `keyword` (optional): Search term to find in the book
- `context_lines` (optional): Lines of context around matches (default: 10)
- `max_results` (optional): Results per page (default: 10)
- `page` (optional): Page number for pagination (default: 1)

## Response Format

Search results include:
- Book metadata (title, authors, series, tags, publisher)
- Calibre deep link for opening in Calibre
- File URL for direct EPUB access
- Available formats
- Whether text format is available for excerpts

## Logging

The server logs all requests and responses to `requests.log` for debugging.

## Limitations

- Requires Calibre to be closed or may experience timeouts
- Full-text search requires indexed books
- Excerpt extraction only works with .txt exports

## License

Apache License 2.0 - See [LICENSE](LICENSE) file for details.