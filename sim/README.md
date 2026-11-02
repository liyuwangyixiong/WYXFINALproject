# Verification boundary

This directory contains a deterministic release-evidence checker. Packaging and path changes did not alter the filter or health algorithms, so this revision does not add new test vectors or fake waveforms. Previous simulated records and personal measurements are intentionally excluded from the public repository.

Run `python sim/validate_release.py` from any directory. It checks the source baseline, required files, reported part/tool/timing/resource fields and the bitstream. The released binary must match its SHA-256; a fresh build may instead match the recorded configuration payload after Vivado's creation-time header. Run the separate `build/check_paths.py` for names. These checks do **not** simulate RTL or verify SpO2 accuracy. The actual Vivado reports are under `build/reports/`; the room-channel board check is recorded in `data/board_validation_20261102.md`, while full four-channel acceptance remains pending.
