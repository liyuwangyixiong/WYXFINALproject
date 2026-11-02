"""Check this release's source/artifact provenance without generating sample data."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    "src/rtl/wyx_final_board_top.sv",
    "src/drivers/sensor_acquire.v",
    "src/display/nextion_display.sv",
    "src/ip/wyx_ps_clock/wyx_ps_clock.bd",
    "src/constraints/pynqz2.xdc",
    "src/arm_monitor/monitor.py",
    "build/create_project.tcl",
    "build/build.tcl",
    "build/reports/timing.rpt",
    "build/reports/utilization.rpt",
    "build/reports/drc.rpt",
    "board/wyxfinalproject.bit",
    "board/install_sd_latest.sh",
    "board/load_on_pynq.py",
    "board/prepare_sd_payload.py",
    "data/core_sha256.json",
    "data/source_inventory.json",
    "data/board_validation_20261102.md",
    "data/board_validation_20261103.md",
    "skill/README.md",
    "skill/sensor-link-diagnosis/SKILL.md",
    "skill/sensor-link-diagnosis/references/triage_record.md",
    "skill/filter-fault-evidence/SKILL.md",
    "skill/filter-fault-evidence/references/evidence_matrix.md",
    "skill/i2c-multidevice-scheduler/SKILL.md",
    "skill/i2c-multidevice-scheduler/references/bus_plan.md",
    "report/design_report.md",
)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main() -> None:
    errors = []
    for name in REQUIRED:
        if not (ROOT / name).is_file():
            errors.append(f"missing: {name}")

    # Conventional tooling names are explicitly allowed by the contest example.
    conventional = {"README.md", "LICENSE", "SKILL.md", ".gitignore", ".gitattributes"}
    pattern = re.compile(r"[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\Z")
    for path in ROOT.rglob("*"):
        parts = path.relative_to(ROOT).parts
        if parts[:4] == ("src", "ip", "wyx_ps_clock", "ip"):
            continue
        if any(part in {".git", ".Xil", ".vivado-ai", "NA", "vivado_build", "generated"} for part in parts):
            continue
        if path.name not in conventional and not pattern.fullmatch(path.name):
            errors.append(f"invalid path component: {path.relative_to(ROOT)}")

    baseline = json.loads((ROOT / "data/core_sha256.json").read_text(encoding="utf-8"))
    for filename, expected in baseline.items():
        path = ROOT / "src/rtl" / filename
        if not path.is_file() or sha256(path) != expected:
            errors.append(f"protected source differs: {filename}")

    inventory = json.loads((ROOT / "data/source_inventory.json").read_text(encoding="utf-8"))
    bit = ROOT / inventory["new_firmware_path"]
    bit_hash = sha256(bit) if bit.is_file() else "missing"
    bit_bytes = bit.read_bytes() if bit.is_file() else b""
    if len(bit_bytes) != inventory["new_bit_size_bytes"]:
        errors.append("bitstream size differs from inventory")
    if bit_hash != inventory["new_bit_sha256"]:
        # Vivado stamps the creation time into the .bit header on each build.
        payload_hash = hashlib.sha256(bit_bytes[109:]).hexdigest()
        if (payload_hash != inventory["new_bit_payload_sha256_after_109"]
                or b"wyx_final_board_top" not in bit_bytes[:100]):
            errors.append("bitstream differs beyond the creation-time header")
    validation = inventory["new_build_validation"]
    if validation["board_programmed"] is True and not (ROOT / "data/board_validation_20261102.md").is_file():
        errors.append("board-programming evidence is missing")
    if validation.get("four_channel_liveness_verified"):
        evidence = validation.get("four_channel_liveness_evidence", "")
        if not evidence or not (ROOT / evidence).is_file():
            errors.append("four-channel liveness evidence is missing")

    result = (ROOT / "build/reports/result.txt").read_text(encoding="utf-8")
    timing = (ROOT / "build/reports/timing.rpt").read_text(encoding="utf-8")
    utilization = (ROOT / "build/reports/utilization.rpt").read_text(encoding="utf-8")
    for marker in ("2024.1", "xc7z020clg400-1", "wyx_final_board_top"):
        if marker not in result + timing + utilization:
            errors.append(f"build marker absent: {marker}")
    if "All user specified timing constraints are met" not in timing:
        errors.append("recorded timing report does not show constraint closure")
    for marker in (str(validation["lut_used"]), str(validation["ff_used"]), str(validation["dsp48_used"])):
        if marker not in utilization:
            errors.append(f"utilization marker absent: {marker}")

    if errors:
        for error in errors:
            print("FAIL", error)
        raise SystemExit(1)
    bit_mode = "exact" if bit_hash == inventory["new_bit_sha256"] else "same_payload_new_timestamp"
    print(f"RELEASE_EVIDENCE_PASS files={len(REQUIRED)} protected_rtl={len(baseline)} bit_sha256={bit_hash} mode={bit_mode}")
    print("SCOPE: package integrity and Vivado evidence; four-channel liveness recorded, accuracy and fault recovery pending")


if __name__ == "__main__":
    main()
