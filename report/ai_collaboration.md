# AI collaboration and correction record

This is an abridged, manually curated record of actual project decisions, not a fabricated full chat transcript. The user requests below are short excerpts or close paraphrases; the response column records the implemented decision rather than claiming to quote an unavailable exact model message.

| User prompt / observation | Model action and artifact | Correction or boundary learned |
| --- | --- | --- |
| “只改心率啊，血氧那几个处理的还挺好的。” | Kept existing four-channel health/filter modules unchanged and recorded 11 protected RTL SHA-256 values in `data/core_sha256.json`. | A new sensor interface must not silently rewrite unrelated algorithms. |
| “我的个人数据只用作测试，不把他写进任何逻辑。” | Kept range values configurable, excluded personal captures from public release. | A measured personal value is not a general health threshold. |
| “仿真完了以后就把伪数据直接删掉。” | Public release includes only deterministic validation tooling and real Vivado reports, no fake waveform dataset. | Evidence needs a source label; do not make simulated values look measured. |
| “血氧、室温只是暂时测不出来，一定要把他们都考进去。” | Retained all four source paths and availability flags. | Missing measurements must be unavailable, not filled with previous values or quietly removed from the design. |
| “网页链路未接通不做了，不用写。” | Kept live website forwarding and receiving API out of the repository. | A planned feature is not a completed, tested deliverable. |
| Supplied older bitstream could not be matched to complete source. | Built a new `wyx_final_board_top` integration and generated a new bitstream. | Binary provenance must be explicit; build success is not board validation. |

The resulting release workflow is: record the requested boundary, inventory existing sources and provenance, preserve protected logic hashes, build in a clean location, publish exact report values, then mark physical test status separately. The reusable skills selected for this submission are `skill/sensor-link-diagnosis/`, `skill/filter-fault-evidence/`, and `skill/i2c-multidevice-scheduler/`. They extract diagnostic and interface reasoning that can be applied to different sensors and FPGA boards; the path check used for release packaging remains under `build/check_paths.py`.

## Verbatim exchange and self-correction from this release

**User prompt:** “按照这里面的自选赛题要求更改我的工程包，GitHub的仓库内容”

**Model response excerpt:** “我先核对选题指南全文和当前仓库，按要求整理目录、构建脚本、验证材料和报告，再同步工程包与 GitHub。现有实测结果和新固件的验证状态会分开标明。”

**Observed failure:** The first release checker passed on the source directory but failed on a clean rebuilt copy with `invalid path component: .Xil`, `invalid path component: NA`, and `build marker absent: Vivado 2024.1`. A second check also found that a rebuilt `.bit` has a different full SHA-256 because Vivado stamps its creation time into the header.

**Model correction excerpt:** “我发现重建后的核验脚本把 Vivado 自动生成的 `.Xil`、`NA` 目录当成源码目录，还要求报告使用固定的版本文字格式。构建本身已通过；我正在修正这两处核验规则，并分别复测原包和重建副本。”

**Retest:** The revised checker excludes only known generated directories, accepts the actual `version=2024.1` report form, and verifies an exact release hash or equal configuration payload after a different timestamp. It passed on both the released directory and the independent full rebuild; see `sim/validation_result.txt` and `data/clean_rebuild_20261101.txt`. This is still build evidence, not a sensor or board test.

## Skill selection and reusable output

**User prompt:** “做124的技能包，按照要求去做” (selecting sensor-link diagnosis, filter/fault evidence, and shared I2C scheduling from the previously reviewed table).

**Model action:** Added three independent `SKILL.md` entrypoints and reusable record templates under `skill/`; each item states applicability, use, observed result, and failure conditions in `skill/README.md`. The older release-path checker was retained as `build/check_paths.py` but removed from the selected skill set. No RTL, algorithm parameter, or experimental input was changed for this extraction.

**Correction and limit:** Source review demonstrates where events and decisions are represented; it is not proof that the newly integrated bitstream produced the same electrical or sensor behavior as older board sessions. Therefore the three skills label their project examples as source/build evidence and require exact-firmware board capture for dynamic claims.
