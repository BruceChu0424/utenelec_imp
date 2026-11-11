part of 'production_daily_report_exact_segment_test.dart';

void registerDailyReportPartialQuantityTests() {
  testWidgets(
    'editing draft reselect uses its server-fenced capacity and saves 400 of 500',
    (tester) async {
      final reads = <RequestOptions>[];
      final saved = <Map<String, dynamic>>[];
      final grid = await _pumpEditDraftPage(
        tester,
        sourceOverrides: const {
          'planId': 'plan-1',
          'plannedQty': 1000,
          'remainingPlanQty': 1000,
          'maxReportQty': 500,
          'maxReportQtyExact': '500',
          'materialReportQtyExact': '500',
          'allowActualOverproduction': true,
        },
        onSourceRequest: reads.add,
        onPutBody: saved.add,
        surfaceSize: const Size(2700, 1250),
        itemsOverride: [
          {
            'id': 'line-1',
            'goodsId': 'goods-1',
            'planId': 'plan-1',
            'planItemId': 'plan-item-1',
            'planNo': 'SJ-001',
            'executionSegmentId': 'segment-1',
            'unitId': 'unit-1',
            'unitRate': 1,
            'qty': 300,
            'outputBatchId': 'batch-one',
            'outputBatchQty': 300,
            'salesOrderItemId': 'order-item-1',
            'allowActualOverproduction': true,
          },
        ],
      );
      final row = grid.rows.firstWhere((row) => !row.isSubRow);
      expect(row.qty.text, '300');
      final reselect = find.byTooltip('重新选择来源子任务');
      await tester.ensureVisible(reselect);
      await tester.tap(reselect);
      await tester.pumpAndSettle();
      await tester.tap(find.text('SJ-001\nSEG-001'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(reads, isNotEmpty);
      for (final read in reads) {
        expect(read.queryParameters['editingReportId'], 'draft');
        expect(read.queryParameters['expectedReportVersion'], 1);
      }
      expect(row.materialReportQtyExact, '500');
      row.qty.text = '400';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved.single['expectedVersion'], 1);
      final savedLine =
          (saved.single['items'] as List<Object?>).first!
              as Map<String, dynamic>;
      expect(savedLine['qty'], 400);
      expect(row.qty.text, '400');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial issue blocks over-kit reporting before preview and preserves repeated input',
    (tester) async {
      var creates = 0;
      var previews = 0;
      final api = _api(
        sourceOverrides: {
          'planId': 'plan-1',
          'plannedQty': 10000,
          'remainingPlanQty': 10000,
          'maxReportQty': 5000,
          'maxReportQtyExact': '5000',
          'materialReportQtyExact': '5000',
          'remainingActualSurplusQty': 1000,
          'allowActualOverproduction': true,
        },
        onCreate: (_) => creates++,
        previewResult: (_) {
          previews++;
          return {'requiresSupplements': false, 'lines': <dynamic>[]};
        },
      );
      await _pumpNewReport(tester, api, surfaceSize: const Size(1800, 1000));
      final row = _productRows(tester).single;
      expect(row.materialReportQtyExact, '5000');
      expect(row.qty.text, '5000');
      final quantityField = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller == row.qty,
      );
      await tester.enterText(quantityField, '6000');
      row.overLimitReason.text = '现场实际数量说明不能扩大物料配套额度';
      await tester.pumpAndSettle();
      for (var index = 0; index < 3; index++) {
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
      }
      expect(creates, 0);
      expect(previews, 0);
      expect(row.qty.text, '6000');
      expect(find.textContaining('物料配套可报数量 5000'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  for (final allowsActualOutput in [false, true]) {
    testWidgets(
      '1000 task saves the entered 800 with the exact source and no final flag: actualOutput=$allowsActualOutput',
      (tester) async {
        await setUtenTestSurfaceSize(tester, const Size(1800, 1000));
        addTearDown(() => setUtenTestSurfaceSize(tester, null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        Map<String, dynamic>? submitted;
        var previewReads = 0;
        final api = _api(
          sourceOverrides: {
            'planId': 'plan-1',
            'plannedQty': 1000,
            'remainingPlanQty': 1000,
            'maxReportQty': 1000,
            'executionSegmentSalesAllocationId': 'allocation-1',
            'remainingActualSurplusQty': 0,
            'allowActualOverproduction': allowsActualOutput,
          },
          onCreate: (body) => submitted = body,
          previewResult: (body) {
            previewReads++;
            final previewItem =
                ((body['report'] as Map)['items'] as List).single as Map;
            expect(previewItem['qty'], 800);
            return {'requiresSupplements': false, 'lines': <dynamic>[]};
          },
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              // Riverpod 3 禁止重复 override；本用例自带 session 与 apiBaseUrl
              // 覆盖（v2 后者生效口径），关闭 spread 里的同名两项。
              ...nativeDetailReaderOverrides(
                includeSession: false,
                includeServer: false,
              ),
              apiClientProvider.overrideWithValue(api),
              departmentRepositoryProvider.overrideWithValue(
                _FakeDepartmentRepository(),
              ),
              masterNameServiceProvider.overrideWithValue(
                MasterNameService(api),
              ),
              productionDailyReportRepositoryProvider.overrideWithValue(
                ProductionDailyReportRepository(api),
              ),
              employeeRepositoryProvider.overrideWithValue(
                _FakeEmployeeRepository(),
              ),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue({
                Perm.productionDailyReportCreate,
                Perm.productionDailyReportView,
              }),
              formDraftStorageProvider.overrideWithValue(
                MemoryFormDraftStorage(),
              ),
              sessionProvider.overrideWith(_ExactSegmentSession.new),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'report-user'),
              ),
              apiBaseUrlProvider.overrideWith(
                (ref) => 'https://test-server/api',
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ProductionDailyReportEditPage(
                initialExecutionSegmentId: 'segment-1',
                returnToWorkshopTasks: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final row = tester
            .widget<UtenEditableGrid<DailyGridRow>>(
              find.byType(UtenEditableGrid<DailyGridRow>),
            )
            .controller
            .rows
            .single;
        expect(row.qty.text, '1000');
        final quantityField = find.byWidgetPredicate(
          (widget) => widget is TextField && widget.controller == row.qty,
        );
        await tester.enterText(quantityField, '800');
        await tester.pumpAndSettle();
        expect(row.qty.text, '800');
        expect(row.allocationRows.single.allocationQty.text, '800');
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(submitted, isNotNull);
        final item = (submitted!['items'] as List).single as Map;
        expect(item['qty'], 800);
        expect(item['planItemId'], 'plan-item-1');
        expect(item['executionSegmentId'], 'segment-1');
        expect(item['executionSegmentSalesAllocationId'], 'allocation-1');
        expect(item['salesOrderItemId'], 'order-item-1');
        expect(item['isFinal'], isNull);
        expect(item['allocations'], isNull); // All 800 go to the warehouse.
        expect(previewReads, allowsActualOutput ? 1 : 0);
        // The simulated response is unknown: its original 800 request remains
        // frozen for receipt recovery, with no expansion to the task's plan total.
        expect(row.qty.text, '800');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
