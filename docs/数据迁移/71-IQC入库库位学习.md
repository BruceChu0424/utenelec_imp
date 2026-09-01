# 71 - IQC 入库库位学习（V451）

> 日期：2026-09-01
>
> 迁移版本：V451（前向候选；以同一受保护构建中的实际 SQL、manifest 和测试证据为准）
>
> 决策依据：[ADR-058](../99-决策记录-ADR/ADR-058-生产成品仓库送检登记与库位快照.md)、[迁移说明 65](65-仓库货品库位偏好.md)
>
> 状态：设计与验收边界已冻结；目标非空库迁移、岗位 UAT、恢复和部署回读完成前，生产 **NO-GO**

## 一、问题与目标

V431 建立了 `warehouse_goods_place_preferences`（仓库×货品×颜色 → 建议库位），
但只有**产成品到货登记**能写它。采购/委外 **IQC 合格品入库确认**从不回写：
`placeHint = COALESCE(preference.place, goods.stock_place)` 里两项长期为空，
「上次成功入库这个产品/原料的库位自动带出」整体失效（V451 前的实际线上行为）。

V451 让 IQC 仓库确认入库成为第二个学习来源：

1. 确认成功后在同事务内 upsert 偏好行（`source_kind = 'IQC_STOCK_IN'`）；
2. 下一次同仓库、同货品、同颜色的待入库明细 `placeHint` 自动带出该库位；
3. 货品主档 `goods.stock_place` 与本次不同才回写——货架目视化清单、即时库存等
   按主档展示库位的页面随之同步最新建议库位（与到货登记 `applyGoodsProfileHints`
   同口径：仅 `stock_place`，不碰编码/系列，带 version/审计）。

## 二、数据模型变化

`warehouse_goods_place_preferences` 来源维度泛化，其余不变：

| 变化 | 内容 |
|---|---|
| `source_registration_id` | `DROP NOT NULL`（FINISHED_ARRIVAL 行仍必须非空，由互斥约束接管） |
| `source_kind` 新增 | `TEXT NOT NULL DEFAULT 'FINISHED_ARRIVAL'`，CHECK 限 `FINISHED_ARRIVAL / IQC_STOCK_IN` |
| `source_iqc_batch_id` 新增 | `UUID NULL`，FK `procurement_iqc_stock_in_batches(id)` RESTRICT |
| 互斥 CHECK | `warehouse_goods_place_preference_source_chk`：按 kind 二选一，另一个来源列必须为 NULL |
| 索引 | `idx_warehouse_goods_place_preference_iqc_batch`（来源批次反查） |

纯前向 DDL：不建表、不回填历史、不改任何存量行（存量行全部满足 FINISHED_ARRIVAL 分支）。
维度唯一约束 `warehouse_goods_place_preference_dimension_uk`、审计触发器、
`fn_set_updated_at()` 均沿用 V431，无变化。

## 三、学习行为合同（`ProcurementIqcStockInService`）

学习只发生在**新鲜确认路径**（单张 `confirm` 与批量 `batchConfirm` 共用 `confirmOne`）：

- 幂等重放：`confirmOne` 开头命中已有批次即提前返回，不进入学习——
  同批次重试不重复增加 `selection_count`；
- 维度去重：按 `warehouse × goods × color` 分组，同维度多行**同值**只 upsert 一次；
- 歧义拒绝：同维度本次出现**不同库位**时该维度不学习（与产成品登记同口径，禁止最后一行覆盖）；
- 时序保护：upsert 的 `DO UPDATE ... WHERE` 按
  `(source_registered_at, 来源UUID)` 严格小于才接受——旧来源不能覆盖新偏好
  （FINISHED_ARRIVAL 与 IQC_STOCK_IN 行之间同样成立，时间戳为主、UUID 决胜）；
- 主档回写：`UPDATE goods SET stock_place ... WHERE 当前值 IS DISTINCT FROM 本次库位`，
  空白值视为空；失败即整体回滚（与确认同事务，不存在"入库成功但学习失败"的半态）；
- 学习写入者：`last_selected_by = 确认操作者 employeeId`，`created_by/updated_by = 操作用户`，
  权限沿用 `warehouse_iqc_stock_in:view + confirm`，不新增权限点。

学习是确认事务的组成部分，不是独立可重试动作（与产成品"登记后单独记住"不同）：
确认成功学习必然成功；任何一行不满足约束时整单确认失败回滚。

## 四、兼容与回退

- 旧数据：V451 前的偏好行全部是 FINISHED_ARRIVAL，语义不变；
- 旧客户端：无感知——不学习时 `placeHint` 行为与 V446 完全一致；
- 显示页同步：货架目视化清单、即时库存、出入库记录的库位列继续读 `goods.stock_place`，
  由主档回写保持最新，不改这三个页面的查询；
- 功能回退：关闭 V451 学习调用（或回退到 V450 构建）即可恢复"只读主档"旧行为；
  偏好表与已学数据保留，Flyway exact-set 不允许用缺 V451 的旧 JAR 覆盖新 schema；
- `server/ops/reset_business_data.sql` 白名单已扩到 V451/413，
  并新增四构件在场校验（kind 列、批次列、互斥约束、索引）。

## 五、最低验收矩阵

- 迁移：空库、V431→V451 升级、存量行 kind 默认值、互斥 CHECK 拒绝非法规格、索引/注释在场；
- 学习：首次确认落行（kind=IQC_STOCK_IN、来源批次、计数 1）、同幂等键重放不重复计数、
  同维度同值去重、同维度异值拒绝、旧时间戳来源不覆盖新偏好、跨 kind 覆盖按时间戳裁决；
- 主档：非空→不同值更新、相同值跳过、空白→填入、version/updated_at/updated_by 推进；
- 集成：`FullChainEndToEndTest#concurrency_idempotentIqcStockInDoesNotDoubleCountStock`
  已覆盖 确认→学习→重放不翻倍→主档回写 全链；
- SQL 安全：学习与回写全部参数绑定（Mimosa 约束），无字符串拼接。

文档、契约测试或本地开发库通过均不代表目标库迁移、实物库位核对、仓库多账号 UAT、
恢复或发布完成；上述目标侧证据任一缺失，生产继续 **NO-GO**。
