# ADR-057：下线货品「生产 BOM 策略」与计划级 BOM 例外放行

- 日期：2026-08-29
- 状态：已接受
- 取代：ADR-029 中「三策略（BOM_REQUIRED / DIRECT_MAKE / NOT_PRODUCED）+ `production_material_analysis:bom_override` 逐计划例外放行」的口径
- 迁移：V423__remove_production_bom_policy.sql；V426__strengthen_direct_make_analysis_lineage.sql

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

### 多层自制与执行口径

“有 BOM 看子层级”只表示**当前 MAKE 层检查自己的直接子件**，不是把整棵 BOM 扁平后交给
根计划一次领料。完整树仍用于计划前分析、路径展示和自底向上安排：

1. 根产品只以自己的直接 BOM 生产硬门槛计算 `ready_finish_qty`；
2. 直接子件已有目标仓合格现货时，父层可直接使用该现货；只有未覆盖短缺继续向下分析；
3. 短缺子件选择 MAKE 时，先检查该子件的直接下层。下层未齐只显示“下层备料中”，不得
   创建正式子计划、预留或领料单；
4. 下层齐套后才创建/定位系统 `MAKE_COMPONENT` child，由 child 独立生成计划草稿并审批；
5. child 批准后形成自己的执行段、直接层需求、预留和 DRAW；仓库真实发料、开工、报工、
   FQC 放行并由仓库点收入库后，父分析才把该子件作为合格现货重新计算；
6. 无直接 BOM 的当前层是合法叶子：按剩余需求全额可安排，形成
   `ZERO_MATERIAL / DIRECT_MAKE`，不创建空物料需求、空预留或空 DRAW。

这一定义避免同一深层物料同时被父计划和 child 重复需求、重复预留或重复领料。

### 计划详情的当前读模型

物料分析生成的计划详情不再提供旧的“物料需求只读估算（MRP）→预排/补建正式计划包”
写入口。当前详情以已冻结的执行分段、真实子计划、正式物料需求、reservation、DRAW/issue、
报工、FQC 和 FINISHED_IN 点收为准：

- `DEMANDED` 显示直接层需求及“已预留 / 已发料 X/Y”；
- `ZERO_MATERIAL / DIRECT_MAKE` 显示“无下层领料物料，可直接自制”，空物料表是正常状态，
  不得再显示“资料异常”“缺少有效 BOM”或要求补 BOM；
- `PLAN_BOM_OVERRIDE` 只允许在历史已冻结执行段中只读展示和审计，新请求、新执行段和新页面
  均不得再创建或提供放行入口；
- 旧计划若缺少物料分析来源，只能提示“缺少物料分析事实，请从物料分析准备重新生成”，
  不能重新解释为必须维护 BOM。

## 影响的链路口径

- 物料分析候选：不再按 `production_bom_policy <> 'NOT_PRODUCED'` 过滤销售订单行；
  「所选货品明确标记为不生产，不能进入生产物料分析」「生产需求货品已改为不生产」
  两条校验删除。
- 生成计划：预览/生成不再接受 `bomOverrides`；「所选批次数量尚未完整齐套，
  不能生成正式计划」成为唯一数量闸门。
- 执行段授权：无 BOM 行必须同时匹配当前计划、来源计划行、精确分析 item 及货品/颜色/单位，
  并证明当前 BOM 与冻结分析快照都没有物料行，才可授权为 DIRECT_MAKE 零料段；遗留
  （无精确分析谱系）行仍被 `ProductionPlanningRequestValidator` 拦截，提示改为
  「缺少物料分析事实」。
- 销售进度/候选行 DTO 不再输出 `productionBomPolicy`。

## 风险与对策

- 风险：无 BOM 产品不再有资料闸门，可能把本应有 BOM 的组装件直接投产。
  对策：齐套计算仍以 BOM 为准——只要维护了 BOM，子层级硬门槛照常拦截；
  计划员在物料分析页仍能看到该产品无子层级物料的展示事实。
- 历史证据完整性：V423 只删列与权限，不改写存量执行段的冻结证据
  （`zero_material_exception_reason / zero_material_authorized_by`）。

## 继续保留的安全校验

下线的是“有没有 BOM 的主档策略门槛”，不是 BOM、库存或执行安全门槛。以下规则继续
fail-closed：

- 只要当前层存在 BOM，就必须校验循环/超过最大层级、非正用量、失效组件、UUID 颜色与基本
  单位、包装/批次计量、控制阶段和 `hard_gate`；不得把坏 BOM 当作“无 BOM”直接生产；
- 分析 item、计划、计划行和执行段必须以 UUID 精确关联；无 BOM 直接自制也必须有当前有效的
  物料分析事实，遗留无来源计划不得据空物料集合自行放行；
- 生成/批准继续校验分析版本、BOM/规则指纹、目标仓、完整套料上限、对象权限、幂等键和稳定
  锁序；普通 generate 不预留，approve/显式 approveNow 才原子形成 READY/预留/DRAW；
- 在途、待检、冻结、不合格和未入目标仓数量不能计入当前齐套；分析软分配不能冒充
  `stock_reservations`；
- DEMANDED 段全部正式需求实际发料后才可开工；只有 IN_PROGRESS 可报工；FQC PASS 只产生
  待点收入库资格，只有仓库实收增加库存和 `iqty`；
- 已批准的物料形状、历史零料证据、预留、领退料、报工、质量决定和入库采用不可变或追加式
  反向，不因本 ADR 删除历史证据。

## V426 逐行谱系守卫与发布边界

V423 删除策略字段后，计划级 `material_analysis_id` 单独存在仍不足以证明某一条无 BOM 执行段
合法。V426 只向前替换 `fn_guard_execution_segment_requirement_shape()`，不修改 V249/V423
已应用字节，并对新 `ZERO_MATERIAL / DIRECT_MAKE` INSERT 增加以下逐行证明：

1. `source_plan_item_id` 必须属于当前 `plan_id`，且计划行未删除；
2. 计划必须同时绑定精确 `material_analysis_id + material_analysis_item_id`，分析 item 未删除；
3. 执行段、来源计划行和分析 item 的 goods/color/unit 必须逐项一致，颜色用 NULL-safe 比较；
4. `zero_material_analysis_id` 必须等于计划绑定的分析 ID；
5. 当前货品不能存在有效 `goods_bom_items`，冻结分析 item 也不能存在 active material 行；
6. 零料原因 NULL、错行/错产品/错颜色/错单位、只有计划级 analysis ID、当前或冻结快照已有
   物料行时均由数据库拒绝；READY 起步和物料形状不可变守卫继续保留。

`NO_PRODUCTION_HARD_GATE` 继续要求“BOM 存在且没有 START/ASSEMBLY/FINISH 硬门槛”。
`PLAN_BOM_OVERRIDE` 不在 V426 新建允许集合中，只保留历史冻结段读取。

V426 是安全前向候选，不是部署授权。Flyway 顺序意味着低于 V425 的环境若升级到 V426 会先执行
V425；**批准 V426 不等于批准跨越或执行尚未独立批准的 V425**。在 V425 的影响、备份、恢复、
审计留存和回滚方案单独评审通过，并完成目标非空库迁移演练、V423→V426 谱系负测、真实岗位
UAT 与部署回读前，目标库升级和生产写能力均保持 **NO-GO**。不得为单独取得 V426 而改写
Flyway 版本、跳过 V425、修改 schema history 或复制函数 SQL 到目标库。
