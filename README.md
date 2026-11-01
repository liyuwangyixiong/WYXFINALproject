# PYNQ-Z2 full board project

This is a newly integrated four-channel board design for a PYNQ-Z2 (XC7Z020), created because the complete source that generated the supplied `health_screen_board_top` bitstream was not present in the available archives. The original bitstream and original project were preserved unchanged. This source project builds a new bitstream with top module `wyx_final_board_top`; it is not a byte-for-byte rebuild of the older `sensor_screen.bit`.

## What is included

- KPT_D01 UART heart-rate input and the existing heart-rate smoothing/quality/fusion modules.
- MAX30102 I²C acquisition, paired red/IR filtering, and SpO₂ estimation.
- Two TMP117 I²C channels for probe and room temperature.
- Nextion serial display interface and the supplied editable HMI/TFT assets.
- PS7-generated 25 MHz FPGA clock for the PYNQ-Z2.
- ARM Linux advisory engine source and install/run scripts.
- The generated `firmware/WYXFINALproject.bit`, Vivado reports, and a reproducible project-generation/build script.

The web forwarding/API feature is not included. The ARM monitor does not currently read PL registers by itself; an FPGA-to-ARM producer still needs to deliver records in the documented JSONL format.

## Open and rebuild

Requires AMD/Xilinx Vivado 2024.1 with Zynq-7000 support.

1. Keep the project in a short ASCII path, such as `D:/FPGA/WYXFINALproject_full_board_20261101`.
2. Run `open_project.cmd` to generate the XPR and open it in Vivado.
3. Run `build_bitstream.cmd` to execute synthesis, implementation, timing/DRC checks, and write a new `.bit` under `firmware/`.

If Vivado is not found automatically, set the `VIVADO_BAT` environment variable to the installed `vivado.bat` path before running either command. The scripts do not program a physical board or write an SD card.

## Build evidence

The included build was run with Vivado 2024.1 for `xc7z020clg400-1`.

- Synthesis: 0 errors and 0 critical warnings.
- Implementation and bit generation: completed successfully.
- Routed timing: WNS +7.569 ns, TNS 0 ns, WHS +0.039 ns, THS 0 ns; all specified 25 MHz internal-clock timing constraints are met.
- DRC: 0 errors. Vivado emitted advisory warnings, including DSP pipeline recommendations.
- I/O timing: asynchronous sensor/UART pins do not have synchronous external input/output delay constraints. The reported internal clock timing is not an external electrical timing or live sensor validation result.
- The 11 protected existing health/filter/UART RTL modules match the pre-integration SHA-256 baseline in `evidence/core_sha256.json`.
- A separate source-only copy containing just the PS7 `.bd` generated the Vivado project and passed synthesis; see `evidence/clean_source_reproduction.txt`.
- New bitstream SHA-256: `ec7ac4fb93c1dfd8f15507247a67d389250996a2289fee6e574d7c6eaee0f929` (4,045,679 bytes).

This verifies that Vivado built the design and met the constraints that are present. The newly generated bitstream has not yet been programmed and tested on the physical board.

## Layout

- `rtl/`, `drivers/`, `display/`: synthesizable design sources.
- `ip/wyx_ps_clock/wyx_ps_clock.bd`: PS7 clock Block Design.
- `constraints/pynqz2.xdc`: PYNQ-Z2 package pins and I/O standards.
- `tools/create_project.tcl`, `tools/build.tcl`: project and build entry points.
- `firmware/`: output bitstream.
- `evidence/build/`: reports from the verified build.
- `arm_monitor/`: ARM-side health evidence/advisory engine; external-input mode has no simulated fallback.
- `nextion/`: screen assets and editable HMI files.

Thresholds in the project are configurable demonstration parameters, not medical limits or a certified life-support function. See `THIRD_PARTY_NOTICES.md` for the scope of licenses and supplied materials.
