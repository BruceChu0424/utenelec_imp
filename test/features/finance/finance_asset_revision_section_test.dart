import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/finance/models/finance_asset_models.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_revision_section.dart';

Map<String, dynamic> _asset({String amount = '120000.00', int months = 60}) => {
  'schemaVersion': 1,
  'objectType': 'FIXED_ASSET',
  'code': 'FA202609230001',
  'name': '数控机床',
  'originalValue': amount,
  'usefulMonths': months,
  'salvageRate': '0.05',
  'startPeriod': '2026-10',
  'categoryName': '生产设备',
  'departmentName': '机加工车间',
  'location': '设备区 A',
};
FinanceAssetReviewRevision _revision({
  String workflow = 'RECOGNITION',
  bool resubmission = true,
  Map<String, dynamic>? previous,
  Map<String, dynamic>? current,
}) => FinanceAssetReviewRevision(
  workflowType: workflow,
  resubmission: resubmission,
  previousSnapshot: previous == null
      ? null
      : jsonEncode({'schemaVersion': 1, ...previous}),
  submissionSnapshot: current == null
      ? null
      : jsonEncode({'schemaVersion': 1, ...current}),
);
FinanceAssetDetail _detail(
  List<FinanceAssetReviewRevision> revisions, {
  String status = 'PENDING_APPROVAL',
}) => FinanceAssetDetail(
  summary: FinanceAssetSummary.fromJson({
    'id': 'asset',
    'code': 'FA202609230001',
    'name': '数控机床',
    'status': status,
  }, FinanceAssetLedger.fixedAsset),
  books: const [],
  schedule: const [],
  approvalSteps: const [],
  events: const [],
  voucherNumbers: const [],
  documentReferences: const [],
  reviewRevisions: revisions,
);
Future<void> _pump(WidgetTester tester, FinanceAssetDetail detail) async {
  tester.view.physicalSize = const Size(1400, 850);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FinanceAssetRevisionSection(detail: detail),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'review terms use readable labels and distinguish equal-name references',
    (tester) async {
      await _pump(
        tester,
        _detail([
          _revision(
            previous: {
              ..._asset(),
              'sourceType': 'PURCHASE',
              'custodianId': 'person-old',
              'custodianName': '张三',
            },
            current: {
              ..._asset(),
              'sourceType': 'MANUAL',
              'custodianId': 'person-new',
              'custodianName': '张三',
              'salvageRate': '0.03',
            },
          ),
        ]),
      );
      expect(find.text('采购入账'), findsOneWidget);
      expect(find.text('手工录入'), findsOneWidget);
      expect(find.text('张三（已更换保管人）'), findsOneWidget);
      expect(find.text('person-old'), findsNothing);
      expect(find.text('person-new'), findsNothing);
      expect(find.text('5%'), findsOneWidget);
      expect(find.text('3%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'asset amount and useful life revisions copy the whole row and mark only changed cells',
    () {
      final rows = financeAssetRevisionRows(
        _revision(
          previous: _asset(),
          current: _asset(amount: '100000.00', months: 48),
        ),
      );
      expect(rows.map((row) => row.kind), [
        UtenRevisionKind.removed,
        UtenRevisionKind.added,
      ]);
      expect(rows.last.changedKeys, {'originalValue', 'usefulMonths'});
      expect(rows.last.value['name'], '数控机床');
      expect(rows.last.value['location'], '设备区 A');
    },
  );

  test(
    'exact amounts compare without binary rounding and scale-only changes stay neutral',
    () {
      final unchanged = financeAssetRevisionRows(
        _revision(
          previous: _asset(amount: '1234567890123456.7800'),
          current: _asset(amount: '1234567890123456.78'),
        ),
      );
      expect(unchanged.single.kind, UtenRevisionKind.unchanged);
      final changed = financeAssetRevisionRows(
        _revision(
          previous: _asset(amount: '1234567890123456.78'),
          current: _asset(amount: '1234567890123456.79'),
        ),
      );
      expect(changed.last.changedKeys, {'originalValue'});
      expect(changed.last.value['originalValue'], '1234567890123456.79');
    },
  );

  testWidgets(
    'new asset values are bold red inside green rows while the name remains green',
    (tester) async {
      await _pump(
        tester,
        _detail([
          _revision(
            previous: _asset(),
            current: _asset(amount: '100000.00', months: 48),
          ),
        ]),
      );
      final amount = tester.widget<Text>(find.text('100000.00'));
      expect(amount.style?.fontWeight, FontWeight.w800);
      expect(amount.style?.color, UtenColors.errorText);
      expect(
        DefaultTextStyle.of(tester.element(find.text('数控机床').last)).style.color,
        UtenColors.successText,
      );
      expect(find.byType(UtenRevisionStrike), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first recognition and a rejected draft do not show stale comparison rows',
    (tester) async {
      expect(
        financeAssetRevisionTitle(
          _detail([_revision(resubmission: false, current: _asset())]),
        ),
        isNull,
      );
      expect(
        financeAssetRevisionTitle(
          _detail([
            _revision(previous: _asset(), current: _asset()),
          ], status: 'DRAFT'),
        ),
        isNull,
      );
      await _pump(
        tester,
        _detail([_revision(resubmission: false, current: _asset())]),
      );
      expect(find.byType(UtenRevisionStrike), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FinanceAssetRevisionSection(
              detail: _detail([
                _revision(
                  previous: _asset(),
                  current: _asset(amount: '100000'),
                ),
              ], status: 'DRAFT'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenRevisionStrike), findsNothing);
    },
  );

  testWidgets('an absent historical snapshot has a clear gap message', (
    tester,
  ) async {
    await _pump(tester, _detail([_revision(current: _asset())]));
    expect(find.textContaining('上次提交内容未留存或暂不可读'), findsOneWidget);
    expect(find.byType(UtenRevisionStrike), findsNothing);
  });

  testWidgets(
    'disposal and termination comparisons stay in separate workflow tables',
    (tester) async {
      await _pump(
        tester,
        _detail([
          _revision(
            workflow: 'DISPOSAL',
            previous: {
              'effectiveDate': '2026-09-23',
              'proceedsAmount': '1000.00',
              'reason': '旧设备处置',
            },
            current: {
              'effectiveDate': '2026-09-24',
              'proceedsAmount': '1200.00',
              'reason': '旧设备处置',
            },
          ),
          _revision(
            workflow: 'TERMINATION',
            previous: {
              'effectiveDate': '2026-09-23',
              'evidenceReference': '合同A',
              'reason': '合同终止',
            },
            current: {
              'effectiveDate': '2026-09-23',
              'evidenceReference': '合同B',
              'reason': '合同终止',
            },
          ),
        ], status: 'DISPOSAL_PENDING'),
      );
      expect(
        find.byKey(const ValueKey('finance-asset-revision-DISPOSAL')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('finance-asset-revision-TERMINATION')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('1200.00')).style?.fontWeight,
        FontWeight.w800,
      );
      expect(
        tester.widget<Text>(find.text('合同B')).style?.fontWeight,
        FontWeight.w800,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('detail DTO parses independently scoped review revisions', () {
    final detail = FinanceAssetDetail.fromJson({
      'summary': {
        'id': 'asset',
        'name': '设备',
        'code': 'FA1',
        'status': 'PENDING_APPROVAL',
      },
      'reviewRevisions': [
        {
          'workflowType': 'RECOGNITION',
          'resubmission': true,
          'previousSnapshot': jsonEncode(_asset()),
          'submissionSnapshot': jsonEncode(_asset(amount: '100000')),
        },
      ],
    }, FinanceAssetLedger.fixedAsset);
    expect(detail.reviewRevisions.single.workflowType, 'RECOGNITION');
    expect(
      financeAssetRevisionRows(detail.reviewRevisions.single).last.changedKeys,
      {'originalValue'},
    );
  });
}
