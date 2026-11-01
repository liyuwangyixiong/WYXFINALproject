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
    "data/core_sha256.json",
    "data/source_inventory.json",
    "skill/README.md",
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
        if ".git" in path.parts or "vivado_build" in path.parts:
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
    if not bit.is_file() or sha256(bit) != inventory["new_bit_sha256"]:
        errors.append("bitstream SHA-256 differs from inventory")
    if inventory["new_build_validation"]["board_programmed"] is not False:
        errors.append("board validation status must not be inferred from build")

    result = (ROOT / "build/reports/result.txt").read_text(encoding="utf-8")
    timing = (ROOT / "build/reports/timing.rpt").read_text(encoding="utf-8")
    utilization = (ROOT / "build/reports/utilization.rpt").read_text(encoding="utf-8")
    for marker in ("Vivado 2024.1", "xc7z020clg400-1", "wyx_final_board_top"):
        if marker not in result + timing + utilization:
            errors.append(f"build marker absent: {marker}")
    if "All user specified timing constraints are met" not in timing:
        errors.append("recorded timing report does not show constraint closure")
    for marker in ("20846", "6421", "55"):
        if marker not in utilization:
            errors.append(f"utilization marker absent: {marker}")

    if errors:
        for error in errors:
            print("FAIL", error)
        raise SystemExit(1)
    print(f"RELEASE_EVIDENCE_PASS files={len(REQUIRED)} protected_rtl={len(baseline)} bit_sha256={sha256(bit)}")
    print("SCOPE: package integrity and existing Vivado evidence only; board validation pending")


if __name__ == "__main__":
    main()
