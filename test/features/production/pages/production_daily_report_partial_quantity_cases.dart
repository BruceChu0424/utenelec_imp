part of 'production_daily_report_exact_segment_test.dart';

void registerDailyReportPartialQuantityTests() {
  for (final allowsActualOutput in [false, true]) {
    testWidgets(
      '1000 task saves the entered 800 with the exact source and no final flag: actualOutput=$allowsActualOutput',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
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
              ...nativeDetailReaderOverrides(),
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
