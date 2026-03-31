# Gold Sets

This directory contains richer evaluation sets for the annotation-type architecture.

Subdirectories:

- `seed_from_gt/`
  Baseline annotation-type sets generated from the existing per-book ground truth.
  Mapping:
  - `verdict == ok` -> `annotation_type == wikipedia`
  - `verdict == suppress` -> `annotation_type == suppress`

- `moby_dick_annotation_types.json`
  Hand-labeled small set that uses the richer target shape and includes `gloss`.

The seed files are a migration aid, not the final target. They preserve current coverage
while we gradually relabel high-value phrases as `gloss` where that better matches the
literary-annotation goal.
