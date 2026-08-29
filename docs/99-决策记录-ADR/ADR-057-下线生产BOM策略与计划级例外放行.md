# ADR-057：下线货品「生产 BOM 策略」与计划级 BOM 例外放行

- 日期：2026-08-29
- 状态：已接受
- 取代：ADR-029 中「三策略（BOM_REQUIRED / DIRECT_MAKE / NOT_PRODUCED）+ `production_material_analysis:bom_override` 逐计划例外放行」的口径
- 迁移：V423__remove_production_bom_policy.sql

## 背景

ADR-029 引入货品主档 `goods.production_bom_policy`，把「是否要求维护 BOM」做成主档治理事实：
未维护 BOM 的自制件在物料分析页被标为「资料异常：该产品要求 BOM，但未维护有效 BOM」，
生成计划前必须由持有 `production_material_analysis:bom_override` 权限的人逐产品填写例外原因。

实际运行反馈：这套主档策略与例外流程把「有没有维护 BOM」变成了排产前置门槛，
计划员被资料完整性卡住，而业务真正关心的只有一件事——**自制时子层级物料是否齐套**。

## 决策

1. **删除货品「生产 BOM 策略」**：`goods.production_bom_policy` 列、货品编辑表单项、
   导入/详情/列表 DTO 全部下线。货品是否维护 BOM 回归为普通资料事实，不再是排产闸门。
2. **删除计划级 BOM 例外放行**：`production_plans.bom_override_reason / bom_override_by`、
   `bomOverrides` 请求字段、`production_material_analysis:bom_override` 权限、
   物料分析页「填写资料异常继续原因」对话框全部移除。
3. **齐套语义收敛为「有 BOM 看子层级，无 BOM 即直接自制」**：
   - 有 BOM → 物料分析照旧展开子层级物料并做生产硬门槛齐套计算；
   - 无 BOM → 无子层级物料需求，`readyNow = 剩余需求全额`，可直接生成计划，
     执行段落位为 `ZERO_MATERIAL / DIRECT_MAKE`（证据 = 物料分析事实，
     V249 的 CHECK 约束与证据列保持不变，历史 `PLAN_BOM_OVERRIDE` 段继续可读可审计，
     但新段不再产生该原因）。
4. **待排产看板去掉「BOM 缺失」异常口径**：`bom_missing` facets 桶、`bomReady` 行标红、
   「BOM资料异常」状态与「一键转发研发」批量入口下线（权限 `production_plan:forward_rd`
   一并删除）；facets 收敛为「紧急/正常」两桶。研发任务中心保留，存量 BOM 任务照常流转。
5. **计划单「从订单带明细」不再拦截无 BOM 行**：无 BOM 产品按直接自制带入，提示改为
   说明性文案（无下层物料、不生成领料明细）。

## 影响的链路口径

- 物料分析候选：不再按 `production_bom_policy <> 'NOT_PRODUCED'` 过滤销售订单行；
  「所选货品明确标记为不生产，不能进入生产物料分析」「生产需求货品已改为不生产」
  两条校验删除。
- 生成计划：预览/生成不再接受 `bomOverrides`；「所选批次数量尚未完整齐套，
  不能生成正式计划」成为唯一数量闸门。
- 执行段授权：无 BOM 行只要挂有物料分析事实即授权为 DIRECT_MAKE 零料段；
  遗留（无分析事实）行仍被 `ProductionPlanningRequestValidator` 拦截，
  提示改为「缺少物料分析事实」。
- 销售进度/候选行 DTO 不再输出 `productionBomPolicy`。

## 风险与对策

- 风险：无 BOM 产品不再有资料闸门，可能把本应有 BOM 的组装件直接投产。
  对策：齐套计算仍以 BOM 为准——只要维护了 BOM，子层级硬门槛照常拦截；
  计划员在物料分析页仍能看到该产品无子层级物料的展示事实。
- 历史证据完整性：V423 只删列与权限，不改写存量执行段的冻结证据
  （`zero_material_exception_reason / zero_material_authorized_by`）。
