part of 'production_daily_report_exact_segment_test.dart';

void registerDailyReportNavigationTests() {
  for (final goBack in [false, true]) {
    testWidgets(
      'supplement view returns without resaving and unlocks report save go=$goBack',
      (tester) async {
        var previews = 0, creates = 0, supplementWrites = 0;
        final api = _api(
          onCreate: (_) => creates++,
          previewResult: (_) {
            previews++;
            return {'requiresSupplements': false, 'lines': <Object>[]};
          },
          responseOverride: (request) {
            if (request.path.endsWith(
              '/actual-output-supplements/pending-supplement',
            )) {
              return <String, dynamic>{
                'id': 'pending-supplement',
                'status': 'PENDING',
                'actualQty': 2,
                'planNo': 'SUP-PENDING',
                'sourceLine': <String, dynamic>{
                  'planId': 'plan-1',
                  'planItemId': 'plan-item-1',
                  'planNo': 'SJ-001',
                  'executionSegmentId': 'segment-1',
                  'goodsId': 'goods-1',
                  'unitId': 'unit-1',
                  'plannedQty': 10,
                  'reportedQty': 0,
                  'maxReportQty': 10,
                },
              };
            }
            if (request.method == 'POST' &&
                request.path.endsWith('/actual-output-supplements')) {
              supplementWrites++;
            }
            return null;
          },
        );
        const sourcePath = '/production/daily-reports/new';
        final router = GoRouter(
          initialLocation: sourcePath,
          routes: [
            GoRoute(
              path: sourcePath,
              builder: (_, _) => const ProductionDailyReportEditPage(
                initialExecutionSegmentId: 'segment-1',
              ),
            ),
            GoRoute(
              path: '/production/actual-output-supplements/:id',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => context.replace('/supplement-review'),
                  child: const Text('replace supplement view'),
                ),
              ),
            ),
            GoRoute(
              path: '/supplement-review',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      goBack ? context.go(sourcePath) : context.pop(),
                  child: const Text('return report inputs'),
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await _pumpNewReport(tester, api, router: router);
        final sourceState = tester.state(
          find.byType(ProductionDailyReportEditPage),
        );
        final row = _productRows(tester).first;
        row.qty.text = '2';
        row.remark.text = '保留数量和说明';
        row.supplementRequestId = 'pending-supplement';
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(find.text('查看追加计划'), findsOneWidget);
        await tester.tap(find.text('查看追加计划'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('replace supplement view'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('return report inputs'));
        await tester.pumpAndSettle();
        expect(
          tester.state(find.byType(ProductionDailyReportEditPage)),
          same(sourceState),
        );
        expect(_productRows(tester).first, same(row));
        expect(row.qty.text, '2');
        expect(row.remark.text, '保留数量和说明');
        expect(creates, 0);
        expect(supplementWrites, 0);
        expect(previews, 1);
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(
          previews,
          2,
          reason:
              'The save preparation guard must be released after its view-only visit.',
        );
        expect(find.text('查看追加计划'), findsOneWidget);
        expect(creates, 0);
        expect(
          supplementWrites,
          0,
          reason: 'Returning from a view must not resume or replay a write.',
        );
        await tester.tap(find.text('返回原报工表'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
