import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../components/data_display/uten_revision_table.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_invoice.dart';
import '../models/expense_item.dart';

const _itemFields = ['category', 'date', 'description', 'amount'];
const _invoiceFields = [
  'invoiceType',
  'invoiceCode',
  'invoiceNo',
  'issueDate',
  'sellerName',
  'sellerTaxNo',
  'buyerName',
  'buyerTaxNo',
  'amountExclTax',
  'taxAmount',
  'totalAmount',
  'attachmentId',
  'remark',
];
const _amountFields = {'amount', 'amountExclTax', 'taxAmount', 'totalAmount'};

bool expenseShowsSubmittedRevision(ExpenseClaim claim) =>
    claim.status != ExpenseClaimStatus.draft &&
    claim.status != ExpenseClaimStatus.rejected;

bool expenseIsSubmittedModification(ExpenseClaim claim) =>
    expenseShowsSubmittedRevision(claim) &&
    (claim.resubmission || claim.previousSubmissionSnapshot != null);

Map<String, dynamic>? _readSnapshot(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic> ||
        value['schemaVersion'] != 1 ||
        value['items'] is! List ||
        value['invoices'] is! List) {
      return null;
    }
    for (final key in ['items', 'invoices']) {
      if ((value[key] as List).any((row) => row is! Map<String, dynamic>)) {
        return null;
      }
    }
    for (final item in (value['items'] as List).cast<Map<String, dynamic>>()) {
      if (item['category'] is! String ||
          item['date'] is! String ||
          item['amount'] is! String ||
          !RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(item['amount'] as String)) {
        return null;
      }
    }
    final invoiceIds = <String>{};
    for (final invoice
        in (value['invoices'] as List).cast<Map<String, dynamic>>()) {
      if (invoice['id'] is! String ||
          (invoice['id'] as String).isEmpty ||
          !invoiceIds.add(invoice['id'] as String) ||
          invoice['invoiceNo'] is! String ||
          invoice['totalAmount'] is! String) {
        return null;
      }
    }
    return value;
  } on Object {
    return null;
  }
}

// Numeric formatting changes must not turn an unchanged expense into a change.
// Work with strings throughout so large, exact amounts never lose digits.
Object? _canonical(String key, Object? value) {
  if (value == null || value == '') return null;
  if (!_amountFields.contains(key)) return value;
  var text = value.toString();
  if (!RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(text)) return text;
  if (text.contains('.')) {
    text = text
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  return text == '-0' ? '0' : text;
}

String _signature(Map<String, dynamic> row, List<String> fields) =>
    jsonEncode([for (final key in fields) _canonical(key, row[key])]);

/// Item UUIDs are recreated during edits. Match unchanged business rows as a
/// multiset first, then pair a changed amount only when its other fields identify
/// one unique row on each side. Ambiguous duplicates stay explicit deletes/adds.
List<UtenRevisionRow<Map<String, dynamic>>> expenseItemRevisionRows(
  List<Map<String, dynamic>> previous,
  List<Map<String, dynamic>> current,
) {
  final matches = <int, int>{};
  final available = current.asMap().keys.toSet();
  for (var oldIndex = 0; oldIndex < previous.length; oldIndex++) {
    final signature = _signature(previous[oldIndex], _itemFields);
    final match = available
        .where((index) => _signature(current[index], _itemFields) == signature)
        .firstOrNull;
    if (match != null) {
      matches[oldIndex] = match;
      available.remove(match);
    }
  }
  const identity = ['category', 'date', 'description'];
  for (var oldIndex = 0; oldIndex < previous.length; oldIndex++) {
    if (matches.containsKey(oldIndex)) continue;
    final signature = _signature(previous[oldIndex], identity);
    final oldCandidates = previous
        .asMap()
        .keys
        .where(
          (index) =>
              !matches.containsKey(index) &&
              _signature(previous[index], identity) == signature,
        )
        .toList();
    final newCandidates = available
        .where((index) => _signature(current[index], identity) == signature)
        .toList();
    if (oldCandidates.length == 1 && newCandidates.length == 1) {
      matches[oldIndex] = newCandidates.single;
      available.remove(newCandidates.single);
    }
  }
  return _pairedRows(previous, current, matches, available, _itemFields);
}

List<UtenRevisionRow<Map<String, dynamic>>> expenseInvoiceRevisionRows(
  List<Map<String, dynamic>> previous,
  List<Map<String, dynamic>> current,
) {
  final matches = <int, int>{};
  final available = current.asMap().keys.toSet();
  for (var oldIndex = 0; oldIndex < previous.length; oldIndex++) {
    final id = previous[oldIndex]['id'];
    if (id is! String || id.isEmpty) continue;
    final sameId = available
        .where((index) => current[index]['id'] == id)
        .toList();
    if (sameId.length == 1 &&
        previous.where((row) => row['id'] == id).length == 1) {
      matches[oldIndex] = sameId.single;
      available.remove(sameId.single);
    }
  }
  return _pairedRows(previous, current, matches, available, _invoiceFields);
}

List<UtenRevisionRow<Map<String, dynamic>>> _pairedRows(
  List<Map<String, dynamic>> previous,
  List<Map<String, dynamic>> current,
  Map<int, int> matches,
  Set<int> added,
  List<String> fields,
) => [
  for (var index = 0; index < previous.length; index++) ...[
    UtenRevisionRow(
      value:
          matches[index] != null &&
              _signature(previous[index], fields) ==
                  _signature(current[matches[index]!], fields)
          ? current[matches[index]!]
          : previous[index],
      kind:
          matches[index] != null &&
              _signature(previous[index], fields) ==
                  _signature(current[matches[index]!], fields)
          ? UtenRevisionKind.unchanged
          : UtenRevisionKind.removed,
      label: matches[index] == null ? '已删除' : null,
    ),
    if (matches[index] != null &&
        _signature(previous[index], fields) !=
            _signature(current[matches[index]!], fields))
      UtenRevisionRow(
        value: current[matches[index]!],
        kind: UtenRevisionKind.added,
        label: '修改后',
        changedKeys: {
          for (final field in fields)
            if (_canonical(field, previous[index][field]) !=
                _canonical(field, current[matches[index]!][field]))
              field,
        },
      ),
  ],
  for (final index in added)
    UtenRevisionRow(
      value: current[index],
      kind: UtenRevisionKind.added,
      label: '新增',
    ),
];

class ExpenseSubmissionRevision {
  ExpenseSubmissionRevision._(this.previous, this.current);
  final Map<String, dynamic> previous;
  final Map<String, dynamic> current;

  static ExpenseSubmissionRevision? fromClaim(ExpenseClaim claim) {
    if (!expenseShowsSubmittedRevision(claim)) return null;
    final old = _readSnapshot(claim.previousSubmissionSnapshot);
    final now = _readSnapshot(claim.submissionSnapshot);
    return old == null || now == null
        ? null
        : ExpenseSubmissionRevision._(old, now);
  }

  List<UtenRevisionRow<Map<String, dynamic>>> get items =>
      expenseItemRevisionRows(
        (previous['items'] as List).cast<Map<String, dynamic>>(),
        (current['items'] as List).cast<Map<String, dynamic>>(),
      );
  List<UtenRevisionRow<Map<String, dynamic>>> get invoices =>
      expenseInvoiceRevisionRows(
        (previous['invoices'] as List).cast<Map<String, dynamic>>(),
        (current['invoices'] as List).cast<Map<String, dynamic>>(),
      );
  String get totalAmount => current['totalAmount']?.toString() ?? '—';
}

class ExpenseSubmissionChangeSummary extends StatelessWidget {
  const ExpenseSubmissionChangeSummary({super.key, required this.claim});
  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context) {
    if (!expenseShowsSubmittedRevision(claim)) return const SizedBox.shrink();
    final revision = ExpenseSubmissionRevision.fromClaim(claim);
    if (revision == null) {
      return claim.resubmission || claim.previousSubmissionSnapshot != null
          ? const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('本单已重新提交；上次提交内容未留存或暂不可读，以下显示当前内容。'),
            )
          : const SizedBox.shrink();
    }
    final changes = [
      for (final field in {'title': '标题', 'remark': '备注'}.entries)
        if (revision.previous[field.key] != revision.current[field.key])
          UtenRevisionField(
            label: field.value,
            before: revision.previous[field.key]?.toString() ?? '',
            after: revision.current[field.key]?.toString() ?? '',
          ),
    ];
    return changes.isEmpty
        ? const SizedBox.shrink()
        : UtenRevisionFields(changes: changes);
  }
}

class ExpenseSubmissionItemTable extends StatelessWidget {
  const ExpenseSubmissionItemTable({
    super.key,
    required this.revision,
    this.stickyHeaderPinned,
  });
  final ExpenseSubmissionRevision revision;
  final ValueNotifier<bool>? stickyHeaderPinned;

  @override
  Widget build(BuildContext context) => UtenRevisionTable<Map<String, dynamic>>(
    embedded: true,
    stickyHeaderPinned: stickyHeaderPinned,
    rows: revision.items,
    columns: [
      MasterColumnDef(
        key: 'category',
        label: '费用科目',
        width: 130,
        value: (row) => _categoryLabel(row['category']),
      ),
      MasterColumnDef(
        key: 'date',
        label: '日期',
        width: 110,
        type: 'date',
        value: (row) => row['date']?.toString(),
      ),
      MasterColumnDef(
        key: 'description',
        label: '说明',
        width: 260,
        value: (row) => row['description']?.toString(),
      ),
      MasterColumnDef(
        key: 'amount',
        label: '金额',
        width: 150,
        type: 'money',
        value: (row) => row['amount']?.toString(),
      ),
    ],
    summaryBar: Align(
      alignment: Alignment.centerRight,
      child: Text(
        '本次共 ${(revision.current['items'] as List).length} 项 · 合计 ¥ ${revision.totalAmount}',
      ),
    ),
  );
}

String _categoryLabel(Object? category) {
  try {
    return ExpenseCategory.fromApi(category).label;
  } on FormatException {
    return category?.toString() ?? '—';
  }
}

class ExpenseSubmissionInvoiceTable extends StatelessWidget {
  const ExpenseSubmissionInvoiceTable({
    super.key,
    required this.revision,
    required this.claim,
    this.stickyHeaderPinned,
  });
  final ExpenseSubmissionRevision revision;
  final ExpenseClaim claim;
  final ValueNotifier<bool>? stickyHeaderPinned;

  @override
  Widget build(BuildContext context) => UtenRevisionTable<Map<String, dynamic>>(
    embedded: true,
    stickyHeaderPinned: stickyHeaderPinned,
    rows: revision.invoices,
    columns: [
      for (final field in const {
        'lineNo': '#',
        'invoiceType': '类型',
        'invoiceNo': '发票号码',
        'totalAmount': '价税合计',
        'invoiceCode': '发票代码',
        'issueDate': '开票日期',
        'sellerName': '销售方',
        'sellerTaxNo': '销售方税号',
        'buyerName': '购买方',
        'buyerTaxNo': '购买方税号',
        'amountExclTax': '金额',
        'taxAmount': '税额',
        'attachmentId': '凭证原件',
        'remark': '备注',
      }.entries)
        MasterColumnDef(
          key: field.key,
          label: field.value,
          width: field.key == 'lineNo'
              ? 54
              : field.key.endsWith('Name') || field.key == 'remark'
              ? 200
              : 150,
          type: _amountFields.contains(field.key) ? 'money' : 'text',
          value: (row) => field.key == 'invoiceType'
              ? ExpenseInvoiceType.fromApi(row[field.key]).label
              : field.key == 'attachmentId'
              ? _attachment(row[field.key])
              : row[field.key]?.toString(),
        ),
    ],
  );

  String _attachment(Object? id) {
    if (id == null || id == '') return '—';
    final attachment = claim.attachments
        .where((item) => item.id == id)
        .firstOrNull;
    return attachment?.originalName ?? '原附件已移除';
  }
}
