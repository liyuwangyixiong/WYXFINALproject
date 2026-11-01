# Reusable skill package

`reproducible-vivado-release/` is a board-agnostic Vivado release and evidence workflow. It applies to a project with RTL/HLS or a Block Design that must be delivered with source, scripts, reports and an honest hardware-validation status. It is not tied to this health-monitor topic, its thresholds, or this PYNQ-Z2 board. It is also not a tested PYNQ Overlay/register-map skill, so the optional PYNQ-specific bonus is not claimed.

## Use

1. Give the agent the target repository and the matching bitstream/build reports. Invoke `skill/reproducible-vivado-release/SKILL.md` as the workflow.
2. Run `python skill/reproducible-vivado-release/scripts/check_paths.py <repository-root>` to find nonportable path components.
3. Follow the skill's evidence classification and report checklist. Fill numbers from actual tool output only. Run a clean source rebuild when paths or scripts change.

## Verified effect here

The path checker was run on this reorganized repository; the result is in `sim/validation_result.txt`. The release checker verified protected RTL hashes, bitstream hash, file layout and existing Vivado report markers. The procedure prevented an older, unmatched bitstream and its hardware observations from being presented as validation of the newly integrated bitstream.

## Failure and scope limits

The checker does not parse HDL, prove timing or program a board. It allows conventional `README.md`, `LICENSE`, `SKILL.md` and Git dotfiles because those names are required by common tooling and the guide itself uses `README.md`. A packaging pass is only a packaging pass; functional simulation and board tests remain separate. For projects with different tools or vendor IP, adapt the evidence checklist and confirm redistribution rights before release.
