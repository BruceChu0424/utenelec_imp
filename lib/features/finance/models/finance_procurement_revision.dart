import 'dart:convert';

import '../../../shared/formatters/exact_decimal.dart';
import 'finance_procurement_workflow.dart';

/// A submitted row and its successor. Missing sides mean addition or removal.
class FinanceProcurementRevision {
  const FinanceProcurementRevision({this.before, this.after});

  final FinanceProcurementReviewLine? before;
  final FinanceProcurementReviewLine? after;

  bool get unchanged =>
      before != null &&
      after != null &&
      before!.displaySnapshotComplete &&
      after!.displaySnapshotComplete &&
      _sameContent(before!, after!);

  bool get needsReview =>
      before != null &&
      after != null &&
      (!before!.displaySnapshotComplete || !after!.displaySnapshotComplete) &&
      _sameContent(before!, after!);
}

/// Draft edits can replace row UUIDs. Reserve exact matches first so repeated
/// goods and unaffected rows cannot accidentally be paired with changed rows.
List<FinanceProcurementRevision> procurementRevisionRows(
  List<FinanceProcurementReviewLine> before,
  List<FinanceProcurementReviewLine> after,
) {
  final remaining = after.toList();
  final matches =
      <FinanceProcurementReviewLine, FinanceProcurementReviewLine>{};
  for (final old in before) {
    final index = remaining.indexWhere((next) => _sameContent(old, next));
    if (index >= 0) matches[old] = remaining.removeAt(index);
  }
  for (final old in before.where((line) => !matches.containsKey(line))) {
    var index = remaining.indexWhere(
      (next) => old.orderItemId != null && old.orderItemId == next.orderItemId,
    );
    if (index < 0) {
      final candidates = remaining.where((next) => _sameIdentity(old, next));
      final oldCandidates = before.where(
        (line) => !matches.containsKey(line) && _sameIdentity(old, line),
      );
      if (candidates.length == 1 && oldCandidates.length == 1) {
        index = remaining.indexOf(candidates.single);
      }
    }
    if (index >= 0) matches[old] = remaining.removeAt(index);
  }
  return [
    for (final old in before)
      FinanceProcurementRevision(before: old, after: matches[old]),
    for (final added in remaining) FinanceProcurementRevision(after: added),
  ];
}

bool _sameIdentity(
  FinanceProcurementReviewLine a,
  FinanceProcurementReviewLine b,
) =>
    (a.goodsId ?? a.goodsCode ?? a.goodsName) ==
        (b.goodsId ?? b.goodsCode ?? b.goodsName) &&
    (a.colorId ?? a.colorName) == (b.colorId ?? b.colorName) &&
    (a.unitId ?? a.unitName) == (b.unitId ?? b.unitName) &&
    a.sourceItemId == b.sourceItemId;

bool _sameContent(
  FinanceProcurementReviewLine a,
  FinanceProcurementReviewLine b,
) => procurementChangedFields(a, b).isEmpty;

/// Table column keys whose values changed. Numeric scale differences are not
/// changes, and renumbering after deleting another row is not a goods edit.
Set<String> procurementChangedFields(
  FinanceProcurementReviewLine before,
  FinanceProcurementReviewLine after,
) => {
  if (before.goodsId != after.goodsId ||
      (before.displaySnapshotComplete &&
          after.displaySnapshotComplete &&
          before.goodsName != after.goodsName))
    'goods',
  if (before.displaySnapshotComplete &&
      after.displaySnapshotComplete &&
      before.goodsCode != after.goodsCode)
    'goodsCode',
  if (before.colorId != after.colorId ||
      (before.displaySnapshotComplete &&
          after.displaySnapshotComplete &&
          before.colorName != after.colorName))
    'colorName',
  if (before.unitId != after.unitId ||
      (before.displaySnapshotComplete &&
          after.displaySnapshotComplete &&
          before.unitName != after.unitName))
    'unitName',
  if (_decimal(before.unitRate) != _decimal(after.unitRate)) 'unitRate',
  if (_decimal(before.qty) != _decimal(after.qty)) 'qty',
  if (_decimal(before.price) != _decimal(after.price)) 'price',
  if (_decimal(before.amountOriginal) != _decimal(after.amountOriginal))
    'amountOriginal',
  if (_decimal(before.amountLocal) != _decimal(after.amountLocal))
    'amountLocal',
  if (before.currencyId != after.currencyId ||
      (before.displaySnapshotComplete &&
          after.displaySnapshotComplete &&
          before.currencyName != after.currencyName))
    'currencyName',
  if (before.deliverDate != after.deliverDate) 'deliverDate',
  if (before.sourceItemId != after.sourceItemId) 'sourceApplicationNos',
  if (before.displaySnapshotComplete && after.displaySnapshotComplete) ...{
    if (before.sourceDocNo != after.sourceDocNo) 'sourceDocNo',
    if (_sourceSignature(before.sourceAllocations) !=
        _sourceSignature(after.sourceAllocations))
      'sourceApplicationNos',
    if (_decimal(before.weight) != _decimal(after.weight)) 'weight',
    if (_decimal(before.giftQty) != _decimal(after.giftQty)) 'giftQty',
    if (_decimal(before.allowedLossPct) != _decimal(after.allowedLossPct))
      'allowedLossPct',
    if (before.remark != after.remark) 'remark',
  },
};

String? _decimal(String? value) => financeExactTrimmed(value) ?? value;

String _sourceSignature(String? value) {
  if (value == null) return '';
  final sources = (jsonDecode(value) as List).cast<Map<String, dynamic>>();
  final parts = [
    for (final source in sources)
      [
        source['sourceItemId']?.toString(),
        _decimal(source['quantity']?.toString()),
      ],
  ];
  parts.sort((a, b) => (a.first ?? '').compareTo(b.first ?? ''));
  return jsonEncode(parts);
}

class ProcurementHeaderChange {
  const ProcurementHeaderChange(this.key, this.label, this.before, this.after);
  final String key;
  final String label;
  final String before;
  final String after;
}

List<ProcurementHeaderChange> procurementHeaderChanges(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) {
  if (before.isEmpty || after.isEmpty) return const [];
  const fields = <(String, String, String?)>[
    ('billDate', '单据日期', null),
    ('supplierId', '供应商 / 委外商', 'supplierName'),
    ('warehouseId', '仓库', 'warehouseName'),
    ('currencyId', '币种', 'currencyName'),
    ('exchangeRate', '汇率', null),
    ('taxRate', '税率', null),
    ('settlementMethodId', '结算方式', 'settlementMethodName'),
    ('purchaserEmployeeId', '订货人', 'purchaserName'),
    ('deliverDate', '预计到货日', null),
    ('remark', '备注', null),
  ];
  Object? value(Map<String, dynamic> snapshot, String key) =>
      const {'exchangeRate', 'taxRate'}.contains(key)
      ? _decimal(snapshot[key]?.toString())
      : snapshot[key];
  String display(Map<String, dynamic> snapshot, String key, String? nameKey) {
    if (!snapshot.containsKey(key)) return '历史未留存';
    if (snapshot[key] == null || snapshot[key] == '') return '未填写';
    if (nameKey != null) return snapshot[nameKey]?.toString() ?? '名称未留存';
    return value(snapshot, key).toString();
  }

  return [
    for (final (key, label, nameKey) in fields)
      if (before.containsKey(key) &&
          after.containsKey(key) &&
          value(before, key) != value(after, key))
        ProcurementHeaderChange(
          key,
          label,
          display(before, key, nameKey),
          display(after, key, nameKey),
        ),
  ];
}

List<String> procurementHeaderUnknownLabels(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) => before.isEmpty
    ? const []
    : [
        for (final entry in const {'remark': '备注'}.entries)
          if (!before.containsKey(entry.key) || !after.containsKey(entry.key))
            entry.value,
      ];
