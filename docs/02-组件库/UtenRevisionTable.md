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

## 单元格内旧新对照 UtenRevisionCell

源码：[`uten_revision_cell.dart`](../../lib/components/data_display/uten_revision_cell.dart)。使用方：员工资料核对更正页（ADR-160）在表格单元格内对照单个字段的旧值与新值。

`UtenRevisionCell(before, after, changedPositions, masked, emptyText, afterTrailing)` 在一个单元格里紧凑地渲染两行：上一行旧值红色删除线（为空时灰色占位文字、不加线）；下一行新值绿底加粗，`changedPositions`（1-based）指定的字符位红色加粗加下划线——证件号码这类逐位校对的字段，差在哪一位一眼可见。

| 参数 | 说明 |
|---|---|
| `before` | 修改前的值；null 或空串显示 `emptyText ?? '(空)'` 灰字 |
| `after` | 修改后的值；null 表示没有新值，不渲染新值行 |
| `changedPositions` | 新值中实际变化的字符位（1-based） |
| `masked` | 脱敏值不做逐位差异高亮（整行新值统一绿字） |
| `emptyText` | 旧值为空时的占位文字，默认「(空)」 |
| `afterTrailing` | 新值行尾部小部件（「采用」按钮/对勾） |

颜色全部复用 [UtenRevisionTable](#明细表) 的 `utenRevisionForeground` / `utenRevisionBackground` token 函数，明暗主题自动适配；`Semantics` 读出「修改前 X，改为 Y」。与 `UtenRevisionFields` 的分工：`UtenRevisionFields` 用于表头级字段对照——带 −/+ 前缀的上下两个容器，适合标题、地址这类长文本；`UtenRevisionCell` 用于表格单元格内——无前缀、内边距紧凑（h6 v2、圆角 4）的两行，适合并排呈现多列字段。字段既有表头级对照又有单元格级对照时，各用各的，不要互相替代。
