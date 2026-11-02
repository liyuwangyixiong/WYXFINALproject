# WYXFINALproject: PYNQ-Z2 four-channel health monitor

Entry for the 2026 AMD FPGA track, self-selected topic, junior group. The target is the PYNQ-Z2 with an `xc7z020clg400-1` Zynq-7000. FPGA logic accepts a KPT_D01 UART heart-rate value, a separate MAX30102 red/IR pair for SpO2, and two TMP117 temperature devices (probe and room). It filters measurements, handles missing or suspect channels, produces four health states, and drives a Nextion display. The PS-side Python monitor is included as an advisory component.

**Validation status:** Vivado 2024.1 synthesis, implementation, bit generation, DRC, and specified internal-clock timing passed for the new `wyx_final_board_top` design. The included new bitstream has **not** been programmed and checked with all four sensors on a physical board. Earlier board observations used a different firmware and are not evidence that this bitstream is hardware-validated. No personal health records or simulated captures are included.

## Contents

| Directory | Purpose |
| --- | --- |
| `src/rtl`, `src/drivers`, `src/display` | Synthesizable Verilog/SystemVerilog. |
| `src/ip`, `src/constraints` | PS7 Block Design source and PYNQ-Z2 constraints. |
| `src/arm_monitor` | PS-side Linux advisory source and install/run scripts. |
| `src/nextion` | Nextion HMI project, compiled screen asset and event sources. |
| `sim` | Source and build-evidence validation script; no invented sensor data. |
| `build` | Reproducible Vivado scripts and synthesis/implementation reports. |
| `board` | Existing bitstream, board connection/deployment instructions. |
| `data` | Provenance, hash baselines and reference values; no personal measurements. |
| `skill` | Three reusable skills: sensor-link diagnosis, filter/fault evidence, and shared I2C scheduling. |
| `report` | Design, tool-version, collaboration and validation reports. |

This follows the recommended directory structure in section 3.3.5.4 of the AMD guide. Standard tool files `README.md`, `LICENSE`, `SKILL.md`, `.gitignore` and `.gitattributes` retain their conventional spellings; other path components use lowercase ASCII letters, digits, underscores or hyphens.

## Rebuild on another Windows computer

1. Install Vivado 2024.1 with Zynq-7000 support. Version 2024.1 differs from the guide's recommended 2025.2/2026.1. This repository was built and tested for scripts on 2024.1; another release needs a fresh run and IP upgrade review.
2. Extract or clone to a short ASCII path with no spaces, for example `D:\fpga\wyxfinalproject`. Keep the full directory tree.
3. If Vivado is not installed at `E:\Xilinx\Vivado\2024.1`, set `VIVADO_BAT` to its `vivado.bat` before running the scripts.
4. Run `build\open_project.cmd` to generate `vivado_build\WYXFINALproject.xpr` and open it. This generated directory is intentionally omitted from Git because it can be recreated from `src/ip/wyx_ps_clock/wyx_ps_clock.bd` and the source files.
5. Run `build\build_bitstream.cmd` with the generated project closed to synthesize, implement, check DRC/timing and write `board\wyxfinalproject.bit` and `build\reports\*.rpt`.
6. Run `python sim\validate_release.py` to check required files, source hashes, bitstream identity (or equal configuration payload after a new build timestamp) and recorded build evidence. It checks packaging/evidence integrity, not sensor accuracy. Run `python build\check_paths.py .` for portable names.

The build scripts do not program hardware or write an SD card. See [board/README.md](board/README.md) for the distinct board procedure. The PS monitor does not automatically read PL registers: a producer must provide records matching `src/arm_monitor/interface.json`. It has no live website forwarding. Missing SpO2 or room-temperature data remain missing and must never be filled from old readings.

## Reported build result

| Item | Vivado 2024.1 result |
| --- | ---: |
| Internal clock | 25 MHz PS FCLK0 |
| LUT | 20,846 / 53,200 (39.18%) |
| Flip-flop | 6,421 / 106,400 (6.03%) |
| DSP48E1 | 55 / 220 (25.00%) |
| Block RAM tiles | 0 / 140 |
| Routed WNS / WHS | +7.569 ns / +0.039 ns |
| DRC | 0 errors, 127 advisory warnings |

These are reports for the same RTL before the directory-only reorganization. An independent rebuild after reorganization passed with the same resource and timing values; its configuration payload matched the released bitstream byte-for-byte after the creation-time header (see `data/clean_rebuild_20261101.txt`). See `build/reports/` and `report/design_report.md`. External asynchronous I/O delay is not constrained, so timing closure here is not proof of electrical or board-level correctness. No directly comparable pre-optimization whole-board baseline is available; the report does not claim a measured speed/resource improvement.

## License and provenance

Original project contributions are under the MIT license in `LICENSE`. Supplied sensor/display assets and vendor material retain their own ownership and terms; see [third-party notices](report/third_party_notices.md). The source that generated the earlier opaque `sensor_screen.bit` was not found. This repository integrates a new complete top and does not claim to reproduce that older binary. Thresholds are student-demo settings, not clinical limits.
