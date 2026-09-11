# UtenDraftsButton / UtenDraftCountSuffix（草稿入口与草稿计数）

> 源码：[`lib/components/buttons/uten_drafts_button.dart`](../../lib/components/buttons/uten_drafts_button.dart)、
> [`lib/components/feedback/uten_draft_count.dart`](../../lib/components/feedback/uten_draft_count.dart)、
> 数据源 [`lib/shared/providers/draft_counts_provider.dart`](../../lib/shared/providers/draft_counts_provider.dart)。
> 建立日期：2026-09-11（同日改版：hub 卡上的草稿数由红色徽章改为中性括号数字，
> 见 [徽章与计数口径](../00-项目准则/14-徽章与计数口径.md)）。

---

## 一、要解决的问题

各模块的「管理」卡片大多是 `skipListOnCreate: true`——从 hub 点卡片**直达新建页**，跳过列表。
这带来两个后果：

1. 用户从 hub 进来后**打不开该单据的列表**（销售订货单尤其明显：`SalesRoutePath.list` 只剩
   详情页删除/审核后的跳转在用）；
2. 保存成草稿的单据**没有任何入口**——用户不知道自己还有几张没提交的单。

`UtenDraftsButton` 补上这条路：新建页右上角显示「草稿(N)」，点进去就是该单据列表的草稿段。
`UtenDraftCountSuffix` 在 hub 单据卡标题后显示同一个 N，让用户在进页面之前就看见。

---

## 二、UtenDraftsButton

```dart
UtenDraftsButton(
  kind: DraftDocKind.salesOrder,
  listLocation: SalesRoutePath.list('orders'),   // 不带 query
)
```

| 参数 | 说明 |
|---|---|
| `kind` | `DraftDocKind` 枚举，决定取哪个计数字段与哪个 `*:view` 权限点 |
| `listLocation` | 该单据的列表路径（不带 query），如 `/sales/orders` |
| `label` | 按钮文案，默认「草稿」 |
| `countScopeNote` | 计数口径备注，追加进 tooltip；用于「按钮数字 ⊋ 落点列表」的场合（见 §五） |

**形态（2026-09-11 统一）**：不再自带 `size`，改为渲染共用的
[`UtenAppBarActionButton`](UtenAppBarActionButton.md)——**深绿实心 + 白字 + 固定 36 高**，
与同在顶栏的「权限设置」完全一致。此前草稿是 tonal 浅底深字、权限设置宽屏是裸 TextButton、
窄屏又是 IconButton，一个顶栏三种长相（用户要求「这些按钮颜色大小都统一起来」）。

行为契约：

- **文案**：n > 0 显示「草稿(n)」，n = 0 只显示「草稿」（不显示 `(0)`）。
- **权限**：没有该单据 `*:view` 权限（且非超管）时**整个按钮隐藏**——跳过去也是空列表。
- **降级**：计数加载中/失败按 0，按钮照常可点，只是暂不显示数字（不放大成异常态）。
- **导航**：`goFrom(context, '$listLocation?status=draft')`。
  必须用 `goFrom` 而不是 `push`——主 Tab 前缀下 `push` 会静默失效；`goFrom` 同时带
  `?returnTo`，列表页返回能回到新建页。
- **测试锚点**：`Key('uten-drafts-button')`。

接入点（全部是新建态、且 `skipListOnCreate` 的页面；编辑既有单据时不显示）：

| 页面 | kind |
|---|---|
| `sales_doc_edit_page`（报价/订货/出货/退货） | `salesQuote` / `salesOrder` / `salesShipment` / `salesReturn` |
| `purchase_order_edit_page`、`purchase_doc_edit_page` | `purchaseOrder` / `purchaseReceipt` / `purchaseReturn`（申请单是只读需求单，返回 null 不显示） |
| `subcontract_order_edit_page`、`subcontract_doc_edit_page` | `subcontractOrder` / `subcontractReturn` / `subcontractMaterialReturn` / `subcontractWaste`（询价/申请/回厂/历史发料返回 null） |
| `finance_doc_edit_page`（收款/付款/费用/其它收入/银行转账） | 五种 finance* |
| `stock_doc_edit_page` | `stockDocument` |
| `production_plan_edit_page` / `production_daily_report_edit_page` | `productionPlan` / `productionDailyReport` |

---

## 三、UtenDraftCountSuffix

```dart
UtenHubCard(
  ...,
  labelSuffix: const UtenDraftCountSuffix(kind: DraftDocKind.purchaseOrder),
)
```

渲染成**中性括号数字**（`采购订货 (3)`，内部是 `UtenCountSuffix`），挂在
`UtenHubCard.labelSuffix` 槽位；`count <= 0` 或无该类型 `*:view` 权限时不渲染、不占位。

接入的 hub 卡：销售（报价/订货/出货/退货）、采购（订货/收货/退货）、
委外（订货/成品退回/余料退回/损耗与责任）、钱流（收款/付款/费用/其它收入/银行转账）、
生产（生产计划/生产日报）、仓库（调拨/盘点）。

> **草稿不是「别人给我的待办」**，是本人未完成的工作，不处理也不会卡住任何人。
> 按[徽章与计数口径](../00-项目准则/14-徽章与计数口径.md)它属于「有多少条、供我掂量」的
> 浏览型计数：**必须用中性括号数字，不用红色 `UtenNotificationBadge`**，并且
> **永不进** hub 卡 / 工作台模块卡 / 导航 Tab 的待办累加
>（`lib/shared/badges/todo_badge_registry.dart` 里根本没有登记草稿源）——
> 否则会把个人草稿混进「有多少事等着我处理」的口径里，把数字放大。

---

## 四、数据源与口径

唯一数据源：`draftCountsProvider`（`FutureProvider.autoDispose<DraftCounts>`，60s 轮询 +
权限自卫），对应后端 `GET /api/documents/drafts/count`。

每类单据的服务端口径：

```sql
SELECT count(*) FROM <表> o
 WHERE o.is_deleted = false AND o.status = 0 AND <对象级归属谓词>
```

- 「对象级归属谓词」复用各模块 `DocumentAccessPolicy.nativeReadScope`，所以徽章数字与
  对应列表页的草稿段**永远同口径**（本人 + 数据范围授权 + 交接继承；`*:view:all`/超管全见）。
- 没有该类型 `*:view` 权限时后端固定返回 0（不查库），前端也不渲染——两层一致。
- **销售订货单额外要求 `finance_rejected = false`**：财务驳回单同样是 `status = 0`，但已计入
  销售关注徽章的 REJECTED 桶，草稿桶再数一次就是双计。故草稿徽章的语义是
  **「待自审的新建/修订草稿」**，驳回件继续走驳回徽章。

`DraftCounts` 实现了值相等，60s 轮询拿到相同数字时不会触发徽章/按钮的无谓重建。

---

## 五、已知口径差异：仓库单据

仓库 8 种单据类型（调拨/盘点/其它出入库/领料/退料/产成品进出仓）共用一张 `stock_documents`。
`stockDocument` 桶是**整模块合计**，而按钮落点列表只列当前类型；因此
`stock_doc_edit_page` 传了 `countScopeNote: '全部仓库单据合计'`，在 tooltip 里写清楚，
避免用户以为列表漏了单。

2026-09-11 补齐：后端在合计之外增加了两个 `doc_type` 切片
（`stockTransfer` = `doc_type='TRANSFER'`、`stockCheck` = `doc_type='CHECK'`），
仓库 hub 的「调拨」「盘点」两张卡各用自己的切片。

> ⚠️ 合计与切片会同时非零，**同一个界面只能用其中一种**：hub 上用切片、新建页按钮用合计。
> 两者混用就是把同一张单数两遍。后端契约测试
> `DocumentDraftCountSqlContractTest#stockDocumentSlicesAreMutuallyExclusiveSubsetsOfTheAggregate`
> 钉住「两切片互斥且都是合计的子集」。

---

## 六、列表页预选契约

按钮跳转到 `<列表路径>?status=draft`。各模块列表页从路由 query 读 `initialStatus`，用
`isDraftStatusQuery(widget.initialStatus)`（`draft_counts_provider.dart` 导出）判定后在
`initState` 里预选草稿段：

| 列表页 | 预选行为 |
|---|---|
| `sales_doc_list_page`（订货） | 选大类第 5 段「草稿」 |
| `sales_doc_list_page`（出货/退货/报价） | 选小类「草稿」段 |
| `purchase_doc_list_page` / `subcontract_business_list_pages` / `stock_doc_list_page` | 选「草稿」分段 |
| `finance_doc_list_page` / `production_plan_list_page` / `production_daily_report_list_page` | 状态筛选置「草稿」 |

`kDraftStatusQuery = 'draft'` 定义在 `draft_counts_provider.dart`，按钮与列表页共用，
避免这个字符串在十来个页面里各写一份走样。
