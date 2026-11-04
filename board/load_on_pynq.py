#!/usr/bin/env python3
"""Load this release's FPGA image from the PYNQ-Z2 SD installation."""

import hashlib
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    bitstream = root / "board" / "wyxfinalproject.bit"
    inventory = json.loads((root / "data" / "source_inventory.json").read_text(encoding="utf-8"))
    actual = hashlib.sha256(bitstream.read_bytes()).hexdigest()
    expected = inventory["new_bit_sha256"]
    if actual != expected:
        raise SystemExit("Bitstream SHA-256 mismatch: " + actual)

    from pynq import Bitstream, Clocks

    Clocks.fclk0_mhz = 25
    Clocks.fclk1_mhz = 100
    Bitstream(str(bitstream)).download()
    fclk0 = Clocks.fclk0_mhz
    fclk1 = Clocks.fclk1_mhz
    if abs(fclk0 - 25) > 1 or abs(fclk1 - 100) > 1:
        raise RuntimeError(f"Unexpected PL clocks: FCLK0={fclk0:.3f} FCLK1={fclk1:.3f} MHz")
    print(f"WYX_LATEST_PL_LOADED FCLK0_MHZ={fclk0:.3f} FCLK1_MHZ={fclk1:.3f} SHA256={actual}", flush=True)


if __name__ == "__main__":
    main()
