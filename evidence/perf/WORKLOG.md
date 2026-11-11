# B 20物料提交性能整改

基线为 `7b912287e53315228b469790ff066a9fab643e3c`。原 Root 聚合组35例只有原10秒门槛失败：实际10214ms，1105 SQL/JDBC8841.1267ms；warehouseBreakdown四次**合计**761.8679ms、loadSourceLines十次合计618.6189ms、downstreamReferences八次合计387.5701ms。原红保留在 Root `evidence/root/final-b-7b912-1/`，不以 quiet 单次绿覆盖。

Root B 测试库在原长轮继续期间以标准 pg_dump 一致性快照保全：`captured-root-b-1/root-b.dump`，14691638字节，SHA-256 `6fc6dad39d6b40671f8425ea1e24711dd9d40ddb0b7e4e3719f3f9c6b859ba30`。此为本地合成测试库，非公司库。大备份/逐分析JSON留本地，不纳Git。

恢复到本任务独立 `uten-feedback-perf-20261111` 容器、127.0.0.1:52159。首次恢复遇 Docker 初始化临时postmaster重启，在0表阶段连接失败；原环境日志保留。第二次在最终postmaster稳定后正常完整恢复，exit0；`--no-owner --no-privileges` 仅用于本地查询对照，不能据此宣称真实权限验收。恢复后独立ANALYZE，不改原Root测试库。

## 查询对照

Root最早原件是22维度×74仓=1628行；本快照在后续真实测试运行后已有96仓，同分析输出2112行。所有前后比较都在同一恢复快照进行，不拿不同规模互相比耗时。

`warehouse-probe-1` 第一轮原/候选14字段规范身份排序JSON原字节相同；候选单独将 per-dimension/warehouse LATERAL own_qty 改为只读范围内一次聚合，初次收益不足，未冒称解决10秒问题。

ANALYZE后 `warehouse-probe-2` 真实EXPLAIN观察：

| 查询 | planning ms | execution ms | rows |
|---|---:|---:|---:|
| 原查询 | 58.912 | 71.443 | 2112 |
| ownQuantities一次聚合 | 53.734 | 53.016 | 2112 |
| 原查询+已有goodsIds显式库存范围 | 49.641 | 47.789 | 2112 |
| 两项组合 | 47.764 | 32.050 | 2112 |

新查询仍消费权威 `v_stock_available`，不复制计量/库存公式；只显式下推已有 goodsIds 条件，避免先计算无关货品的计量函数。ownQuantities仍保留tracked优先、beneficiary active、真实owner、剩余量/状态/删除/颜色规则；用 EXISTS 而非 dimensions直接JOIN，避免同SKU多单位重复累计。未延长超时、扩大写入或缓存跨请求facts。

`warehouse-multistate-1` 在同一只读RR事务，遍历快照全部51个活动analysis、26496行×14字段，原/组合候选规范有序JSON原字节全部相同；包括7个own_qty非零scope，以及实际6个untracked/1个tracked活动reservation。各scope原件和SHA在 comparison.json/rows；原SQL对dimension同仓tie未规定次序，因此对照按warehouseCode/warehouseId/goodsId/colorId/unitId完整身份排序。

中途工具夹具失败（Python默认GBK读UTF-8、探针枚举名少写S）日志/失败源码均保留，不算产品反例。正确UTF-8探针最终全部对照通过。

## 实际服务验收待执行

生产目前只改唯一 `MaterialAnalysisWarehouseBreakdownReader`。原20物料方法保留原10秒及21批/计划1/采购总量400/原幂等重放断言；公共测试体增加一组同库真实 `analyses.detail` 并行读，验证真实重叠和完整物料身份，并独立记录writer和reader JDBC。原35方法仍需全部验，新增并行例单列，不把6例仓分解投影测试冒称完整业务账。

199bb真实服务后续已完成42/42：原35逐case全部保留且通过，新增并发1、仓投影6；quiet4172ms/同库真实detail并发4506ms（11次完整读取真实重叠）。详见ACCEPTANCE-warehouse-v1.md及summary/manifest，不以此覆盖原10214ms红或把所有加速归因于该查询。新代码后续必须进入同一整合候选继续适用回归；7b已完成的D3证据保持原SHA。
