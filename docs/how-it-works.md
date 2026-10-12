# How Shizi recognizes text

English | [简体中文](how-it-works.zh-CN.md)

The [README](../README.md) covers how to use Shizi. This page explains how automatic mode decides how to recognize a page, and
why, for anyone who wants to understand the results or change the code. Coordinates always run from 0 to 1, with the origin at the
top left.

## The steps of automatic mode

0. For a PDF page, Shizi first checks whether the page's own text can be used (see "A PDF's own text" below). If it can, the page
   isn't recognized as an image; only the images on it are. The steps below are for recognizing an image.
1. If a judgment plugin is configured, it checks the image first, in parallel with the first recognition pass.
2. The whole image is recognized line by line. The language follows the recognition language setting: in automatic mode the system
   decides line by line; Chinese First recognizes text as Chinese first, and falls back to automatic on pages in Western languages
   or with text Chinese can't read (see "Recognition language" below).
3. A page is straightened first only if the paper is clearly tilted, the detected quadrilateral doesn't hug the image border, and
   95% of the text lies inside the paper. Without a plugin, the page must also need document recognition (see step 5); with a
   plugin, the plugin saying it's a photo also counts. A sheet scanned flat has no real paper edge to find: what gets found is
   usually a table block touching the border, so it isn't straightened. After straightening, coordinates are relative to the
   straightened image, and the result's `coordinateSpace` says so.
4. Small text: a large image (over about 2.5 million pixels) is split into tiles about 1000 pixels on a side and recognized in detail,
   and long lines cut by tile edges are joined back together; an image that is tilted as a whole is rotated upright before splitting.
   A small image is recognized again at double size, and that result is used only if it's clearly better.
5. If there are tables, columns, or vertical text (reported by the plugin or detected by the code), or no text was found at all,
   the page is recognized again in document mode and merged with the line-by-line result: the layout (table cells, paragraphs,
   reading order) comes from document mode, and the text in each block is replaced with the line-by-line text that falls inside it.
   - Text is replaced only where at least half of it matches on both sides; empty cells are filled in directly, and lines that
     fall in no block are listed at the end.
   - Document mode's layout is used only if more than 80% of the line-by-line text fits into it, and document mode itself
     recognized 90% of the text or found a table.
   - If the plugin reports a table but document mode found none, its layout isn't used: it would scramble the table column by column.
   - If document mode found no table but more than half of the lines sit in cells enclosed by printed lines (with more than one line
     in some cell), its layout isn't used either: it would output the page paragraph by paragraph, one column at a time.
     The page is read by cells as in step 6 instead.
   - Document mode's minimum text height is set to 1/64 of the image height: with the system default of 1/32, scans seem to be
     shrunk before recognition, and parts of tables are lost.
6. When document mode's layout isn't used, the line-by-line result is split into blocks at large blank areas: sidebars, body text,
   and dialogs are separated, with a blank line between blocks. Left and right sides that line up row by row (tables,
   "label: value" forms) aren't split.
   - When a page has text side by side, Shizi first looks for long black horizontal and vertical lines (red seals and blue ink don't
     count; strokes through the middle of text and strikethroughs are filtered out). Lines enclosed on all four sides form a cell:
     the lines of one cell are never split into different blocks, and a gutter that is a cell wall isn't cut either. Inside a block,
     cells are read row by row, each cell from top to bottom (when every cell in a row has one line only, the row is joined into
     one line).
   - A frame whose text splits into left and right columns of three or more lines each (a frame around the whole page) doesn't count
     as a cell, and is split as if there were no printed lines. Pages without printed lines are still read line by line.
   - When a page is split into several columns, each paragraph starts with its rough position on the page, such as 〔中间〕 (middle)
     or 〔左侧〕 (left), so that a model that can't see the image still knows where the text is; a note at the end of the result
     says these markers aren't recognized text. In English output the markers read 〔middle〕, 〔left〕, and so on.
7. Lines at the system's lowest confidence level, and lines found only by document mode (where line-by-line found nothing; mostly
   seals and signatures), are marked as suspicious. With a plugin, the longer suspicious lines are sent to it for review.

**Why combine the two modes**: document mode recognizes tables and paragraphs, but its text is poor on scans (look-alike characters
get confused, whole columns of numbers go missing). Line-by-line recognition gets the text right but knows nothing about tables, so
the order gets scrambled. Merged, the layout comes from one and the text from the other.

**Why tables are read along printed lines**: line boxes alone can't tell "one cell wrapped onto three lines" from "three rows of one
line each", so the second lines of neighboring cells get joined into one line; the lines printed on the paper tell them apart.
Pages without printed lines are still read line by line, without guessing cells from gaps and alignment: that would turn receipts
and tight key-value tables into one column of item names followed by one column of prices.

## A PDF's own text

PDFs exported from Word or a browser already contain their text, and Shizi uses it directly; images, flowcharts, and screenshots
inside them are recognized separately (an image that appears at the same position and renders the same is recognized only once,
such as a logo in every page header). The text can't be used blindly, so each page is first checked for what it draws (counted,
not decoded):

| What's on the page | How it is recognized |
|---|---|
| No drawn text (scans, vector drawings) | As an image |
| Only invisible text (an OCR layer that a scanner or Acrobat added to a scan) | Its layer is ignored and the page is recognized as an image (with a note in the result) |
| Invisible text on top of visible text, at least half as much as the visible text (a digital PDF that was OCRed again, so the text would appear twice) | As an image (with a note) |
| Images covering more than half the page (flowcharts, scans with headers and page numbers added) | As an image |
| Any other digital page | Its own text, with image areas recognized separately |

Two more checks:

- Pages where more than 2% of the text is garbled (a font without an encoding table) are recognized as images.
- Spot checks: a horizontal strip is OCRed and compared with the page's text, and a page where less than 80% matches is recognized
  as an image. Spot checks run on pages where a font first appears in quantity (each part of a merged PDF uses different fonts;
  once a font fails, every later page using it is recognized as an image), and on pages with white text drawn on a white background
  (invisible text, possibly a fake layer underneath; white text on a red background doesn't need checking).

Also:

- Images are found even in PDFs that declare resources in a parent node of the page tree. QR codes and barcodes are detected on
  every page, including vector-drawn ones and those in very small images.
- Selecting an area (drawing a box in Shizi, or `region` over MCP) takes the text inside the box, so selecting half a line gives half
  a line; images are recognized only when the box covers one. Lines cut by the crop box keep only the part inside it.
- PDFs exported from browsers often split one line into several pieces; they are joined back by position. Lines follow the page text
  as ordered by PDFKit (usually the reading order for Word and browser exports), with a blank line between paragraphs.
- Pages are recognized as images when the recognition mode is Document (it needs the table structure, which a PDF's own text
  doesn't have), when "Use a PDF’s text layer when it has one" is turned off in Settings, or when MCP passes `textLayer: false`.
- Known issue: in Chinese PDFs exported from browsers, PDFKit occasionally can't locate one character; it is placed at the end of
  the page in PDF order, without a box.

## Recognition language

Without a specified language, the system decides line by line which language model to use. Lines with many letters and digits get a
Western model, which turns the Chinese in them into gibberish, and short Chinese is often taken for Japanese (「出错」 comes out as
「出錯」). English reads fine with any model, which is why recognition seems especially good at English.

Chinese First recognizes everything as Chinese first (the Chinese model also reads English and digits) and falls back to automatic
in two cases:

- The page has almost no Chinese characters (English, Spanish, …): recognizing it as Chinese would drop letters such as á and ñ,
  and is slower.
- The page has text Chinese can't read: Korean and Japanese recognized as Chinese come out empty.

A PDF remembers the previous page's conclusion, so a Western PDF is recognized twice only on its first page. Pages that follow a
Western page and have little text or contain Chinese are tried as Chinese again, so a document can switch back.
Punctuation in English and code that was recognized as full-width is changed back to half-width; in lines with Chinese, only
punctuation between English letters and digits is changed (「请使用 API！」 and 「推荐 Mac（Intel）版本」 stay as they are).

The cost: the Chinese model makes small mistakes in English (a missing space after an apostrophe, "Ive" read as "lve", "®" read
as "@"), and single images that are mostly English are recognized twice. That's why automatic remains the default.

When languages are specified (concrete languages in the MCP `languages` parameter), the system uses only the first language's
model, so Chinese, Japanese, and Korean are moved to the front.

## MCP replies

- A reply holds at most about 45 KB and 1800 lines, because some clients show the model only the first 50 KB or 2000 lines of a
  tool result and cut the rest. When a multi-page PDF doesn't fit, the reply stops at a page boundary and ends with a note on which
  pages it covered and what to pass as `pages` for the rest (such as `pages="10-32"`), so you can simply call again. A single page
  that is too long is truncated; you can recognize it in parts with `region`.
- The `detail: "full"` JSON goes in a second text block of the reply, not in `structuredContent`: some clients read only text
  blocks, while others (such as Claude Code) read only `structuredContent` when it is present and drop the text blocks. With two
  text blocks, both see the same thing. The JSON counts toward the limit above, so a multi-page `full` reply holds only one or two
  pages.
- In the JSON, upright lines have only a `box`; tilted and upside-down lines also have a `quad` (four corners, in the direction the
  text runs).
- `ocr_to_file` writes each page the same way as an `ocr_image` reply, plus a `.json` file with the same name for `full`, and never
  overwrites existing files. When the client sends a progress token (`progressToken`), progress is reported after each page.
