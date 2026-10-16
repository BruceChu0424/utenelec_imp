import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/hr_task/models/hr_reconcile_form_draft.dart';
import 'package:uten_imp/features/hr_task/models/hr_reconcile_plan.dart';
import 'package:uten_imp/features/hr_task/widgets/hr_reconcile_cells.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';

HrReconcileRow _row(
  String id,
  int rowNo, {
  int? version = 4,
  String field = 'idNumber',
  bool applied = false,
  List<String> candidates = const ['first', 'second'],
}) => HrReconcileRow(
  rowNo: rowNo,
  kind: HrReconcileRowKind.update,
  employee: HrReconcileEmployee(id: id, code: id, name: '同名员工'),
  employeeVersion: version,
  items: [
    HrReconcileItem(
      itemNo: 1,
      field: field,
      label: '证件号码',
      writePath: 'CHANGE_IDENTITY',
      tier: HrReconcileTier.manual,
      candidates: [
        for (final value in candidates) HrReconcileCandidate(value: value),
      ],
      outcome: applied
          ? const HrReconcileItemOutcome(
              status: HrReconcileOutcomeStatus.applied,
            )
          : null,
    ),
  ],
  result: applied
      ? const HrReconcileRowResult(status: HrReconcileRowResultStatus.applied)
      : null,
);

HrReconcilePlan _plan({
  String id = 'original-plan',
  int version = 1,
  HrReconcilePlanStatus status = HrReconcilePlanStatus.open,
  List<HrReconcileRow>? rows,
}) => HrReconcilePlan(
  id: id,
  version: version,
  status: status,
  actorName: '人事',
  createdAt: null,
  expiresAt: null,
  canApply: true,
  capabilities: const HrReconcilePlanCapabilities(viewPii: true, piiEdit: true),
  counts: const HrReconcilePlanCounts(
    rows: 2,
    update: 2,
    updateItems: 2,
    info: 0,
    same: 0,
    applied: 0,
    skipped: 0,
    failed: 0,
  ),
  rows: rows ?? [_row('employee-a', 1), _row('employee-b', 2)],
);

void main() {
  test('a preselected suggestion never supplies a manual final value', () {
    const item = HrReconcileItem(
      itemNo: 1,
      field: 'idNumber',
      label: '证件号码',
      writePath: 'CHANGE_IDENTITY',
      tier: HrReconcileTier.high,
      preselected: true,
      newValue: '11010519491231002X',
    );
    final draft = HrReconcileRowDraft();
    addTearDown(draft.dispose);
    expect(hrReconcileFinalValue(item, draft), isNull);
    draft.manual.text = '1101051949';
    expect(hrReconcileFinalValue(item, draft), isNull);
    draft.manual.text = '11010519491231002X';
    expect(hrReconcileFinalValue(item, draft)?.value, '11010519491231002X');
  });

  test('credential fields never capture manual input or candidate choices', () {
    final source = _plan(rows: [_row('employee-a', 1, field: 'password')]);
    final captured = captureHrReconcileFormDraft(source, {
      'employee-a': const HrReconcileDraftInput(
        manual: 'never-persist',
        candidateValue: 'never-persist',
      ),
    });
    final row = (captured['rows'] as List).single as Map;
    expect(row.containsKey('manual'), isFalse);
    expect(row.containsKey('candidateValue'), isFalse);
    expect(row.containsKey('adopted'), isFalse);
  });

  test(
    'finished receipt must prove original version, rows, items and counts',
    () {
      final submission = {
        'planVersion': 1,
        'rows': [
          {
            'rowNo': 1,
            'items': [
              {'itemNo': 1},
            ],
          },
        ],
      };
      HrReconcileApplyResult result({
        int version = 2,
        int rowNo = 1,
        int itemNo = 1,
        int applied = 1,
      }) => HrReconcileApplyResult(
        planVersion: version,
        round: 1,
        counts: HrReconcileApplyCounts(applied: applied, skipped: 0, failed: 0),
        rows: [
          HrReconcileApplyRowResult(
            rowNo: rowNo,
            result: HrReconcileRowResultStatus.applied,
            items: [
              HrReconcileApplyItemResult(
                itemNo: itemNo,
                status: HrReconcileOutcomeStatus.applied,
              ),
            ],
          ),
        ],
        summary: '完成',
      );
      expect(hrReconcileReceiptMatchesSubmission(result(), submission), isTrue);
      expect(
        hrReconcileReceiptMatchesSubmission(result(version: 3), submission),
        isFalse,
      );
      expect(
        hrReconcileReceiptMatchesSubmission(result(rowNo: 2), submission),
        isFalse,
      );
      expect(
        hrReconcileReceiptMatchesSubmission(result(itemNo: 2), submission),
        isFalse,
      );
      expect(
        hrReconcileReceiptMatchesSubmission(result(applied: 2), submission),
        isFalse,
      );
    },
  );

  test(
    'retained input snapshots exclude password and authorization metadata',
    () {
      final original = captureHrReconcileFormDraft(_plan(), const {});
      final rows = original['rows'] as List;
      final cleaned = hrReconcileInputSnapshot({
        ...original,
        'password': 'never-persist',
        'stepUpToken': 'never-persist',
        'rows': [
          {
            ...Map<String, dynamic>.from(rows.first as Map),
            'password': 'never-persist',
          },
          rows.last,
        ],
      });
      expect(cleaned.keys, isNot(contains('password')));
      expect(cleaned.keys, isNot(contains('stepUpToken')));
      expect(
        (cleaned['rows'] as List).first,
        isNot(containsPair('password', 'never-persist')),
      );
    },
  );

  test(
    'restore binds original plan and employee UUID despite row order and same names',
    () {
      final saved = captureHrReconcileFormDraft(_plan(), {
        'employee-a': const HrReconcileDraftInput(
          manual: '  unfinished X  ',
          adopted: false,
          selected: true,
        ),
      });
      final restored = restoreHrReconcileFormDraft(
        _plan(rows: [_row('employee-b', 1), _row('employee-a', 2)]),
        saved,
      );
      expect(restored['employee-a']!.manual, '  unfinished X  ');
      expect(restored['employee-a']!.adopted, isNull);
      expect(restored['employee-a']!.selected, isTrue);
      expect(restored['employee-b']!.manual, isEmpty);
      expect(
        saved.keys,
        unorderedEquals([
          'inputMode',
          'planId',
          'planVersion',
          'employeeIds',
          'rows',
        ]),
      );
    },
  );

  test(
    'legacy choices never become manual input and genuine manual text survives',
    () {
      final saved = captureHrReconcileFormDraft(_plan(), const {});
      saved.remove('inputMode');
      final rows = saved['rows'] as List;
      (rows.first as Map<String, dynamic>).addAll({
        'manual': '  unfinished X  ',
        'adopted': true,
        'candidateValue': 'second',
        'selected': true,
      });
      (rows.last as Map<String, dynamic>).addAll({
        'adopted': true,
        'candidateValue': 'first',
        'selected': true,
      });
      final restored = restoreHrReconcileFormDraft(
        _plan(
          rows: [
            _row('employee-a', 1, candidates: ['different']),
            _row('employee-b', 2),
          ],
        ),
        saved,
      );
      expect(restored['employee-a']!.manual, '  unfinished X  ');
      expect(restored['employee-a']!.legacyChoicesIgnored, isTrue);
      expect(restored['employee-a']!.candidateValue, isNull);
      expect(restored['employee-a']!.adopted, isNull);
      expect(restored['employee-b']!.manual, isEmpty);
      final recaptured = captureHrReconcileFormDraft(_plan(), restored);
      expect(recaptured['inputMode'], 'MANUAL_ONLY_V1');
      for (final row in recaptured['rows'] as List) {
        expect(row, isNot(contains('adopted')));
        expect(row, isNot(contains('candidateValue')));
      }
    },
  );

  for (final changed in <String, HrReconcilePlan>{
    'plan UUID': _plan(id: 'different-plan'),
    'plan version': _plan(version: 2),
    'employee UUID': _plan(
      rows: [_row('different-employee', 1), _row('employee-b', 2)],
    ),
    'employee version': _plan(
      rows: [_row('employee-a', 1, version: 5), _row('employee-b', 2)],
    ),
    'missing original employee version': _plan(
      rows: [_row('employee-a', 1, version: null), _row('employee-b', 2)],
    ),
    'field identity': _plan(
      rows: [
        _row('employee-a', 1, field: 'phone'),
        _row('employee-b', 2),
      ],
    ),
    'member missing': _plan(rows: [_row('employee-a', 1)]),
    'closed status': _plan(status: HrReconcilePlanStatus.closed),
    'applying status': _plan(status: HrReconcilePlanStatus.applying),
  }.entries) {
    test('changed ${changed.key} cannot receive original input', () {
      final saved = captureHrReconcileFormDraft(_plan(), {
        'employee-a': const HrReconcileDraftInput(manual: 'unfinished'),
      });
      expect(
        () => restoreHrReconcileFormDraft(changed.value, saved),
        throwsFormatException,
      );
    });
  }

  test('duplicate employees are rejected atomically', () {
    final saved = captureHrReconcileFormDraft(_plan(), {
      'employee-a': const HrReconcileDraftInput(manual: 'unfinished'),
    });
    final rows = saved['rows'] as List;
    final duplicate = {
      ...saved,
      'rows': [rows.first, rows.first],
    };
    expect(
      () => restoreHrReconcileFormDraft(_plan(), duplicate),
      throwsFormatException,
    );
  });

  test(
    'confirmed partial apply keeps only compatible remaining raw inputs',
    () {
      final saved = captureHrReconcileFormDraft(_plan(), {
        'employee-a': const HrReconcileDraftInput(
          manual: 'already applied',
          selected: true,
        ),
        'employee-b': const HrReconcileDraftInput(
          manual: '  remainder unfinished  ',
          adopted: false,
        ),
      });
      final remaining = remainingHrReconcileDraftInputs(
        _plan(
          version: 2,
          rows: [
            _row('employee-a', 1, version: 5, applied: true),
            _row('employee-b', 2),
          ],
        ),
        saved,
      );
      expect(remaining['employee-a']!.manual, isEmpty);
      expect(remaining['employee-b']!.manual, '  remainder unfinished  ');
      expect(remaining['employee-b']!.selected, isFalse);
      expect(remaining['employee-b']!.adopted, isNull);
    },
  );

  test(
    'task matching uses original plan members and excludes unrelated UUIDs',
    () {
      final spec = FormDraftCatalog.employeeReconcile.spec(
        route:
            '/hr/tasks/reconcile?planId=original-plan&employeeIds=employee-a,employee-b',
      );
      final draft = FormDraft(
        id: 'draft',
        title: spec.title,
        module: spec.module,
        route: spec.route,
        permission: spec.permission,
        draftKind: spec.draftKind,
        updatedAt: DateTime.utc(2026, 10, 11),
        data: {
          ...captureHrReconcileFormDraft(_plan(), const {}),
          'warehouseId': 'unrelated-employee',
        },
      );
      expect(hrReconcileDraftMatchesEmployee(draft, 'employee-a'), isTrue);
      expect(hrReconcileDraftMatchesEmployee(draft, 'employee-b'), isTrue);
      expect(
        hrReconcileDraftMatchesEmployee(draft, 'unrelated-employee'),
        isFalse,
      );
      final wrongPlan = FormDraft(
        id: draft.id,
        title: draft.title,
        module: draft.module,
        route: '/hr/tasks/reconcile?planId=other-plan',
        permission: draft.permission,
        draftKind: draft.draftKind,
        updatedAt: draft.updatedAt,
        data: draft.data,
      );
      expect(hrReconcileDraftMatchesEmployee(wrongPlan, 'employee-a'), isFalse);
    },
  );
}
