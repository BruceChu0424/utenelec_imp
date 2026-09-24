# UtenRevisionTable

源码：[`uten_revision_table.dart`](../../lib/components/data_display/uten_revision_table.dart)。

适用于所有业务模块的修改后重新提交、退回修改复审和同类申请对照。它只负责显示，不读取业务接口，不决定两个版本如何配对。

## 明细表

`UtenRevisionTable<T>` 接受原表的 `List<MasterColumnDef<T>> columns` 与按业务顺序组装的 `List<UtenRevisionRow<T>> rows`，自动增加变更状态列：

| kind | 显示 | 用法 |
|---|---|---|
| `unchanged` | 中性普通行 | 两版商业内容相同 |
| `removed` | 红底红字、贯穿整行删除线 | 被修改或删除的原完整行 |
| `added` | 绿底绿字 | 被修改后的完整行，或纯新增行 |

同一行发生修改时，依次传入 removed 旧行与 added 新行。新行的 `changedKeys` 填实际变化字段对应的 `MasterColumnDef.key`；这些单元格红字加粗，其他字段仍为绿字。即使只改数量也要传两条完整行。纯新增没有旧值，`changedKeys` 保持空集合；纯删除没有新增行。

```dart
UtenRevisionRow(
  value: before,
  kind: UtenRevisionKind.removed,
),
UtenRevisionRow(
  value: after,
  kind: UtenRevisionKind.added,
  changedKeys: {'qty', 'amountOriginal'},
),
```

字段 key 与业务显示值同源，不能把 `qty` 写成列标题“数量”后期待自动匹配。数值比较先统一十进制末尾零，编号和票号等字符串不能这样规范化。自动重排行号、审核人和核验状态不属于申请人修改内容。

底层保留 `MasterDataTableView` 列宽、横向滚动、全屏和复制能力。`embedded`、`primary`、`stickyHeaderPinned`、`bottomContentPadding` 按原宿主表的滚动方案传入。`summaryBar` 只能来自本次单据合计，不能计算包含旧行的显示集合。

对照列使用纯文本值，不复用原列上的编辑或业务操作按钮，旧记录始终只读。

## 非明细字段

`UtenRevisionFields(changes: List<UtenRevisionField>)` 展示标题、日期、地址、条款等变化字段。每项包含 `label`、`before`、`after`，旧值红色划线，新值绿底、实际变更文本红色加粗，长文本允许换行。

## 数据边界

- 版本来自业务提交或决策快照。旧信息未保存时明确提示，不能复制最新信息充当历史。
- 同一货品的多行保留各自身份。编辑会重建 UUID 时，先匹配完整内容并保留重复次数；仅在对应关系唯一时组成旧/新对，歧义行分别删除和新增。
- 金额必须属于该行自身币种；版本之间币种变化时不能沿用当前币种给旧金额加标签。
- 各流程只对比本流程的前次与本次提交，不把资产初始确认、处置和终止三类申请互相配对。

逐页接入与验证记录见[重新提交审批差异展示](../03-页面/重新提交审批差异展示.md)。
