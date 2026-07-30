# ER 草图

> ⏳ **随实体字典生长的活文档**。新增实体关联时同步更新本图。
> 这里只画**概念模型**（实体 + 关系），不画物理表结构。

---

## 一、整体概览

```mermaid
erDiagram
    User ||--|| Employee : "1对1"
    Employee }o--|| Department : "属于"
    Employee }o--|| Position : "担任"
    Department ||--o{ Department : "父子"
    Employee ||--o{ PayrollSlip : "收到"
    Employee ||--o{ ExpenseClaim : "申请"
    Employee ||--o{ Notice : "发布(hr)"
    Employee ||--o{ Suggestion : "提交"
    Employee ||--o{ LabTest : "上传(lab)"
    Employee ||--o{ ProductionOutput : "录入"
    PayrollSlip ||--|{ PayrollItem : "包含"
    ExpenseClaim ||--|{ ExpenseItem : "包含"
    ExpenseClaim ||--o{ ExpenseApproval : "经过"
    Notice ||--o{ NoticeReadRecord : "被读"
    Suggestion ||--o{ SuggestionReply : "回复"
    LabTest ||--|| LabSample : "测"
    LabTest ||--|| LabReport : "产出"
    HvacDevice }o--|| Building : "在"
    HvacDevice }o--|| Floor : "在"
    Building ||--|{ Floor : "包含"
    HvacDevice ||--o{ HvacCommand : "被控"
    ProductionLine ||--o{ ProductionOutput : "产出"
    ProductionShift ||--o{ ProductionOutput : "班次"
    ProductionOrder ||--o{ ProductionOutput : "工单"
    Product ||--o{ ProductionOutput : "产品"
    Material ||--o{ InventoryStock : "库存"
    Warehouse ||--o{ InventoryStock : "在"
    InventoryMovement }o--|| Material : "物料"
    InventoryMovement }o--|| Warehouse : "仓库"
```

> 当前是骨架图，字段暂略。字段在 [实体字典.md](实体字典.md) 中维护。

---

## 二、分模块详图

### 2.1 组织架构

```mermaid
erDiagram
    User ||--|| Employee : "1对1"
    Employee }o--|| Department : "属于"
    Employee }o--|| Position : "担任"
    Department ||--o{ Department : "父子部门"
    Employee ||--o{ EmploymentHistory : "经历"
```

### 2.2 工资

```mermaid
erDiagram
    PayrollBatch ||--|{ PayrollSlip : "包含"
    PayrollSlip ||--|{ PayrollItem : "明细"
    PayrollSlip }o--|| Employee : "归属"
```

### 2.3 报销

```mermaid
erDiagram
    ExpenseClaim ||--|{ ExpenseItem : "明细"
    ExpenseClaim ||--o{ ExpenseApproval : "审批流"
    ExpenseItem }o--|| ExpenseCategory : "归类"
```

### 2.4 通知与建议

```mermaid
erDiagram
    Notice ||--o{ NoticeReadRecord : "已读"
    Suggestion ||--o{ SuggestionReply : "回复"
```

### 2.5 实验室

```mermaid
erDiagram
    LabTest ||--|| LabSample : "测样品"
    LabTest ||--|| LabReport : "产出报告"
    LabTest }o--|| LabEquipment : "用设备"
```

### 2.6 设备控制

```mermaid
erDiagram
    Building ||--|{ Floor : "含楼层"
    Floor ||--o{ HvacDevice : "装空调"
    HvacDevice ||--o{ HvacCommand : "指令历史"
```

### 2.7 生产

```mermaid
erDiagram
    ProductionLine ||--o{ ProductionOutput : "产出"
    ProductionShift ||--o{ ProductionOutput : "班次"
    ProductionOrder ||--o{ ProductionOutput : "工单"
    Product ||--o{ ProductionOutput : "产品"
    ProductionLine ||--o{ ProductionShift : "排班"
```

### 2.8 库存

```mermaid
erDiagram
    Material ||--o{ InventoryStock : "余量"
    Warehouse ||--o{ InventoryStock : "存放"
    InventoryMovement }o--|| Material : "物料"
    InventoryMovement }o--|| Warehouse : "仓库"
```

### 2.9 审批流（未来目标，不是当前 ER）

> 当前 V133 没有 `ApprovalNode` 或 `ApprovalRecord` 表：报销与工资分别把固定流程的状态、
> 操作人和时间戳保存在 `expense_claims`、`payroll_batches`。下图仅是业务决定采用可配置多级
> 审批后才考虑的目标模型，不能用于当前数据库建表或迁移对账。详见 [实体字典](实体字典.md) 与
> [全局机制 §三](../05-架构/全局机制.md#三审批流建模可配置多级)。

```mermaid
erDiagram
    ApprovalNode ||--o{ ApprovalRecord : "定义节点"
    ExpenseClaim ||--o{ ApprovalRecord : "expense 审批轨迹"
    PayrollBatch ||--o{ ApprovalRecord : "payroll 审批轨迹"
    ApprovalRecord }o--|| Employee : "审批人"
```

---

## 三、关联类型说明

| 符号 | 含义 |
|---|---|
| `||` | 强制 1 |
| `}o` | 可选多（0 或 N） |
| `o{` | 可选多 |
| `|{` | 强制多（1 或 N） |

例如 `Employee }o--|| Department` 表示：一个员工属于 0 或 1 个部门，一个部门有多个员工。

---

## 四、待定问题

> 关系还没完全想清楚的地方。

- [ ] User 和 Employee 是否真的一对一？（兼职/外协人员怎么算？）
- [ ] 一个员工能否同时属于多个部门？（兼任）
- [ ] 报销审批是单级还是多级？多级的话审批流实体怎么建模？
- [ ] 工资条是按月一条还是按批次？
- [ ] 老系统数据迁移时，缺失的关联关系如何补？
- [ ] 多厂区场景下，Building 和 Department 怎么关联？

---

**最后更新**：2026-07-21 · **状态**：骨架已立，待随页面细化
