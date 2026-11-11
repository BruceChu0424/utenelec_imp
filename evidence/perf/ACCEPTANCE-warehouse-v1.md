# B 20物料性能候选 v1 验收

实际执行源码为 **`199bb4a257d33ce6dcaa6391343f22bad2fa2065`**，基于统一候选7b。新独立工作树 `feedback-perf-verify-199bb-20261111` 正常 fresh Maven 构建，完整42/42通过，0失败/错误/跳过，exit0，sourceStart=sourceEnd=199bb、dirtySourceAfter=[]。本报告不冒称后续统一候选已执行。

机器对照原Root XML逐case核实：**原35聚合用例一个未少，全部通过**；只新增1个真实并发读取用例，聚合36/36；既有仓分解PostgreSQL 6/6。汇总/逐case在 `warehouse-v1-acceptance-summary.json`，原红XML另存 `original-red-aggregate.xml`。

| 实际提交场景 | 原门槛 | 写操作耗时 | 写SQL / JDBC / commit | 同库真实读负载 |
|---|---:|---:|---|---|
| 原Root7b失败 | 10000 ms | **10214 ms，失败保留** | 1105 / 8841.1267 ms / 376.3422 ms | 原Root并行环境，原证据不覆盖 |
| v1无注入读取客户端 | 10000 ms | 4172 ms | 1105 / 3604.0324 ms / 131 ms | 0 |
| v1一个真实detail客户端 | 10000 ms | 4506 ms | 1105 / 4053.7877 ms / 143 ms | 共13个RR事务/559 SQL；11次完整读取实际覆盖提交区间 |

原21批、计划1、采购总量400及原幂等键重放断言均通过。读负载真实调用相同分析的 `analyses.detail`，校验分析与20物料身份完整，复制真实测试principal，使用独立事务与JDBC计数；不是空转/pg_sleep。客户端收尾不计入原写操作计时，没有修改10000ms门槛。此为本地合成数据服务验收，非公司普通账号HTTP/峰值负载验收。

整体新旧耗时环境不同，**不能把全部约5秒差异都归因于单条查询，更不能据此判定公司截图唯一原因**。可归因的结构与等价证据如下。

## 唯一生产修改及同数据证明

生产只修改 `MaterialAnalysisWarehouseBreakdownReader`，未改Service/aggregate写流程、迁移、旧单、权限、写入上限、超时或跨请求缓存。

- 原按dimension×warehouse执行LATERAL own_qty，改为相同合法维度/仓范围内 `MATERIALIZED own_quantities` 一次聚合。保留tracked优先、beneficiary active、owner、状态/删除/剩余量及颜色NULL规则；使用EXISTS避免同SKU多显示单位重复累计。
- 保留权威 `v_stock_available`，显式下推已存在的goodsIds范围，避免先计算无关库存的计量函数；所有仓、行与原14个结果字段保留。
- Root原始诊断22维×74仓=1628行。标准pg_dump捕获原长轮稍后状态恢复到本任务私有PG，已有96仓；在这个**相同恢复快照**对照旧新查询，输出2112行。未用不同规模对照耗时。
- 恢复快照全部51个活动analysis，共26496行×14字段，在同一只读RR事务中按完整身份规范排序，前后JSON**原字节完全相同**；含7个own_qty非零scope，实际6个untracked/1个tracked活动reservation。每scope原始JSON与SHA保留在 `warehouse-multistate-1/rows/` 和comparison.json。
- 提交中的真实Reader SQL已与上述比较模板做token对照，只忽略注释/空白，结果一致：`warehouse-multistate-1/production-template-input.json`。

同快照ANALYZE后EXPLAIN ANALYZE（规划/执行分开）原件在 `warehouse-probe-2/`：

| 查询 | planning ms | execution ms | rows |
|---|---:|---:|---:|
| 原查询 | 58.912 | 71.443 | 2112 |
| ownQuantities一次聚合 | 53.734 | 53.016 | 2112 |
| 原查询+显式goods范围 | 49.641 | 47.789 | 2112 |
| 两项组合 | 47.764 | 32.050 | 2112 |

原own聚合2112 loops改为新一次聚合。实际服务warehouse查询四次总计由原记录761.8679ms到v1无注入24.5921ms/并发35.9298ms；不同环境的其余SQL也变快，因此这只是同形实测，归因以相同恢复快照的结构对照为准。loadSourceLines、downstreamReferences另留真实未改构造SQL及计划，未为了凑速度更改其业务语义。

## 原件、限制和后续

`runs/warehouse-v1-199bb-1/` 保留完整maven.log、两份XML、源起止及原始JDBC统计；`interim-timing-comparison.json` 只提取原map，不改原日志。`warehouse-v1-manifest.json` 按源Git blob/原始文件字节分别指纹，包含本地被Git忽略的14.7MB快照和全部逐scope JSON。

快照SHA-256为 `6fc6dad39d6b40671f8425ea1e24711dd9d40ddb0b7e4e3719f3f9c6b859ba30`。原Root测试长轮未暂停/取消/改库。恢复使用no-owner/no-privileges，故查询对照不单独证明权限；真实业务与角色边界由完整原35服务组验证。工具的首次Docker临时postmaster连接失败、UTF-8读取/探针编译失误均原样保留，不当成产品反例。

42执行之后仅补了新增**测试**的启动超时/中断关闭读取线程及恢复中断标志，javac通过；生产Reader未再变化。该收尾改动不能冒称已经执行在上述199bb轮次，后续统一候选回归使用新源码。

后续整合须明确新SHA，按新的候选继续适用回归；D3的7b证据保持7b，不能重标。公司原单/目标设备与真实峰值并发缺失时列现场步骤：相同20×合法来源、原10秒、实际岗位并发操作，分开记录SQL/锁等待和失败；不从本地合成样例推定公司截图唯一原因。

未合并main、推送、部署或正式打包。
