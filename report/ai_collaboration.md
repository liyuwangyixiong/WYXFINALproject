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

The resulting workflow is: record the requested boundary, inventory existing sources and provenance, preserve protected logic hashes, build in a clean location, publish exact report values, then mark physical test status separately. This became the reusable `skill/reproducible-vivado-release/` skill. It is useful for other Vivado projects because it checks evidence classes and package structure rather than a health-specific threshold.
