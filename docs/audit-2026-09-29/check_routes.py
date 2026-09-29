"""Read-only quality audit of the downloaded official CSV; run with Python 3."""
import csv
import hashlib
import json
import math
from collections import Counter
from pathlib import Path

BASE = Path(__file__).resolve().parent
source = BASE / "taiwantrip-official-93967.csv"
raw = source.read_bytes()
with source.open(encoding="utf-8-sig", newline="") as handle:
    rows = list(csv.DictReader(handle))
counts = Counter(row["路線名稱"] for row in rows)
keys = Counter((r["路線名稱"], r["方向性"], r["站序"]) for r in rows)
invalid = []
for line, row in enumerate(rows, 2):
    try:
        lat, lon = float(row["緯度"]), float(row["經度"])
        valid = (math.isfinite(lat) and math.isfinite(lon)
                 and -90 <= lat <= 90 and -180 <= lon <= 180
                 and int(row["站序"]) > 0)
    except (ValueError, TypeError):
        valid = False
    if not valid:
        invalid.append({"csv_record_including_header": line, **row})
report = {
    "retrieved_date": "2026-09-29",
    "source": "https://media.taiwan.net.tw/od/07_DTD/%E5%8F%B0%E7%81%A3%E5%A5%BD%E8%A1%8C.csv",
    "sha256": hashlib.sha256(raw).hexdigest(),
    "rows": len(rows), "distinct_route_names": len(counts),
    "route_rows": dict(counts),
    "invalid_coordinate_or_sequence_rows": invalid,
    "duplicate_route_direction_sequence": [
        {"key": list(key), "count": count} for key, count in keys.items() if count > 1
    ],
    "records_with_embedded_comma": sum(any("," in v for v in row.values()) for row in rows),
    "limitations": "Basic syntax/range audit only. Does not prove current operation, geographical correctness, or complete route coverage.",
}
(BASE / "route-quality.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps({k: report[k] for k in ["rows", "distinct_route_names", "records_with_embedded_comma"]}, ensure_ascii=False))
print("Invalid rows:", len(invalid), "Duplicate key groups:", len(report["duplicate_route_direction_sequence"]))
