"""Prepare the verified runtime files for an existing PYNQ-Z2 Linux SD card."""

import argparse
import hashlib
import json
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FILES = (
    "board/install_sd_latest.sh",
    "board/load_on_pynq.py",
    "board/wyxfinalproject.bit",
    "data/source_inventory.json",
    "src/arm_monitor/engine.py",
    "src/arm_monitor/install_on_pynq.sh",
    "src/arm_monitor/interface.json",
    "src/arm_monitor/monitor.py",
    "src/arm_monitor/settings.json",
    "src/arm_monitor/simulator.py",
    "src/arm_monitor/storage.py",
)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=ROOT / "sd_payload" / "wyxfinalproject_latest")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output directory is not empty: " + str(output))

    inventory = json.loads((ROOT / "data/source_inventory.json").read_text(encoding="utf-8"))
    bit = ROOT / "board/wyxfinalproject.bit"
    if digest(bit) != inventory["new_bit_sha256"]:
        raise SystemExit("bitstream differs from source inventory")

    copied = {}
    for name in FILES:
        source = ROOT / name
        if not source.is_file():
            raise SystemExit("runtime file missing: " + name)
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        copied[name] = digest(destination)
    manifest = {"files": copied, "release_id": "wyxfinalproject-20261104-100mhz"}
    (output / "data/sd_copy_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("SD_PAYLOAD_READY", output, "files=" + str(len(copied)))
    print("BIT_SHA256", copied["board/wyxfinalproject.bit"])


if __name__ == "__main__":
    main()
