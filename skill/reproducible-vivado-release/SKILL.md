---
name: reproducible-vivado-release
description: Package a Vivado FPGA project with reproducible source, measured reports, clear provenance, and separate build-versus-board validation claims.
---

# Reproducible Vivado release

Use when a team needs to hand a Vivado design to another computer or publish a competition repository. This workflow applies across boards and topics; adapt device and interface details from the actual project.

1. Inventory source files, generated IP, board constraints, scripts, tool version, binary artifacts and licenses. Identify which source produced each bitstream; keep unmatched artifacts clearly separate.
2. Preserve existing design behavior during packaging. Record hashes of modules that must remain unchanged. Before changing algorithmic logic, define a separate functional verification plan.
3. Rebuild from source in a clean directory. Keep generated caches out of the release. Capture the exact Vivado version, part, top, resource report, timing summary, DRC and artifact hash.
4. Classify claims as source present, simulation/validation, synthesis, implementation, bit generation, board programming, and live sensor test. Never promote a lower layer to a higher one. Do not use personal data or invented waveforms as public evidence.
5. For board evidence, log the programmed bitstream hash, input stimulus or sensor setup, timestamps, raw output and reference result. If a stage is missing, mark it pending in README and the report.
6. Check repository paths with `python scripts/check_paths.py <repository-root>`. Rename unsafe path components and update script references. Keep standard tool filenames such as `README.md`, `LICENSE`, `SKILL.md` and Git dotfiles.
7. State the exact scope of third-party code and generated vendor artifacts. Apply an open-source license only where the authors have the right to do so.

The prompt template in [references/prompts.md](references/prompts.md) can be reused to ask an agent for an evidence audit. The path checker only tests names. Neither resource verifies HDL function or hardware operation.
