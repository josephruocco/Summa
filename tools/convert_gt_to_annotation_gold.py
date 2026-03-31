#!/usr/bin/env python3
import json
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
SRC_DIR = SCRIPT_DIR / "ground_truth"
DST_DIR = SCRIPT_DIR / "gold_sets" / "seed_from_gt"


def convert_entry(entry):
    if entry["verdict"] == "ok":
        converted = {
            "bookId": entry["bookId"],
            "phrase": entry["phrase"],
            "annotation_type": "wikipedia",
            "expected": entry.get("expected", ""),
        }
    else:
        converted = {
            "bookId": entry["bookId"],
            "phrase": entry["phrase"],
            "annotation_type": "suppress",
        }
    if "_reason" in entry:
        converted["_reason"] = entry["_reason"]
    return converted


def main():
    DST_DIR.mkdir(parents=True, exist_ok=True)
    for src_path in sorted(SRC_DIR.glob("*.json")):
        data = json.loads(src_path.read_text())
        converted = [convert_entry(entry) for entry in data if "_comment" not in entry]
        dst_path = DST_DIR / src_path.name
        dst_path.write_text(json.dumps(converted, indent=2, ensure_ascii=False) + "\n")
        print(f"Wrote {dst_path}")


if __name__ == "__main__":
    main()
