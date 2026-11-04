# WYXFINALproject: PYNQ-Z2 four-channel health monitor

Entry for the 2026 AMD FPGA track, self-selected topic, junior group. The target is the PYNQ-Z2 with an `xc7z020clg400-1` Zynq-7000. FPGA logic accepts a KPT_D01 UART heart-rate value, a separate MAX30102 red/IR pair for SpO2, and two TMP117 temperature devices (probe and room). It filters measurements, handles missing or suspect channels, produces four health states, and drives a Nextion display. The PS-side Python monitor is included as an advisory component.

**Validation status (2026-11-04):** The current `board/wyxfinalproject.bit` uses PS FCLK0 at 25 MHz for peripherals and FCLK1 at 100 MHz for the SpO2 compute path. Vivado 2024.1 synthesis, routing, bit generation, DRC error check, and specified internal-clock timing passed. Routed WNS is +0.070 ns with zero failing endpoints. Four RTL tests pass, covering the pipelined filter, divider, one estimator waveform, and the clock-domain mailbox. The 100 MHz image has **not** been programmed on a board. The separate `board/wyxfinalproject_25mhz_verified.bit` was programmed and had four-channel liveness checks on 2026-11-02/03. Those captures do not validate the 100 MHz image. No personal health records or simulated captures are included.

## Contents

| Directory | Purpose |
| --- | --- |
| `src/rtl`, `src/drivers`, `src/display` | Synthesizable Verilog/SystemVerilog. |
| `src/ip`, `src/constraints` | PS7 Block Design source and PYNQ-Z2 constraints. |
| `src/arm_monitor` | PS-side Linux advisory source and install/run scripts. |
| `src/nextion` | Nextion HMI project, compiled screen asset and event sources. |
| `sim` | Source and build-evidence validation script; no invented sensor data. |
| `build` | Reproducible Vivado scripts and synthesis/implementation reports. |
| `board` | Current 100 MHz bitstream, verified 25 MHz baseline, board instructions and SD runtime packaging scripts. |
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

The build scripts do not program hardware or write an SD card. See [board/README.md](board/README.md) for the distinct board and SD runtime procedures. The PS monitor does not automatically read PL registers: a producer must provide records matching `src/arm_monitor/interface.json`. It has no live website forwarding. Missing SpO2 or room-temperature data remain missing and must never be filled from old readings.

## Reported build result

| Item | Vivado 2024.1 result |
| --- | ---: |
| Internal clocks | FCLK0 25 MHz; FCLK1 100 MHz |
| LUT | 13,079 / 53,200 (24.58%) |
| Flip-flop | 9,091 / 106,400 (8.54%) |
| DSP48E1 | 64 / 220 (29.09%) |
| Block RAM tiles | 0 / 140 |
| Routed WNS / WHS | +0.070 ns / +0.037 ns |
| DRC | 0 errors, 110 advisory warnings |

See `report/design_report.md` for the before/after resource table and exact test scope. The 25 MHz baseline reports and image are under `build/reports/baseline_25mhz/` and `board/`. `build/reports/cdc.rpt` records one critical classification on the reset path and 60 mailbox data warnings; the mailboxes passed the included simulation, but this is not board validation. External asynchronous I/O delay is not constrained. The prior independent rebuild in `data/clean_rebuild_20261101.txt` applies to the 25 MHz baseline only.

## License and provenance

Original project contributions are under the MIT license in `LICENSE`. Supplied sensor/display assets and vendor material retain their own ownership and terms; see [third-party notices](report/third_party_notices.md). The source that generated the earlier opaque `sensor_screen.bit` was not found. This repository integrates a new complete top and does not claim to reproduce that older binary. Thresholds are student-demo settings, not clinical limits.
