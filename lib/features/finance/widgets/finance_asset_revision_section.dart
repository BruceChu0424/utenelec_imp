import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../components/data_display/uten_revision_table.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/finance_asset_models.dart';
import 'finance_asset_ui.dart';

const _labels = <String, String>{
  'code': '编号',
  'name': '名称',
  'originalValue': '资产原值',
  'totalAmount': '待摊金额',
  'usefulMonths': '使用月数',
  'salvageRate': '残值率',
  'startPeriod': '起始期间',
  'categoryName': '类别',
  'departmentName': '部门',
  'custodianName': '负责人 / 保管人',
  'location': '位置',
  'sourceType': '来源类型',
  'sourceRef': '来源单号',
  'sourceLineRef': '来源行号',
  'sourceDocumentDate': '来源日期',
  'remark': '备注',
  'acquisitionDate': '购置日期',
  'acceptanceDate': '验收日期',
  'readyForUseDate': '可使用日期',
  'serialNumber': '序列号',
  'assetTag': '资产标签',
  'costCenterCode': '成本中心',
  'benefitStartDate': '受益开始日期',
  'benefitEndDate': '受益截止日期',
  'effectiveDate': '生效日期',
  'proceedsAmount': '处置收入',
  'evidenceReference': '凭证依据',
  'reason': '申请原因',
};
const _numbers = {
  'originalValue',
  'totalAmount',
  'usefulMonths',
  'salvageRate',
  'proceedsAmount',
};
const _identityFields = {
  'categoryId': 'categoryName',
  'departmentId': 'departmentName',
  'custodianId': 'custodianName',
  'responsibleEmployeeId': 'custodianName',
  'sourceId': 'sourceRef',
};

Map<String, dynamic>? _snapshot(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> &&
            value['schemaVersion'] == 1 &&
            (value['name'] is String || value['effectiveDate'] is String)
        ? value
        : null;
  } on Object {
    return null;
  }
}

Object? _valueForComparison(String key, Object? value) => _numbers.contains(key)
    ? financeExactTrimmed(value?.toString())
    : value == ''
    ? null
    : value;

Set<String> _changedKeys(
  Map<String, dynamic> before,
  Map<String, dynamic> after,
) => {
  for (final key in {...before.keys, ...after.keys})
    if ((_labels.containsKey(key) || _identityFields.containsKey(key)) &&
        _valueForComparison(key, before[key]) !=
            _valueForComparison(key, after[key]))
      _identityFields[key] ?? key,
};

List<UtenRevisionRow<Map<String, dynamic>>> financeAssetRevisionRows(
  FinanceAssetReviewRevision revision,
) {
  final previous = _snapshot(revision.previousSnapshot);
  final current = _snapshot(revision.submissionSnapshot);
  if (previous == null || current == null) return const [];
  final changed = _changedKeys(previous, current);
  return changed.isEmpty
      ? [UtenRevisionRow(value: current, kind: UtenRevisionKind.unchanged)]
      : [
          UtenRevisionRow(value: previous, kind: UtenRevisionKind.removed),
          UtenRevisionRow(
            value: current,
            kind: UtenRevisionKind.added,
            changedKeys: changed,
          ),
        ];
}

String? financeAssetRevisionTitle(FinanceAssetDetail? detail) {
  if (detail == null) return null;
  bool revised(String type) => detail.reviewRevisions.any(
    (entry) => entry.workflowType == type && entry.resubmission,
  );
  return switch (detail.summary.status) {
    'DISPOSAL_PENDING' when revised('DISPOSAL') => '资产处置申请修改',
    'TERMINATION_PENDING' when revised('TERMINATION') => '待摊终止申请修改',
    'PENDING_APPROVAL' || 'APPROVED' when revised('RECOGNITION') =>
      detail.summary.ledger == FinanceAssetLedger.fixedAsset
          ? '固定资产修改'
          : '待摊费用修改',
    _ => null,
  };
}

/// The asset is one business item. Its principal facts stay in one old/new row;
/// long or secondary changed terms use the same red-old/green-new field style.
class FinanceAssetRevisionSection extends StatelessWidget {
  const FinanceAssetRevisionSection({super.key, required this.detail});
  final FinanceAssetDetail detail;

  @override
  Widget build(BuildContext context) {
    final revisions = detail.reviewRevisions.where(
      (revision) =>
          revision.resubmission &&
          !(revision.workflowType == 'RECOGNITION' &&
              detail.summary.status == 'DRAFT'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final revision in revisions) _workflow(context, revision),
      ],
    );
  }

  Widget _workflow(BuildContext context, FinanceAssetReviewRevision revision) {
    final rows = financeAssetRevisionRows(revision);
    final title = switch (revision.workflowType) {
      'RECOGNITION' => '确认审批 · 修改对比',
      'DISPOSAL' => '处置申请 · 修改对比',
      'TERMINATION' => '终止申请 · 修改对比',
      _ => '申请修改对比',
    };
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text('$title：上次提交内容未留存或暂不可读，请核对当前资料。'),
      );
    }
    final mainKeys = revision.workflowType == 'RECOGNITION'
        ? <String>[
            'name',
            if (rows.any((row) => row.value.containsKey('originalValue')))
              'originalValue',
            if (rows.any((row) => row.value.containsKey('totalAmount')))
              'totalAmount',
            'usefulMonths',
            if (rows.any((row) => row.value['salvageRate'] != null))
              'salvageRate',
            'startPeriod',
            'categoryName',
            'departmentName',
            'code',
          ]
        : <String>[
            'effectiveDate',
            if (revision.workflowType == 'DISPOSAL') 'proceedsAmount',
            'evidenceReference',
            'reason',
          ];
    final old = rows.first.value;
    final now = rows.last.value;
    String display(Map<String, dynamic> row, String key) {
      final text = _display(row, key);
      if (!identical(row, now) ||
          rows.length < 2 ||
          _display(old, key) != text) {
        return text;
      }
      final referenceChanged = _identityFields.entries.any(
        (entry) => entry.value == key && old[entry.key] != now[entry.key],
      );
      if (!referenceChanged) return text;
      return '$text（已更换${switch (key) {
        'categoryName' => '类别',
        'departmentName' => '部门',
        'custodianName' => _fieldLabel(key),
        _ => '来源记录',
      }}）';
    }

    final extraFields = <UtenRevisionField>[
      if (rows.length > 1)
        for (final key in rows.last.changedKeys)
          if (!mainKeys.contains(key))
            UtenRevisionField(
              label: _fieldLabel(key),
              before: display(old, key),
              after: display(now, key),
            ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          UtenRevisionTable<Map<String, dynamic>>(
            key: ValueKey('finance-asset-revision-${revision.workflowType}'),
            embedded: true,
            rows: rows,
            columns: [
              for (final key in mainKeys)
                MasterColumnDef(
                  key: key,
                  label: _fieldLabel(key),
                  width:
                      key == 'name' ||
                          key == 'reason' ||
                          key == 'evidenceReference'
                      ? 210
                      : 130,
                  type: _numbers.contains(key) ? 'money' : 'text',
                  value: (row) => display(row, key),
                ),
            ],
          ),
          if (extraFields.isNotEmpty) ...[
            const SizedBox(height: 12),
            UtenRevisionFields(changes: extraFields),
          ],
        ],
      ),
    );
  }

  String _display(Map<String, dynamic> row, String key) {
    if (key == 'sourceType') {
      return financeAssetSourceTypeLabel(row[key]?.toString());
    }
    if (key == 'salvageRate' && row[key] != null) {
      final percent = financeExactMultiplyTexts([row[key].toString(), '100']);
      return percent == null ? '—' : '${financeExactTrimmed(percent)}%';
    }
    final text = row[key]?.toString();
    if (text != null && text.isNotEmpty) return text;
    final idKey = _identityFields.entries
        .where((field) => field.value == key)
        .firstOrNull
        ?.key;
    final id = idKey == null ? null : row[idKey]?.toString();
    return id == null || id.isEmpty
        ? '—'
        : key == 'sourceRef'
        ? '历史来源单号未留存'
        : '历史名称未留存';
  }

  String _fieldLabel(String key) => switch (key) {
    'custodianName' =>
      detail.summary.ledger == FinanceAssetLedger.fixedAsset ? '保管人' : '负责人',
    'usefulMonths' =>
      detail.summary.ledger == FinanceAssetLedger.fixedAsset ? '使用月数' : '摊销月数',
    _ => _labels[key] ?? key,
  };
}
