part of 'production_daily_report_detail_approve_test.dart';

void registerDailyReviewV3MergeCases() {
  testWidgets(
    'review-save returns draft then fresh V3 materials before one new-version approval',
    (tester) async {
      final (api, _) = await _pump(
        tester,
        routeUnapproval: true,
        capability: 3,
        onApprove: (server) {
          server.serverStatus = 1;
          server.includeReceipt = true;
          server.rememberApproval();
          return null;
        },
      );
      await tester.tap(find.widgetWithText(UtenButton, '修改后审核'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存编辑 null'));
      await tester.pumpAndSettle();
      expect(api.rowVersion, 1);
      expect(api.materialReads, 2);
      expect(api.approveBodies, isEmpty);
      expect(find.widgetWithText(FilledButton, '确认审核'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pumpAndSettle();
      expect(api.approveBodies, hasLength(1));
      expect(api.approveBodies.single['commandVersion'], 3);
      expect(api.approveBodies.single['expectedVersion'], 1);
      expect(
        api.approveBodies.single['materialReviewFingerprint'],
        'material-snapshot-1',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'reviewed material surplus never acquires a default KEEP or RETURN decision',
    (tester) async {
      final (api, notices) = await _pump(
        tester,
        routeUnapproval: true,
        capability: 3,
        materialRows: [_materialRow('a')],
        onApprove: (_) => null,
      );
      await tester.tap(find.widgetWithText(UtenButton, '修改后审核'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存编辑 null'));
      await tester.pumpAndSettle();
      expect(api.materialReads, 2);
      expect(api.approveBodies, isEmpty);
      expect(find.widgetWithText(FilledButton, '确认审核'), findsNothing);
      expect(notices, contains('请逐料选择退回仓库或留在车间，再确认审核'));
      expect(
        find.byKey(const ValueKey('daily-material-action-a')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a newer mutation after reviewed-save stops approval and says the saved draft remains',
    (tester) async {
      final (api, notices) = await _pump(
        tester,
        routeUnapproval: true,
        capability: 3,
        onApprove: (_) => null,
      );
      api.afterReviewedSave = (server) => server.rowVersion++;
      await tester.tap(find.widgetWithText(UtenButton, '修改后审核'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存编辑 null'));
      await tester.pumpAndSettle();
      expect(api.rowVersion, 2);
      expect(api.approveBodies, isEmpty);
      expect(find.widgetWithText(FilledButton, '确认审核'), findsNothing);
      expect(
        notices.any(
          (text) => text.contains('核改已保存为草稿') && text.contains('本次未继续审核'),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'account changes at the saved draft boundary cannot read fresh materials or submit approval',
    (tester) async {
      final (api, notices) = await _pump(
        tester,
        routeUnapproval: true,
        capability: 3,
        onApprove: (_) => null,
      );
      api.afterReviewedSave = (server) =>
          server.container.read(_scope.notifier).state =
              const AuthenticatedScope(userId: 'other-reviewer');
      await tester.tap(find.widgetWithText(UtenButton, '修改后审核'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存编辑 null'));
      await tester.pumpAndSettle();
      expect(api.materialReads, 1);
      expect(api.approveBodies, isEmpty);
      expect(
        notices.any(
          (text) => text.contains('核改已保存为草稿') && text.contains('本次未继续审核'),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
