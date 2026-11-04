# Verification boundary

This directory contains a deterministic release-evidence checker. Packaging and path changes did not alter the filter or health algorithms, so this revision does not add new test vectors or fake waveforms. Previous simulated records and personal measurements are intentionally excluded from the public repository.

Run `python sim/validate_release.py` from any directory. It checks required files, protected RTL hashes, reported part/tool/timing/resource fields and both bitstreams. The current binary must match its SHA-256; a fresh build may instead match the recorded configuration payload after Vivado's creation-time header. Run `python build/check_paths.py .` for portable names.

Run `powershell -File sim/run_equivalence.ps1` from the repository root with Vivado 2024.1 simulator available at `E:\Xilinx\Vivado\2024.1\bin`, or set `VIVADO_BIN`. It compiles the original and pipelined RTL together and runs four deterministic testbenches. Results are under `sim/results/`: 260 paired filter samples, 40 divider inputs, one 400-sample SpO2 estimator waveform, and 20 mailbox transfers between 25 and 100 MHz clocks. These tests do not establish numerical accuracy over all sensor inputs or physical board operation.

The 100 MHz image has not been programmed. The 2026-11-02/03 board captures in `data/` apply to the retained 25 MHz baseline bitstream.
