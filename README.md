# Summa (ScreenGlossMVP)

A macOS overlay that detects text on your screen and highlights vocabulary + named references with hover tooltips.

## Demo
(Add a short GIF or screen recording)

## Features (MVP)
- Screen capture via ScreenCaptureKit
- OCR via Vision
- Named-entity highlighting (NaturalLanguage)
- Dictionary definitions + optional web lookup

## Run
1. Open `ScreenGlossMVP.xcodeproj` in Xcode.
2. Build & Run.
3. Enable **Screen Recording** permission when prompted:
   System Settings → Privacy & Security → Screen Recording → enable the app.
4. Select the target window and toggle Session ON.

## Notes
- Best results with high-contrast text.
- OCR runs after scrolling settles (debounced).

## Roadmap
- Better entity span boxing (multi-word bounding boxes)
- Persistent caching for lookups
- PDF-native text extraction (when available) instead of OCR
