part of 'production_daily_report_detail_approve_test.dart';

void registerDailyReportMaterialRecoveryCases() {
  testWidgets(
    'V3 partially held source remains selectable and explains the server restriction in one-line field tooltip',
    (tester) async {
      final partial = _materialRow('partial', blocked: '部分原领料已由后续批次承接')
        ..['returnableIssuedQty'] = 2;
      final (api, _) = await _pump(
        tester,
        capability: 3,
        materialRows: [partial],
        onApprove: (server) {
          server.serverStatus = 1;
          server.includeReceipt = true;
          server.rememberApproval();
          return null;
        },
      );
      final field = tester.widget<UtenDropdownField>(
        find.byKey(const ValueKey('daily-material-action-partial')),
      );
      expect(field.dense, isTrue);
      expect(field.enabled, isTrue);
      expect(find.byTooltip('只申请本次可退数量；部分原领料已由后续批次承接，其余留在车间'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('daily-material-return-all')));
      await tester.pumpAndSettle();
      await _tapApprove(tester);
      expect(api.approveBodies.single['materialDecisions'], [
        {'demandId': 'partial', 'action': 'RETURN'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'V3 confirmed receipt with failed local cleanup keeps original review marked confirmed',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 3,
        materialRows: _reviewRows(),
        onApprove: (server) {
          server.serverStatus = 1;
          server.includeReceipt = true;
          server.rememberApproval();
          server.approvalStorage.failWrites = true;
          return null;
        },
      );
      await tester.tap(find.byKey(const ValueKey('daily-material-keep-all')));
      await tester.pumpAndSettle();
      await _tapApprove(tester);
      expect(api.approvalStorage.records, hasLength(1));
      expect(find.text('结果已核对'), findsOneWidget);
      expect(find.text('结果待核对'), findsNothing);
      expect(
        find.byKey(const Key('daily-report-retry-original-approval')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'V3 KEEP-only history never claims a return application was created',
    (tester) async {
      await _pump(
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
      await tester.tap(find.byKey(const ValueKey('daily-material-keep-all')));
      await tester.pumpAndSettle();
      await _tapApprove(tester);
      expect(find.text('以下为审核时保存的用料与余料处理记录。'), findsOneWidget);
      expect(find.text('退仓申请已登记'), findsNothing);
      expect(find.text('无余料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final readFails in [false, true]) {
    testWidgets(
      'V3 reopened unknown shows original balances instead of current snapshot: readFails=$readFails',
      (tester) async {
        final (oldApi, _) = await _pump(
          tester,
          capability: 3,
          materialRows: _reviewRows(),
          onApprove: (_) => NetworkTimeoutException(),
        );
        await tester.tap(
          find.byKey(const ValueKey('daily-material-return-all')),
        );
        await tester.pumpAndSettle();
        await _tapApprove(tester);
        final original = Map<String, dynamic>.from(oldApi.approveBodies.single);
        final (newApi, _) = await _pump(
          tester,
          capability: 3,
          storage: oldApi.approvalStorage,
          materialRows: [_materialRow('new')],
          materialReadFailure: readFails ? NetworkTimeoutException() : null,
          onApprove: (_) => null,
        );
        expect(find.text('原审核的用料与余料处理'), findsOneWidget);
        expect(newApi.materialReads, 0, reason: '未知审核恢复直接使用原快照，不读当前余额重算原选择');
        expect(
          find.byKey(const ValueKey('daily-material-review-unavailable')),
          findsNothing,
        );
        final table = tester
            .widget<MasterDataTableView<DailyReportMaterialReviewRow>>(
              find.byWidgetPredicate(
                (w) => w is MasterDataTableView<DailyReportMaterialReviewRow>,
              ),
            );
        expect(table.items.map((row) => row.demandId), ['a', 'b', 'zero']);
        expect(table.items.first.usageQty, '6');
        expect(find.text('退回仓库（原选择）'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('daily-report-retry-original-approval')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '重试原审核'));
        await tester.pumpAndSettle();
        expect(newApi.approveBodies.single, original);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'V3 unknown cannot settle with a legacy receipt that proves no material decision',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        capability: 3,
        materialRows: _reviewRows(),
        onApprove: (server) {
          server.serverStatus = 1;
          server.includeReceipt = true;
          server.rememberApproval(protocol: 1);
          server.receipt!.remove('reviewedVersion');
          return null;
        },
      );
      await tester.tap(find.byKey(const ValueKey('daily-material-keep-all')));
      await tester.pumpAndSettle();
      await _tapApprove(tester);
      expect(api.approvalStorage.records, hasLength(1));
      expect(find.text('原审核的用料与余料处理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
