# Summa

![Summa](./assets/summa-logo.png)

Summa is a macOS menu bar app that lays an annotation layer over anything you read. Point it at whatever is on screen, a book in Kindle, a PDF, an article in a browser tab, and it surfaces the references, context, and word meanings a careful editor would add, right on top of the page, on hover. Nothing to import, no separate reading app, no tab to open.

## What it does

Summa reads along with you and annotates the few things per page actually worth a pause: a classical or biblical allusion, a piece of period context, a callback to something earlier in the same book, a word whose meaning has drifted. It is built for restraint. Annotating less, but annotating the things that matter, is most of the work.

Hover a highlighted phrase and a short gloss appears. Nothing is written into the app you are reading in. Summa draws a transparent layer on top, so it works the same over any reading surface.

## How it works

The interesting part is the pipeline behind the overlay:

1. **Capture.** ScreenCaptureKit grabs a frame of the frontmost window. Vision runs OCR and returns the recognized text with a bounding box for every token.
2. **Segment.** The tokens are stitched back into reading order and split into passages.
3. **Annotate.** Each passage goes to a language model behind a prompt tuned for restraint. The model returns structured output: the exact phrase, a short gloss, and a type.
4. **Ground.** Every returned phrase is matched back against the OCR tokens, so annotations land on the real words on screen rather than on a paraphrase. The matched run is grouped into visual lines and each line is unioned into its own rectangle. If a phrase cannot be found in the real tokens it is discarded. The model proposes; something it cannot fabricate disposes.
5. **Render.** A transparent overlay draws a highlight box per line. Hover shows the gloss.

Model calls route through a Cloudflare Worker proxy rather than shipping a key in the client, and results stream back as NDJSON so annotations appear incrementally instead of after one long wait.

## Evaluating the annotations

The hard problem is not calling a model, it is teaching it restraint and measuring whether it listened. The `tools/` directory holds the eval harness: a hand curated ground truth set across many works, gold sets for annotation types, and the scoring scripts. The ground truth deliberately includes cases labeled to suppress, so that returning nothing becomes a scoreable outcome and annotation noise is penalized rather than invisible.

The design story behind this is written up here: [Measuring Silence](https://josephruocco.net/2026/07/27/measuring-silence/).

## Stack

- SwiftUI and AppKit, a `MenuBarExtra` accessory app
- ScreenCaptureKit for capture, Vision for OCR
- A Cloudflare Worker proxy (`server/summa-proxy`) in front of the Anthropic Messages API, with streaming and per code rate limits
- A Python eval harness in `tools/`

## Build and run

Open `ScreenGlossMVP.xcodeproj` in Xcode and build the `ScreenGlossMVP` scheme for macOS. The app is not sandboxed, because it needs Screen Recording permission to read the frontmost window. Grant that under System Settings on first launch.

Premium annotations run through the proxy and need an access code, or you can point the app at your own Anthropic key in Settings.

## Status

Summa is early and under active development. The demos on [josephruocco.net](https://josephruocco.net) show it running on chapters of public domain classics.
