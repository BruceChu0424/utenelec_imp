import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft.dart';
import 'hr_reconcile_plan.dart';

/// Only user input is persisted; the server remains the source for suggestions and outcomes.
class HrReconcileDraftInput {
  const HrReconcileDraftInput({
    this.manual = '',
    this.adopted,
    this.candidateValue,
    this.selected = false,
    this.legacyChoicesIgnored = false,
  });

  final String manual;
  // Legacy draft metadata is accepted only for migration detection, never captured
  // or restored as an editable value.
  final bool? adopted;
  final String? candidateValue;
  final bool selected;
  final bool legacyChoicesIgnored;
}

bool hrReconcileInputIsSupported(HrReconcileRow row) => row.items.every(
  (item) => item.field == 'idNumber' && item.writePath == 'CHANGE_IDENTITY',
);

bool _rawRowAllowsInput(Map<Object?, Object?> row) {
  final items = row['items'];
  return items is List &&
      items.isNotEmpty &&
      items.every(
        (item) =>
            item is Map &&
            item['field'] == 'idNumber' &&
            item['writePath'] == 'CHANGE_IDENTITY',
      );
}

Map<String, dynamic> hrReconcileInputSnapshot(Map<String, dynamic> source) => {
  'inputMode': source['inputMode'],
  'planId': source['planId'],
  'planVersion': source['planVersion'],
  'employeeIds': [
    if (source['employeeIds'] case final List<Object?> ids)
      ...ids.whereType<String>(),
  ],
  'rows': [
    if (source['rows'] case final List<Object?> rows)
      for (final row in rows.whereType<Map<Object?, Object?>>())
        {
          'employeeId': row['employeeId'],
          'sourceVersion': row['sourceVersion'],
          'items': [
            if (row['items'] case final List<Object?> items)
              for (final item in items.whereType<Map<Object?, Object?>>())
                {
                  'itemNo': item['itemNo'],
                  'field': item['field'],
                  'writePath': item['writePath'],
                },
          ],
          if (_rawRowAllowsInput(row)) ...{
            'manual': row['manual'],
            'adopted': row['adopted'],
            'candidateValue': row['candidateValue'],
            'selected': row['selected'],
          },
        },
  ],
};

Map<String, dynamic> captureHrReconcileFormDraft(
  HrReconcilePlan plan,
  Map<String, HrReconcileDraftInput> inputs,
) => {
  'inputMode': 'MANUAL_ONLY_V1',
  'planId': plan.id,
  'planVersion': plan.version,
  'employeeIds': [for (final row in plan.rows) row.employee.id],
  'rows': [
    for (final row in plan.rows)
      {
        'employeeId': row.employee.id,
        'sourceVersion': row.employeeVersion,
        'items': [
          for (final item in row.items)
            {
              'itemNo': item.itemNo,
              'field': item.field,
              'writePath': item.writePath,
            },
        ],
        if (row.kind == HrReconcileRowKind.update &&
            hrReconcileInputIsSupported(row)) ...{
          'manual': inputs[row.employee.id]?.manual ?? '',
          'selected': inputs[row.employee.id]?.selected ?? false,
        },
      },
  ],
};

Map<String, HrReconcileDraftInput> restoreHrReconcileFormDraft(
  HrReconcilePlan plan,
  Map<String, dynamic> snapshot,
) {
  if (snapshot['planId'] != plan.id ||
      snapshot['planVersion'] != plan.version) {
    throw const FormatException('核对计划或版本已变化，原草稿保留，请重新核对');
  }
  if (plan.status != HrReconcilePlanStatus.open || !plan.canApply) {
    throw const FormatException('这份核对已关闭或不可执行，不能恢复成可编辑草稿');
  }
  final rawRows = snapshot['rows'];
  if (rawRows is! List || rawRows.length != plan.rows.length) {
    throw const FormatException('原核对成员不完整，不能按行号恢复');
  }
  final sourceRows = {for (final row in plan.rows) row.employee.id: row};
  final inputs = <String, HrReconcileDraftInput>{};
  for (final raw in rawRows) {
    if (raw is! Map || raw['employeeId'] is! String) {
      throw const FormatException('草稿缺少原员工身份');
    }
    final employeeId = raw['employeeId'] as String;
    final source = sourceRows[employeeId];
    if (source == null || inputs.containsKey(employeeId)) {
      throw const FormatException('原核对成员已变化，不能按姓名或行号恢复');
    }
    if (!hrReconcileInputIsSupported(source)) {
      throw const FormatException('核对包含不支持的填写字段，不能恢复原文');
    }
    if (source.employeeVersion == null ||
        raw['sourceVersion'] != source.employeeVersion) {
      throw const FormatException('原员工版本已变化，草稿不能覆盖最新资料');
    }
    final rawItems = raw['items'];
    if (rawItems is! List || rawItems.length != source.items.length) {
      throw const FormatException('原核对字段已变化');
    }
    final itemIdentities = <String>{};
    for (final item in rawItems) {
      if (item is! Map) throw const FormatException('原核对字段身份无效');
      final identity =
          '${item['itemNo']}:${item['field']}:${item['writePath']}';
      if (!itemIdentities.add(identity)) {
        throw const FormatException('原核对字段身份重复');
      }
    }
    if (source.items.any(
      (item) => !itemIdentities.contains(
        '${item.itemNo}:${item.field}:${item.writePath}',
      ),
    )) {
      throw const FormatException('原核对字段已变化');
    }
    final manual = raw['manual'] ?? '';
    final adopted = raw['adopted'];
    final candidateValue = raw['candidateValue'];
    if (manual is! String ||
        (adopted != null && adopted is! bool) ||
        (candidateValue != null && candidateValue is! String) ||
        (raw['selected'] != null && raw['selected'] is! bool)) {
      throw const FormatException('原填写输入不完整');
    }
    if ((source.result != null ||
            source.items.any((item) => item.outcome != null)) &&
        (manual.isNotEmpty ||
            adopted != null ||
            candidateValue != null ||
            raw['selected'] == true)) {
      throw const FormatException('原核对行已经执行，请查看处理结果');
    }
    inputs[employeeId] = HrReconcileDraftInput(
      manual: manual,
      legacyChoicesIgnored:
          adopted != null ||
          candidateValue != null ||
          (snapshot['inputMode'] != 'MANUAL_ONLY_V1' &&
              raw['selected'] == true &&
              manual.trim().isEmpty &&
              source.items.any((item) => item.preselected)),
      selected: raw['selected'] == true,
    );
  }
  return inputs;
}

/// A confirmed apply creates a new local editing baseline for the same plan.
/// Only untouched server rows with the same frozen employee and item identities keep input.
Map<String, HrReconcileDraftInput> remainingHrReconcileDraftInputs(
  HrReconcilePlan plan,
  Map<String, dynamic> previous,
) {
  if (previous['planId'] != plan.id) return const {};
  final oldRows = previous['rows'];
  if (oldRows is! List) return const {};
  final next = captureHrReconcileFormDraft(plan, const {});
  final nextRows = next['rows'] as List;
  for (final nextRow in nextRows.cast<Map<String, dynamic>>()) {
    final current = plan.rows.firstWhere(
      (row) => row.employee.id == nextRow['employeeId'],
    );
    if (current.result != null ||
        current.items.any((item) => item.outcome != null)) {
      continue;
    }
    final matches = oldRows
        .whereType<Map<Object?, Object?>>()
        .where(
          (row) =>
              row['employeeId'] == nextRow['employeeId'] &&
              row['sourceVersion'] == nextRow['sourceVersion'],
        )
        .toList();
    if (matches.length != 1) continue;
    final old = matches.single;
    final candidate = {
      ...next,
      'rows': [
        for (final row in nextRows)
          if (identical(row, nextRow))
            {...Map<String, dynamic>.from(old), 'selected': false}
          else
            row,
      ],
    };
    try {
      restoreHrReconcileFormDraft(plan, candidate);
      nextRow.addAll(Map<String, dynamic>.from(old)..['selected'] = false);
    } on FormatException {
      // Keep the original snapshot; an incompatible input is never carried to a changed source.
    }
  }
  return restoreHrReconcileFormDraft(plan, next);
}

bool hrReconcileDraftMatchesEmployee(FormDraft draft, String employeeId) {
  final uri = Uri.tryParse(draft.route);
  final data = draft.data;
  if (draft.module != BadgeModule.people ||
      draft.permission != Perm.employeePiiEdit ||
      draft.draftKind != 'employee_reconcile' ||
      uri?.path != RouteName.hrReconcile ||
      uri?.queryParameters['planId'] != data['planId'] ||
      data['planId'] is! String) {
    return false;
  }
  final rows = data['rows'];
  return rows is List &&
      rows.any((row) => row is Map && row['employeeId'] == employeeId);
}

bool hrReconcileReceiptMatchesSubmission(
  HrReconcileApplyResult result,
  Map<String, dynamic> submission,
) {
  final version = submission['planVersion'];
  final rawRows = submission['rows'];
  if (version is! int ||
      result.planVersion != version + 1 ||
      rawRows is! List) {
    return false;
  }
  final expected = <int, Set<int>>{};
  for (final row in rawRows) {
    if (row is! Map || row['rowNo'] is! int || row['items'] is! List) {
      return false;
    }
    final rowNo = row['rowNo'] as int;
    if (expected.containsKey(rowNo)) return false;
    final items = <int>{};
    for (final item in row['items'] as List) {
      if (item is! Map ||
          item['itemNo'] is! int ||
          !items.add(item['itemNo'] as int)) {
        return false;
      }
    }
    if (items.isEmpty) return false;
    expected[rowNo] = items;
  }
  if (expected.isEmpty || result.rows.length != expected.length) return false;
  final seen = <int>{};
  for (final row in result.rows) {
    final expectedItems = expected[row.rowNo];
    if (expectedItems == null || !seen.add(row.rowNo)) return false;
    final itemIds = row.items.map((item) => item.itemNo).toSet();
    if (itemIds.length != row.items.length ||
        itemIds.length != expectedItems.length ||
        !itemIds.containsAll(expectedItems)) {
      return false;
    }
  }
  return result.counts.applied ==
          result.rows
              .where((row) => row.result == HrReconcileRowResultStatus.applied)
              .length &&
      result.counts.skipped ==
          result.rows
              .where((row) => row.result == HrReconcileRowResultStatus.skipped)
              .length &&
      result.counts.failed ==
          result.rows
              .where((row) => row.result == HrReconcileRowResultStatus.failed)
              .length;
}
