# 25. EmbeddingGemma 2 as the embedder

Try Google's EmbeddingGemma 2, released on 6 October 2026, in place of — or beside — `multilingual-e5`, and keep it
only if it is better on Artem's own bookmarks and fits this Mac.

## Why it is worth an afternoon

From the announcement and the coverage of it — **none of this is checked against the model card; do that first**:

- open weights under Apache 2.0, on Hugging Face and Kaggle;
- 740 M parameters in three blocks: about 270 M for text and code, 170 M for images and video frames, 300 M for
  audio;
- **one 768-dimension space for all of them** — a picture and the sentence that describes it land together;
- quantized, about 191 MB of memory for the text block alone and 567 MB for everything, measured by Google on a
  phone.

Two things in Savoia it could change:

- **Search over bookmarks and the start page's personal search** ([bookmarks.md](../../bookmarks.md#embeddings)).
  Today that is `multilingual-e5-small` (384 dimensions) or `-base` (768), through MLX.
- **Pictures in bookmarks** ([16-images-in-bookmarks.md](16-images-in-bookmarks.md)). Its third step was a
  multimodal embedder, remote and keyed, with images leaving the Mac. A local one makes that step the first: no
  OCR, no captions, the picture itself is embedded beside the text. If this model holds up, task 16 is rewritten
  around it.

## What is not known, and decides everything

1. **Languages.** E5 was chosen because «плов» and *pilaf* land next to each other across about a hundred
   languages. Does the model card promise that for text, and does Russian ↔ English retrieval hold on real pages?
2. **Whether it runs under MLX at all.** Savoia's embedder is `MLXEmbedder` over
   [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)'s `MLXEmbedders`. Is this architecture supported
   there, is there an MLX conversion of the weights, and is the image tower? **Look before writing anything**
   (AGENTS.md: search for what exists first, and report stars, activity and licence). The other fronts on `dev`
   run E5 as transformers.js in a `PageSandbox` — note whether an ONNX build exists, since an embedder only the Mac
   can run splits the index between fronts.
3. **What a text needs.** E5 wants a `query: ` / `passage: ` prefix, mean pooling set by hand and L2
   normalisation; each was a bug once. This model will have its own task prompts and pooling — read them from the
   card, not from E5's habits.
4. **Memory on 8 GB.** The dev Mac is usually in the `.warning` pressure band (AGENTS.md). Measure resident and
   GPU memory in a Release build for the text block and for text plus images, at fp16, the way bookmarks.md
   records it for E5. Quantisation was prototyped once and deliberately not shipped; do not reach for it first.
5. **Whether 768 can be cut.** If the model is trained so that a prefix of the vector still works, 256 or 384
   dimensions halve the index. Check the card.

## Order

1. Read the model card and the MLX question; write down what is there. Stop if it does not run on the Mac without
   a port of our own, and say what a port would take.
2. A second `EmbeddingModelChoice` beside `small` and `base`, behind the existing setting — the type is already a
   ladder. Vectors of different models never share an index: `BookmarkIndexer` rebuilds on a change of choice, and
   that has to stay true.
3. **The comparison, on Artem's bookmarks**: the same twenty questions against both indexes — some in Russian
   about English pages, some the other way — and which page each returns first. `SAVOIA_EMBED_SELFTEST` and
   `SAVOIA_PERSONAL_SELFTEST` exist; extend them rather than judge by eye. Time per page and memory beside the
   answers.
4. Only if text is at least as good: one bookmark's pictures embedded and found by a sentence. That result decides
   task 16.

## Done when

[bookmarks.md](../../bookmarks.md) has a table — E5 small, E5 base, EmbeddingGemma 2 — with quality on the twenty
questions, time, memory and size on disk, and one line saying which is the default and why. If it is not adopted,
the table stays and this file goes.
