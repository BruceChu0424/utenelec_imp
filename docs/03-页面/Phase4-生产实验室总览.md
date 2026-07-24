# Phase 4 — 生产 / 实验室端总览

> **⚠️ 2026-07-24 权限模型重构**：角色体系已下线（[ADR-011](../99-决策记录-ADR/ADR-011-工作台部门分区与动态权限配置.md)）。本文中"按角色分权/角色端"的表述仅作历史参考——现行权限 = 全员基础 ∪ 部门配置（含上级部门）± 个人覆盖，由超管在权限管理页按部门配置。


> **lab（实验室）+ production（车间）角色端**总纲，10 个页面，覆盖质量检测、设备控制、生产、库存。
> 上层：[页面总览](页面总览.md)。全局机制见 [全局机制](../05-架构/全局机制.md)。

---

## 一、定位

实验室技术员上传检测数据、出报告；车间/设备人员控制楼栋空调、看流水线进度、录产量；仓管管库存。**平板 + 手机**为主，车间现场多用平板。

## 二、页面清单

| # | 页面 | 路由 | 角色 |
|---|---|---|---|
| 1 | 检测上传 | `/lab/test/upload` | lab |
| 2 | 检测列表 | `/lab/test` | lab |
| 3 | 检测报告 | `/lab/test/:id` | lab |
| 4 | 空调设备总览 | `/hvac` | production |
| 5 | 空调控制 | `/hvac/:id` | production |
| 6 | 流水线看板 | `/production/line` | production |
| 7 | 产量录入 | `/production/output/entry` | production |
| 8 | 产量统计 | `/production/output` | production |
| 9 | 库存查询 | `/inventory` | production |
| 10 | 出入库记录 | `/inventory/movement` | production |

## 三、角色权限

| 页面 | lab | production | manager | admin | 其他 |
|---|---|---|---|---|---|
| 检测* | ✅ | ❌ | ✅只读 | ✅ | ❌ |
| 空调* | ❌ | ✅ | ✅只读 | ✅ | ❌ |
| 流水线/产量* | ❌ | ✅ | ✅只读 | ✅ | ❌ |
| 库存* | ❌ | ✅ | ✅只读 | ✅ | ❌ |

权限点：`lab:test:view/upload`、`production:view`、`inventory:view`（见 [全局机制 §1.2](../05-架构/全局机制.md#12-角色与权限点)）。

## 四、共同特征
- **平板优先**：多为数据录入/看板，桌面/平板用 DataTable + 看板，手机简化。
- **车间现场**：性能档多为 lite/standard，重动画慎用。
- **视角选择器**：产量统计、库存、流水线看板 manager 可切部门范围。
- **实时性**：空调状态、流水线进度后端接入后走轮询/SSE（前端阶段 Mock）。

## 五、依赖组件
`UtenDataTable`、`UtenForm`、`UtenChartPlaceholder`、`UtenStatCard`、`UtenStatusBadge`（合格/不合格、设备在线/离线）、`UtenSwitch`/`UtenSlider`（空调控制）、`UtenConfirmDialog`、`UtenEmpty`。

## 六、涉及实体（需细化入实体字典）
`LabTest`/`LabSample`/`LabReport`/`LabEquipment`（实验室）；`HvacDevice`/`Building`/`Floor`（空调）；`ProductionLine`/`ProductionShift`/`ProductionOutput`/`ProductionOrder`/`Product`（生产）；`Material`/`InventoryStock`/`InventoryMovement`/`Warehouse`（库存）。

## 七、推进顺序
实验室（检测上传→列表→报告）→ 空调（总览→控制）→ 流水线看板 → 产量（录入→统计）→ 库存（查询→出入库）。

---

**最后更新**：2026-07-22 · **状态**：总览定稿
