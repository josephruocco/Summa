# SUMMA

<p align="center">
  <img src="./assets/summa-logo.png" width="420" alt="SUMMA" />
</p>

**SUMMA** is a reading-augmentation tool that highlights text in real time and surfaces
**Wikipedia context** and **dictionary definitions** directly alongside what you’re reading.

It is designed to preserve immersion while providing historical, conceptual, and linguistic
context — without tab-switching, pop-ups, or distraction loops.

---

## What It Does

When you read text (web, PDF, EPUB, or system-level selection), SUMMA:

- Detects **important terms, names, and concepts**
- Highlights them inline (non-destructively)
- Displays:
  - **Wikipedia summaries** for people, places, events, and ideas
  - **Dictionary definitions** for vocabulary
- Keeps annotations **minimal, contextual, and dismissible**

Think: footnotes that appear only when they’re useful.

---

## Why SUMMA Exists

Most reading tools force a tradeoff between:
- Depth vs. flow
- Context vs. attention

SUMMA removes that tradeoff by letting context **surface quietly** and disappear just as easily.

The name references medieval *summae* — attempts to systematically organize knowledge without fragmenting it.

---

## Core Features

- 🔎 **Automatic term detection**
- 📚 **Wikipedia lookup (concept-aware, not just keyword-based)**
- 📖 **Dictionary definitions (part-of-speech aware)**
- ✍️ **Inline highlights** that do not modify source text
- 🪟 **Side or floating annotation panels**
- ⏱️ **Debounced lookups** to avoid visual noise
- 🧠 **Stop-word and frequency filtering**

---

## Architecture (High Level)

```text
Text Source
    ↓
Tokenization + POS tagging
    ↓
Entity / Term Candidate Filter
    ↓
┌───────────────────────────────┐
│  Wikipedia API  |  Dictionary │
│        API      |      API    │
└───────────────────────────────┘
    ↓
Annotation Layer
(overlay — not DOM rewrite)
