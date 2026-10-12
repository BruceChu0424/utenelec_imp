part of 'production_daily_report_exact_segment_test.dart';

Map<String, dynamic> _reviewDailyDetail() => {
  'id': 'draft',
  'makerId': 'original-maker',
  'billNo': 'SR-REVIEW',
  'billDate': '2026-10-07',
  'status': 0,
  'rowVersion': 7,
  'departmentId': 'workshop',
  'workerIds': ['employee-1'],
  'warehouseId': 'saved-warehouse',
  'supplierId': 'saved-supplier',
  'sourceDocNo': 'original-report-source',
  'items': [
    {
      'id': 'stored-review-item',
      'goodsId': 'goods-1',
      'goodsName': '测试成品',
      'qty': 4,
      'qtyExact': '4',
      'defectQty': 1,
      'defectQtyExact': '1',
      'unitId': 'unit-1',
      'unitRate': 1,
      'unitRateExact': '1',
      'planId': 'plan-1',
      'planItemId': 'plan-item-1',
      'planNo': 'SJ-1',
      'executionSegmentId': 'segment-1',
    },
  ],
  'outputBatches': [
    {
      'batchKey': 'review-batch',
      'sourceItemId': 'stored-review-item',
      'itemIds': ['stored-review-item'],
      'qty': 4,
      'qtyExact': '4',
      'groups': [
        {
          'destination': 'WAREHOUSE',
          'itemIds': ['stored-review-item'],
          'qty': 4,
          'qtyExact': '4',
        },
      ],
    },
  ],
};

void registerDailyReviewedSaveTests() {
  testWidgets(
    'reviewer edits output and defects in the creation grid with redlines and snapshot-only save',
    (tester) async {
      Map<String, dynamic>? reviewed;
      var ordinaryWrites = 0;
      final snapshot = List.filled(64, 'd').join();
      final api = _api(
        responseOverride: (request) {
          if (request.path.endsWith('/daily-reports/draft/draft-review')) {
            if (request.method == 'GET') {
              return {'snapshot': snapshot, 'detail': _reviewDailyDetail()};
            }
            reviewed = Map<String, dynamic>.from(request.data as Map);
            return _createFixtureHttpError(request, 422);
          }
          if (request.path.endsWith('/daily-reports/draft') &&
              request.method == 'PUT') {
            ordinaryWrites++;
          }
          if (request.path.endsWith('/master/goods/lookup')) {
            return [
              {'id': 'goods-1', 'name': '测试成品', 'code': 'P01'},
            ];
          }
          return null;
        },
      );
      await _pumpNewReport(
        tester,
        api,
        page: const ProductionDailyReportEditPage(
          id: 'draft',
          reviewMode: true,
        ),
        extraPermissions: {Perm.productionDailyReportApprove},
      );
      final grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
        find.byType(UtenEditableGrid<DailyGridRow>),
      );
      expect(grid.showAddRow, isFalse);
      expect(grid.showRowDelete, isFalse);
      final row = _productRows(tester).firstWhere((row) => !row.isSubRow);
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && identical(w.controller, row.qty),
        ),
        '6',
      );
      await tester.enterText(_defectField(row), '2');
      for (final allocation in row.allocationRows) {
        allocation.allocationQty.text = '6';
      }
      await tester.pump();
      final retained = find.byKey(
        ValueKey('daily-review-before-qty-${row.hashCode}'),
      );
      expect(retained, findsOneWidget);
      expect(
        tester.widget<Text>(retained).style!.decoration,
        TextDecoration.lineThrough,
      );
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(reviewed, isNotNull);
      expect(ordinaryWrites, 0);
      expect(reviewed!['expectedSnapshot'], snapshot);
      expect(reviewed!['approveNow'], isFalse);
      final doc = Map<String, dynamic>.from(reviewed!['document'] as Map);
      final item = Map<String, dynamic>.from(
        (doc['items'] as List).single as Map,
      );
      expect(item['reviewSourceItemId'], 'stored-review-item');
      expect(item['planItemId'], 'plan-item-1');
      expect(item['executionSegmentId'], 'segment-1');
      expect(item['qty'], 6);
      expect(item['defectQty'], 2);
      expect(doc['expectedVersion'], 7);
      expect(doc['warehouseId'], 'saved-warehouse');
      expect(doc['supplierId'], 'saved-supplier');
      expect(doc['sourceDocNo'], 'original-report-source');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'server denied review never exposes accepted cells or submits a reviewer snapshot',
    (tester) async {
      var calls = 0;
      final api = _api(
        responseOverride: (request) {
          if (request.path.contains('draft-review')) {
            calls++;
            return _createFixtureHttpError(request, 403);
          }
          return null;
        },
      );
      await _pumpNewReport(
        tester,
        api,
        page: const ProductionDailyReportEditPage(
          id: 'draft',
          reviewMode: true,
        ),
      );
      expect(calls, 1);
      expect(find.byType(UtenEditableGrid<DailyGridRow>), findsNothing);
      expect(find.text('保存并审核'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'changing reviewer identity hides accepted report cells and cannot reuse the old snapshot',
    (tester) async {
      var saves = 0;
      final api = _api(
        responseOverride: (request) {
          if (request.path.endsWith('/daily-reports/draft/draft-review')) {
            if (request.method == 'GET') {
              return {
                'snapshot': List.filled(64, 'e').join(),
                'detail': _reviewDailyDetail(),
              };
            }
            saves++;
            return _createFixtureHttpError(request, 422);
          }
          return null;
        },
      );
      await _pumpNewReport(
        tester,
        api,
        page: const ProductionDailyReportEditPage(
          id: 'draft',
          reviewMode: true,
        ),
        extraPermissions: {Perm.productionDailyReportApprove},
        followSessionIdentity: true,
      );
      expect(find.byType(UtenEditableGrid<DailyGridRow>), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionDailyReportEditPage)),
      );
      (container.read(sessionProvider.notifier) as _ExactSegmentSession)
          .switchAccount();
      await tester.pumpAndSettle();
      expect(find.byType(UtenEditableGrid<DailyGridRow>), findsNothing);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
