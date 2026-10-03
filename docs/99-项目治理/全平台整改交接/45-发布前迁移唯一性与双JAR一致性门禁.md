# 发布前迁移唯一性与双 JAR 一致性门禁

本机恢复遇到两个并行 V782 后，检查发现已有前向连续性测试先把版本放进 TreeSet，重复版本会被静默去重。现在逐个插入并先拒绝重复数值版本，再执行原有769起连续性检查；历史允许空号不变，新预留空号仍拒绝。针对本次双V782的新反例在旧逻辑上真实红（4项中3通过1失败），修复后实际JUnit Platform 4/4通过、0跳过；最终交付字节另核同4项，不重复加计。

现役 Simple Release 在Maven打包后执行这个序列合同与现有Flyway checksum导出；组装时、生成SHA/签名前，调用新增窄CLI verify-migrations。该CLI复用既有release_tools.py的migration_metadata和verify_jar_migrations，逐项校验应用JAR、迁移JAR与源码清单的名称、版本、精确SQL字节及真实Flyway checksum；没有另造摘要算法，也没有恢复已退役tar/SBOM发布链。

Linux轻验证实际通过6项CLI/既有安全测试和29项现役workflow测试，含执行真实组装脚本：重复版本、漏SQL、任一JAR字节差异均在SHA生成前拒绝。network none、无Docker socket、0.25CPU/512MiB，仅7秒，容器已删除。Windows原6项在旧POSIX web stamping的setup处拒绝，尚未到产品断言；失败日志保留，没有绕过该边界促绿。

实际独立索引tree `eab3a3ec58885a50e883cbd10b55a4516c7bb2ab` 的5路径与已验源语义完全一致，985个相关源逐一核对，其中980个未改源保持基准。换行差异按核验清单记录；Java索引字节与最终green-exact已验源完全一致。无其它WIP混入，未修改任何历史迁移、未执行新数据库操作、未打包签名上传、未运行全Maven/PG或真实CI。既有本机cleanB21/PID47572继续运行。

证据：migration-gate-candidate/manifest.json、evidence/junit-summary.json、evidence/linux-python-summary.json及原日志；migration-gate-index-evidence/source-equivalence.json和commit-receipt.json。此为本次启动冲突的发布防复发支持提交，不增加21产品小批或4/15父项完成数。最终还必须在发布的准确SHA上完成全量所需检查和实际CI。
