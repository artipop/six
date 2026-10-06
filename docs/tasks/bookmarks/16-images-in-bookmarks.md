# 16. Finding a bookmark by what is in its pictures

## What this is

A bookmark keeps a page as text, and search over bookmarks is over that text. A picture survives only as a link in
the saved copy: what it shows and what is written on it is unknown to Savoia. Save an article whose point is a
diagram, or a screenshot of a price table, and a search for "pricing" or "queue diagram" does not find it — those
words were only in the picture.

Worth building only if such pages get bookmarked. **Ask Artem for five bookmarks where this bit him before
starting**; with none, close this file and leave a line in todo.md.

## The plan

Today a bookmark keeps images only as `![alt](src)` in the Markdown and `og:image` in the front matter; nothing in
a picture is searchable. The plan, in the order it should be built ([bookmarks.md](../../bookmarks.md#embeddings) has what
the SDK offers and doesn't):

1. **OCR + labels, locally (Vision)** — the base. When a page is bookmarked, download its large images (≥ 120 px, at
   most ~20 per page) into `Bookmarks/<slug>/images/`, run `RecognizeTextRequest` (multilingual OCR) and
   `ClassifyImageRequest` (~1300 labels) on each, and store the result as chunks of a new kind —
   `bookmark_chunks(kind: image, imageURL, text)` — embedded like any text. Screenshots, diagrams, infographics,
   menus, tables-as-pictures become findable by their words; a photo by its labels. Don't lean on `alt` or
   `<figcaption>` — they are usually empty or wrong; use them only as extra words when present.
2. **Descriptions from Foundation Models** (macOS 27: the on-device model takes `Attachment<ImageAttachmentContent>`
   — `CGImage`, `CIImage`, `CVPixelBuffer`, `imageURL:`; nothing else, no PDF). Ask for a one-line description per
   image, in the user's language, and store it as another image chunk. Seconds per image, needs Apple Intelligence
   assets — a budget of ~10 images per page, in the background after step 1. Decide after seeing step 1 on real pages.
3. **A multimodal embedder** (Voyage `voyage-multimodal-3`, Cohere Embed v4) as a second `Embedder` conformer:
   image chunks embedded as images, text as text, one space — real text→image search and cross-lingual text at the
   same time. Remote, keyed, images leave the Mac; a setting, off by default.

PDFs: the model doesn't take them; `PDFPage.string` for the text layer and page renders as images through step 1/2
when `ReadablePage` learns to read a PDF `WebPage`.

## Done when

Step 1 alone is a finished task: on the five bookmarks, a search for a word that appears only in a picture finds
the page, on the dev Mac's 8 GB, with the time and memory it cost written into
[bookmarks.md](../../bookmarks.md). Steps 2 and 3 are decided after seeing step 1 on real pages.
