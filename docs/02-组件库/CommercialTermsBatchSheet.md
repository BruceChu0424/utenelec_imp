# CommercialTermsBatchSheet 统一设置条款批量面板

> 源码：[`lib/shared/widgets/commercial_terms_batch_sheet.dart`](../../lib/shared/widgets/commercial_terms_batch_sheet.dart)
> 引入：2026-09-03（ADR-068 行级商业条款改造）；最后核对：2026-09-03。

## 一、职责与交互

订货单明细**多选行批量写条款**的底部面板：勾选 N 行 → 操作条「统一设置条款 (N)」→
一次写供应商+结账(结算)方式+币种+汇率+税率。

- **留空的项保持各行原值**（返回体对应字段为 null）；全部留空、汇率 ≤0、税率越界时
  应用被拦截（面板不关闭，顶部通知提示）。
- 供应商行内嵌滑入选择面板（分类树+搜索+可内联新建，同表头选商交互）。
- `partyNoun`（供应商/委外商）与 `settlementLabel`（结账方式/结算方式）由调用方注入，
- 取消返回 null；应用返回 `CommercialTermsBatchResult`。

## 二、对外契约

```dart
Future<CommercialTermsBatchResult?> showCommercialTermsBatchSheet(
  BuildContext context, WidgetRef ref, {
  required int selectedCount,
  required Map<String, String> currencyEntries,   // 币种字典
  required Map<String, String> settlementEntries, // 结算方式字典（启用中）
  String partyNoun = '供应商',
  String settlementLabel = '结账方式',
});
```

## 三、已接入页面

- 采购订货单专属编辑页 `_batchSetTerms`（编辑既有单时写全部行，保持一单一套条款）。
- 委外订货单专属编辑页 `_batchSetTerms`（同上）。

## 四、验证

- [`commercial_terms_batch_sheet_test.dart`](../../test/shared/widgets/commercial_terms_batch_sheet_test.dart)
  （留空语义、非法值拦截、结果字段）
