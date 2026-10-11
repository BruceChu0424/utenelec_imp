part of 'production_daily_report_detail_approve_test.dart';

Map<String, dynamic> _materialRow(
  String id, {
  bool canReturn = true,
  int remaining = 4,
  int direct = 1,
  String? blocked,
}) => {
  'demandId': id,
  'planId': 'plan-1',
  'materialExecutionSegmentId': 'source-$id',
  'materialExecutionSegmentCode': 'HP-$id',
  'goodsName': '用料$id完整名称及其他很长的识别信息',
  'goodsCode': 'CODE-$id',
  'colorName': '深灰色',
  'unitName': '个',
  'availableQty': 10,
  'usageQty': 6,
  'remainingIssuedQty': remaining,
  'undrawnDirectQty': direct,
  'returnableIssuedQty': canReturn ? remaining : 0,
  'returnableDirectQty': canReturn ? direct : 0,
  'canReturn': canReturn,
  'returnBlockedReason': blocked,
};

List<Map<String, dynamic>> _reviewRows() => [
  _materialRow('a'),
  _materialRow('b', canReturn: false, blocked: '后续生产批次正在承接这份材料'),
  _materialRow('zero', remaining: 0, direct: 0, canReturn: false),
];

void registerDailyReportMaterialReviewCases() {
  testWidgets(
    'V3 separates material quantities and requires an explicit eligible decision',
    (tester) async {
      final (api, notices) = await _pump(
        tester,
        capability: 3,
        materialRows: _reviewRows(),
        onApprove: (_) => null,
      );
      expect(api.materialReads, 1);
      final table = tester
          .widget<MasterDataTableView<DailyReportMaterialReviewRow>>(
            find.byWidgetPredicate(
              (w) => w is MasterDataTableView<DailyReportMaterialReviewRow>,
            ),
          );
      expect(
        table.columns.map((c) => c.label),
        containsAll([
          '来源工单',
          '物料名称',
          '本次实际用料',
          '审核前可用',
          '预计已领余料',
          '未领直送料',
          '本次可申请退料',
          '处理方式',
        ]),
      );
      expect(table.items, hasLength(3));
      expect(
        find.byKey(const ValueKey('daily-material-action-b')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('daily-material-action-zero')),
        findsNothing,
      );
      expect(find.byTooltip('后续生产批次正在承接这份材料'), findsOneWidget);
      await tester.tap(find.widgetWithText(UtenButton, '审核'));
      await tester.pumpAndSettle();
      expect(notices, contains('请逐料选择退回仓库或留在车间，再确认审核'));
      expect(find.widgetWithText(FilledButton, '确认审核'), findsNothing);
      expect(api.approveBodies, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'V3 returns only eligible rows and freezes the complete saved decision at confirmation',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 3,
        materialRows: _reviewRows(),
        onApprove: (server) {
          server.serverStatus = 1;
          server.includeReceipt = true;
          server.rememberApproval();
          return null;
        },
      );
      await tester.tap(find.byKey(const ValueKey('daily-material-return-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(UtenButton, '审核'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本次实际用料 6 个'), findsOneWidget);
      api.materialFingerprint = 'a-new-ledger-snapshot';
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pumpAndSettle();
      expect(api.approveBodies.single, containsPair('commandVersion', 3));
      expect(
        api.approveBodies.single['materialReviewFingerprint'],
        'material-snapshot-1',
      );
      expect(api.approveBodies.single['materialDecisions'], [
        {'demandId': 'a', 'action': 'RETURN'},
        {'demandId': 'b', 'action': 'KEEP'},
        {'demandId': 'zero', 'action': 'KEEP'},
      ]);
      expect(api.approvalStorage.records, isEmpty);
      expect(find.text('退仓申请已登记'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('V3 zero balances need no additional choice', (tester) async {
    final (api, _) = await _pump(
      tester,
      capability: 3,
      materialRows: [
        _materialRow('zero', remaining: 0, direct: 0, canReturn: false),
      ],
      onApprove: (server) {
        server.serverStatus = 1;
        server.includeReceipt = true;
        server.rememberApproval();
        return null;
      },
    );
    expect(find.byType(UtenDropdownField), findsNothing);
    await _tapApprove(tester);
    expect(api.approveBodies.single['materialDecisions'], [
      {'demandId': 'zero', 'action': 'KEEP'},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('V3 users without approval action only see trusted balances', (
    tester,
  ) async {
    final (api, _) = await _pump(
      tester,
      capability: 3,
      approvable: false,
      materialRows: _reviewRows(),
      onApprove: (_) => null,
    );
    expect(find.byType(UtenDropdownField), findsNothing);
    expect(
      find.byKey(const ValueKey('daily-material-return-all')),
      findsNothing,
    );
    expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
    expect(find.text('只读核对'), findsOneWidget);
    expect(api.approveBodies, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['missing', 'version', 'duplicate']) {
    testWidgets('V3 unavailable material snapshot fails closed: $mode', (
      tester,
    ) async {
      final rows = _reviewRows();
      if (mode == 'duplicate') rows.add(_materialRow('a'));
      final (api, _) = await _pump(
        tester,
        capability: 3,
        materialRows: rows,
        materialVersionOverride: mode == 'version' ? 2 : null,
        materialReadFailure: mode == 'missing'
            ? NetworkTimeoutException()
            : null,
        onApprove: (_) => null,
      );
      expect(
        find.byKey(const ValueKey('daily-material-review-unavailable')),
        findsOneWidget,
      );
      expect(find.widgetWithText(UtenButton, '审核'), findsNothing);
      expect(api.approveBodies, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'V3 ledger conflict refreshes trusted balances and asks for a new decision',
    (tester) async {
      final (api, notices) = await _pump(
        tester,
        capability: 3,
        materialRows: _reviewRows(),
        onApprove: (server) {
          server.materialFingerprint = 'changed-ledger';
          return ApiException(
            'DAILY_REPORT_MATERIAL_REVIEW_CONFLICT',
            '材料台账已变化，请重新核对',
            httpStatus: 409,
          );
        },
      );
      await tester.tap(find.byKey(const ValueKey('daily-material-return-all')));
      await tester.pumpAndSettle();
      await _tapApprove(tester);
      expect(api.approvalStorage.records, isEmpty);
      expect(api.materialReads, 2);
      expect(notices, contains('材料台账已变化，请重新核对'));
      final field = tester.widget<UtenDropdownField>(
        find.byKey(const ValueKey('daily-material-action-a')),
      );
      expect(field.value, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'V3 unknown result replays the original decision and fingerprint after a fresh GET',
    (tester) async {
      var attempts = 0;
      final (api, _) = await _pump(
        tester,
        capability: 3,
        materialRows: _reviewRows(),
        onApprove: (server) {
          attempts++;
          if (attempts == 1) return NetworkTimeoutException();
          server.serverStatus = 1;
          server.includeReceipt = true;
          server.rememberApproval(replay: true);
          return null;
        },
      );
      await tester.tap(find.byKey(const ValueKey('daily-material-keep-all')));
      await tester.pumpAndSettle();
      await _tapApprove(tester);
      final original = Map<String, dynamic>.from(api.approveBodies.single);
      final record =
          jsonDecode(api.approvalStorage.records.values.single) as Map;
      expect(record['materialDecisions'], original['materialDecisions']);
      api.materialFingerprint = 'new-current-ledger';
      await tester.tap(
        find.byKey(const Key('daily-report-retry-original-approval')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '重试原审核'));
      await tester.pumpAndSettle();
      expect(api.approveBodies, [original, original]);
      expect(api.approvalStorage.records, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'V3 receipt with another material fingerprint cannot settle the original intent',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 3,
        materialRows: _reviewRows(),
        onApprove: (server) {
          server.serverStatus = 1;
          server.includeReceipt = true;
          server.rememberApproval();
          server.receipt!['materialReviewFingerprint'] = 'another-snapshot';
          return null;
        },
      );
      await tester.tap(find.byKey(const ValueKey('daily-material-keep-all')));
      await tester.pumpAndSettle();
      await _tapApprove(tester);
      expect(api.approvalStorage.records, hasLength(1));
      expect(
        find.byKey(const Key('daily-report-resolve-approval')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'V3 material review keeps single row cells usable on narrow large text: dark=$dark',
      (tester) async {
        await _pump(
          tester,
          capability: 3,
          materialRows: _reviewRows(),
          size: const Size(390, 780),
          textScale: 1.3,
          dark: dark,
          onApprove: (_) => null,
        );
        final field = tester.widget<UtenDropdownField>(
          find.byKey(const ValueKey('daily-material-action-a')),
        );
        expect(field.dense, isTrue);
        final texts = tester.widgetList<Text>(find.text('用料a完整名称及其他很长的识别信息'));
        expect(texts.every((text) => text.maxLines == 1), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
