# Shizi (拾字)

English | [简体中文](README.zh-CN.md)

Shizi is on-device text recognition for the Mac. It reads the text in images, screenshots, scans, and PDFs, and makes the photos
it has recognized searchable by their text. It uses the text recognition built into macOS: everything stays on your Mac, with no
internet connection and no fees. It comes as a Mac app and as an MCP server, `shizi-mcp`, so AI assistants that support MCP,
such as Claude Code, can read the text in images and PDFs.

The name means "picking up characters" in Chinese. Versions 0.0.35 and earlier were called mac-ocr-mcp; version 0.0.36 in
[CHANGELOG.md](CHANGELOG.md) (Chinese) lists what to change when you upgrade.

## Features

- **All kinds of images**: photos, screenshots, and scans, at any angle, even upside down. Tilted pages are straightened first,
  small text in large images is split into tiles and recognized in detail, and QR codes and barcodes are detected too.
- **Tables and layout**: tables come out as Markdown, multi-column pages in reading order, and vertical text from right to left.
  Scanned tables and forms are read cell by cell along the lines printed on the paper. Tables, columns, and vertical text need macOS 26.
- **PDFs**: PDFs exported from Word or a browser use their own text, which is exact and much faster; images inside them are
  recognized separately. Scanned PDFs are recognized page by page.
- **Languages**: 30, detected automatically. For Chinese mixed with Latin letters, digits, or formulas, the Chinese First
  option gets it right.
- **Photos**: recognize the text in your Photos library and find photos by their text later. With a judgment service connected,
  Shizi can also classify photos by content and save each category as an album.
- **For AI assistants**: the MCP server recognizes images and PDFs, writes whole documents out as text files, and searches
  recognized photos by text.
- **Judgment plugins (optional)**: connect a judgment service to check an image before recognition and decide how to read it,
  to review lines that may be misrecognized, and to classify photos. Everything works without one.

## Install

Shizi runs on macOS 14 or later; tables, columns, and vertical text need macOS 26. For now it is built from source, which needs
Xcode 26 or the matching Command Line Tools.

Build the app:

```bash
./scripts/build-app.sh   # builds .build/app/Shizi.app, ad-hoc signed; drag it to Applications
```

The app includes the MCP server and the judgment plugin. An ad-hoc signed app counts as a new app after every rebuild, so you
need to grant Photos access again each time.

Build just the MCP server and the command line:

```bash
swift build -c release   # builds .build/release/shizi-mcp; the judgment plugin is .build/release/ocr-plugin-systemone
```

## Usage

### App

Drag in or open an image or PDF, or paste a screenshot with ⌘V, and recognition starts.

- The original is on the left, with a box over each line; the recognized text is on the right. **Page** shows it as running text,
  with tables drawn as real tables; **Line by Line** lists one line per row and marks the ones that may be misrecognized.
  Switch between them with ⌘1 and ⌘2.
- Drag a box on the image to recognize just that area. Copy all the text, or export it as Markdown, plain text, or JSON
  (with each line's position).
- Multi-page PDFs are recognized page by page, and you can stop at any time. The pages form one long scroll, and the page list
  and the text follow the page you are on.
- **Photos**: under Photos in the sidebar, grant access, pick an album, and click Recognize to recognize the photos that haven't
  been recognized yet. Find recognized photos by their text in the search field, and add selected photos to an album.
  Photos whose originals are only in iCloud are downloaded first; you can turn that off in Settings.
- **Classify**: Classify in the album header sorts photos into categories, or finds the ones that match a condition, by their
  recognized text or by the image itself. First turn on "Classify photos" for a judgment plugin in Settings.
- **Language**: English and Chinese. Shizi follows your system language: Chinese if your system language is Chinese, English
  otherwise. You can also pick one in Settings › Recognition › Interface; it takes effect after Shizi relaunches.
  Notes inside recognition results (such as lines that may be misrecognized and layout position markers) are still in Chinese.
- **Settings** (⌘,): recognition defaults, recognition language, interface language, and judgment plugins. Connect gives you
  the command for Claude Code and the configuration for other assistants, and sets up Lingxi, the author's own assistant,
  in one click.

### Connect an AI assistant (MCP)

Run `shizi-mcp` with no arguments to start the MCP server over standard input and output. For Claude Code:

```bash
claude mcp add shizi -- /absolute/path/to/shizi-mcp
```

For other assistants:

```json
{ "mcpServers": { "shizi": { "command": "/absolute/path/to/shizi-mcp" } } }
```

If you use the app, copy the path from Settings › Connect.

Tools:

- `ocr_image`: recognizes an image or PDF and returns the text: the body in reading order, tables as Markdown, followed by any
  QR codes and the lines that may be misrecognized.
- `ocr_to_file`: recognizes a whole document into a Markdown file and replies with just the path and a summary. Use it for long
  documents when you need the full text. It takes the same parameters as `ocr_image`, plus `outputPath`; without it, files go to
  `~/Library/Caches/shizi/results/` and are cleaned up after 7 days. Up to 100 pages per call.
- `photos_search`: finds photos Shizi has recognized by their text. Parameters: `query` (words separated by spaces) and `limit`.
  It only reads the text Shizi stored and never touches your Photos library.
- `ocr_status`: shows what this Mac can recognize, which plugins are configured, and whether they can be reached.

Tool descriptions and the notes in results are in Chinese for now; AI assistants read them fine.

Parameters of `ocr_image` and `ocr_to_file`:

| Parameter | Description |
|---|---|
| `path` | Required. Path to the image or PDF (`~` works) |
| `pages` | PDF pages, such as `"1-3,5"`; by default up to 20 pages from the start |
| `mode` | `auto` (default) / `lines` (line by line) / `document` |
| `languages` | Omit to use the recognition language from Settings; `["chinese-first"]` for Chinese First, `["auto"]` for automatic; a list such as `["zh-Hans", "en-US"]` sets the languages (only the first language's model is used, so Chinese, Japanese, and Korean are moved to the front) |
| `region` | Recognize one area only: `[left, top, width, height]` from 0 to 1, with the origin at the top left; result coordinates stay relative to the whole image |
| `rectify` | Straighten tilted pages: `auto` / `on` / `off` |
| `tiles` | Split large images into tiles to read small text: `auto` / `on` / `off` |
| `barcodes` | Detect QR codes and barcodes; on by default |
| `detail` | `text` (default) returns just the text; `full` adds a JSON block with each line's position, confidence, table cells, and more |
| `plugins` | Whether to call judgment plugins this time; on by default |
| `textLayer` | Use a PDF's own text when it has one; `true` by default, `false` recognizes every page as an image |

A reply holds about 45 KB at most. When a multi-page PDF doesn't fit, the reply stops at a page boundary and says which `pages`
to request next. Coordinates in the `detail: "full"` JSON run from 0 to 1, with the origin at the top left.

### Command line

```bash
shizi-mcp ocr image.png                      # the recognized text
shizi-mcp ocr document.pdf --pages 2 --json  # the full structured result
shizi-mcp status                             # what can be recognized, and whether plugins work
```

The options match the tool parameters; `shizi-mcp --help` lists them all.

## Settings

The configuration file is `~/.config/shizi/config.json` (set `SHIZI_CONFIG` to use another file). Shizi's Settings window edits
this file, and the MCP server checks it before each call, so changes apply without a restart.

- **Recognition language**: `"recognition": {"languages": "chinese-first"}` means Chinese First; leave it out for automatic.
  In automatic mode the system picks a language line by line, so Chinese in lines full of letters and digits often comes out
  garbled. Chinese First recognizes text as Chinese first, and falls back to automatic when a page is in a Western language or
  has text that Chinese can't read (Korean, Japanese).
- **Judgment plugins**: one entry per plugin under `plugins`. API keys are kept in the keychain, never in the file.
  A plugin sends what it needs to judge to the service you configure: downscaled images for image checks and for classifying
  by image, the suspicious lines for reviews, and the recognized text for classifying by text. Without plugins, nothing is sent
  anywhere. For setup and the plugin protocol, see [docs/plugins.md](docs/plugins.md).

## Limitations

Shizi can't read, or reads poorly: emoji, superscripts and subscripts in formulas, very small text (under about 8 pixels tall),
text curved along a seal, characters a typeface doesn't distinguish (such as I and l), and merged table cells (they are split into
blanks). Only black table lines are detected, so tables on red backgrounds or with light gray lines come out line by line.
Signatures can't be read, and handwriting isn't specifically tuned.

## How it works

How automatic mode chooses a strategy, when a PDF's own text is used, and when Chinese First falls back are explained in
[docs/how-it-works.md](docs/how-it-works.md).

## Development

The development rules are in [AGENTS.md](AGENTS.md), the change log is [CHANGELOG.md](CHANGELOG.md), and the UI guidelines are
in [docs/design-spec.md](docs/design-spec.md), all in Chinese.

```bash
./scripts/setup-hooks.sh   # run once after cloning: enables the commit hook (checks CHANGELOG, bumps the version)
./scripts/test.sh          # unit tests
./scripts/test-hooks.sh    # tests for the commit hook
```

`./scripts/build-app.sh --sign` and `--release` sign and notarize with your own Developer ID; the top of the script explains
how to set it up. The benchmark script `bench/bench.mjs` uses a set of test images on the author's machine that isn't in this
repository.

## License

[MIT](LICENSE)
