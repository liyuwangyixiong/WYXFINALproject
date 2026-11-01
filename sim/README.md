# Verification boundary

This directory contains a deterministic release-evidence checker. Packaging and path changes did not alter the filter or health algorithms, so this revision does not add new test vectors or fake waveforms. Previous simulated records and personal measurements are intentionally excluded from the public repository.

Run `python sim/validate_release.py` from any directory. It checks the source baseline, bitstream hash, required files, reported part/tool/timing/resource fields and naming convention. It does **not** simulate RTL, verify SpO2 accuracy, prove a serial display exchange, or count as a physical board test. The actual Vivado reports are under `build/reports/`; the new bitstream's board acceptance remains pending as recorded in `board/README.md`.
