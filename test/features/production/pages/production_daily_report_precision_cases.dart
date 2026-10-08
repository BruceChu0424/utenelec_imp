part of 'production_daily_report_exact_segment_test.dart';

Map<String, dynamic> _precisionOnlyItem(Object? value) =>
    Map<String, dynamic>.from((value as List).single as Map);

void registerDailyReportPrecisionTests() {
  testWidgets(
    'exact daily quantity old high draft needs manual verification and clones stay blocked',
    (tester) async {
      const quantity = '9999999999999.9999';
      final sent = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: const {
            'maxReportQty': 10000000000000.0,
            'maxReportQtyExact': quantity,
          },
          onCreate: sent.add,
        ),
      );
      final state =
          tester.state(find.byType(ProductionDailyReportEditPage))
              as FormDraftMixin;
      final data = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(state.captureFormDraft())) as Map,
      );
      final oldRow = _precisionOnlyItem(data['rows'])
        ..remove('quantityTextConfirmed');
      data['rows'] = [oldRow];
      await state.restoreFormDraft(data);
      await tester.pumpAndSettle();
      final row = _productRows(tester).firstWhere((row) => !row.isSubRow);
      expect(row.qty.text, quantity);
      expect(row.qtyNeedsVerification, isTrue);
      row.qty.text = '9999999999999.9998';
      row.qty.text = quantity;
      expect(row.qtyNeedsVerification, isTrue, reason: '程序回填不是用户核对');
      final copy = row.clone();
      expect(copy.qtyNeedsVerification, isTrue);
      copy.dispose();
      expect(
        _precisionOnlyItem(
          state.captureFormDraft()['rows'],
        )['quantityTextConfirmed'],
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && identical(widget.controller, row.qty),
      );
      await tester.enterText(field, '');
      await tester.enterText(field, quantity);
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(_precisionOnlyItem(sent.single['items'])['qty'], quantity);
      expect(tester.takeException(), isNull);
    },
  );
  for (final exact in [true, false]) {
    testWidgets('exact daily quantity direct preview and create exact=$exact', (
      tester,
    ) async {
      const quantity = '9999999999999.9999';
      final sent = <Map<String, dynamic>>[];
      Map<String, dynamic>? previewed;
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: const {
            'planId': 'plan-1',
            'maxReportQty': 100,
            'allowActualOverproduction': true,
          },
          onCreate: sent.add,
          responseOverride: (request) =>
              request.path.endsWith('/direct-transfers/candidates')
              ? {
                  'candidates': [
                    {
                      'demandId': 'exact-target',
                      'executionSegmentId': 'target-segment',
                      'remainingQty': 10000000000000.0,
                      if (exact) 'remainingQtyExact': '9999999999999.9998',
                    },
                  ],
                  'receiverLimit': 30,
                }
              : null,
          previewResult: (body) {
            previewed = body;
            return {
              'requiresSupplements': false,
              'lines': [
                {
                  'inputLineIndex': 0,
                  'sourceExecutionSegmentId': 'segment-1',
                  'actualQtyExact': quantity,
                  'actualQty': 10000000000000.0,
                  'withinAuthorizationQty': '100',
                  'overLimitQty': '9999999999899.9999',
                },
              ],
            };
          },
        ),
      );
      final row = _productRows(tester).firstWhere((row) => !row.isSubRow);
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && identical(widget.controller, row.qty),
        ),
        quantity,
      );
      row.overLimitReason.text = '登记真实产量';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      if (exact) {
        final expected = [
          {
            'directTransferDemandId': 'exact-target',
            'qty': '9999999999999.9998',
          },
          {'directTransferDemandId': null, 'qty': 0.0001},
        ];
        expect(
          _precisionOnlyItem((previewed!['report'] as Map)['items'])['qty'],
          quantity,
        );
        expect(
          _precisionOnlyItem(
            (previewed!['report'] as Map)['items'],
          )['allocations'],
          expected,
        );
        await tester.tap(find.text('按实际数量保存'));
        await tester.pumpAndSettle();
        expect(_precisionOnlyItem(sent.single['items'])['qty'], quantity);
        expect(
          _precisionOnlyItem(sent.single['items'])['allocations'],
          expected,
        );
      } else {
        expect(previewed, isNull);
        expect(sent, isEmpty);
        expect(find.textContaining('转送数量对不上原来的分配'), findsOneWidget);
      }
      expect(row.qty.text, quantity);
      expect(tester.takeException(), isNull);
    });
  }
  for (final exact in [true, false]) {
    testWidgets('exact daily quantity unedited source default exact=$exact', (
      tester,
    ) async {
      const quantity = '9999999999999.9999';
      final saved = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: {
            'maxReportQty': double.parse(quantity),
            if (exact) 'maxReportQtyExact': quantity,
            'unitRate': 0.000032,
            'unitRateExact': '0.000032',
          },
          onCreate: saved.add,
        ),
      );
      final row = _productRows(tester).firstWhere((row) => !row.isSubRow);
      expect(row.qty.text, exact ? quantity : '');
      if (exact) {
        final copy = row.clone();
        expect(copy.qty.text, quantity);
        expect(copy.unitRateText, '0.000032');
        copy.dispose();
        final state =
            tester.state(find.byType(ProductionDailyReportEditPage))
                as FormDraftMixin;
        final draft = jsonDecode(jsonEncode(state.captureFormDraft())) as Map;
        expect(_precisionOnlyItem(draft['rows'])['qty'], quantity);
        expect(_precisionOnlyItem(draft['rows'])['unitRateExact'], '0.000032');
      }
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      if (exact) {
        expect(_precisionOnlyItem(saved.single['items'])['qty'], quantity);
        expect(_precisionOnlyItem(saved.single['items'])['unitRate'], 0.000032);
      } else {
        expect(saved, isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final exact in [true, false]) {
    testWidgets(
      'exact daily quantity existing report unedited save exact=$exact',
      (tester) async {
        const quantity = '9999999999999.9999';
        Map<String, dynamic>? saved;
        final item = <String, dynamic>{
          'id': 'stored-item',
          'goodsId': 'goods-1',
          'unitId': 'unit-1',
          'qty': 10000000000000.0,
          'outputBatchQty': 10000000000000.0,
          if (exact) 'qtyExact': quantity,
          if (exact) 'outputBatchQtyExact': quantity,
          'unitRate': 0.000032,
          'unitRateExact': '0.000032',
          'defectQty': 0.0001,
          'defectQtyExact': '0.0001',
          'planId': 'plan-1',
          'planItemId': 'plan-item-1',
          'executionSegmentId': 'segment-1',
        };
        await _pumpNewReport(
          tester,
          _api(
            responseOverride: (request) {
              if (request.path.endsWith('/master/goods/lookup')) {
                return [
                  {'id': 'goods-1', 'name': '测试成品', 'code': 'P01'},
                ];
              }
              if (request.path.endsWith('/daily-reports/existing')) {
                if (request.method == 'PUT') {
                  saved = Map<String, dynamic>.from(request.data as Map);
                  return _createFixtureHttpError(request, 422);
                }
                return {
                  'id': 'existing',
                  'makerId': 'employee-1',
                  'billDate': '2026-10-07',
                  'status': 0,
                  'rowVersion': 1,
                  'departmentId': 'workshop',
                  'items': [item],
                  'outputBatches': [
                    {
                      'batchKey': 'batch',
                      'sourceItemId': 'stored-item',
                      'itemIds': ['stored-item'],
                      'qty': 10000000000000.0,
                      'groups': <Object>[],
                    },
                  ],
                };
              }
              return null;
            },
          ),
          page: const ProductionDailyReportEditPage(id: 'existing'),
        );
        if (exact) {
          final row = _productRows(tester).firstWhere((row) => !row.isSubRow);
          expect(row.qty.text, quantity);
          expect(row.defectQty.text, '0.0001');
          await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
          await tester.pumpAndSettle();
          expect(_precisionOnlyItem(saved!['items'])['qty'], quantity);
          expect(_precisionOnlyItem(saved!['items'])['defectQty'], 0.0001);
          expect(_precisionOnlyItem(saved!['items'])['unitRate'], 0.000032);
        } else {
          expect(find.text('日报草稿未能读取，原有内容没有改变'), findsOneWidget);
          expect(saved, isNull);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'exact daily quantity stored slices retain batch, defect and allocation originals',
    () {
      final group = ProductionDailyReportInputGroup([
        ProductionDailyReportItem.fromJson({
          'id': 'slice',
          'qty': 10000000000000.0,
          'qtyExact': '9999999999999.9999',
          'outputBatchQty': 10000000000000.0,
          'outputBatchQtyExact': '9999999999999.9999',
          'defectQty': 0.0001,
          'defectQtyExact': '0.0001',
          'unitRate': 0.000032,
          'unitRateExact': '0.000032',
        }),
      ]);
      expect(group.qtyText, '9999999999999.9999');
      expect(group.defectQtyText, '0.0001');
      expect(group.source.unitRateText, '0.000032');
      expect(group.allocations.single['qty'], '9999999999999.9999');
      final legacy = ProductionDailyReportInputGroup([
        const ProductionDailyReportItem(id: 'legacy', qty: 10000000000000.0),
      ]);
      expect(legacy.qtyText, isNull);
      expect(() => legacy.allocations, throwsFormatException);
      expect(productionExactQuantityText(1000000.000001, scale: 6), isNull);
      expect(
        productionQuantityWire('999999999999.999999', scale: 6),
        '999999999999.999999',
      );
      expect(productionQuantityWire('0.000032', scale: 6), 0.000032);
    },
  );

  test(
    'exact daily quantity supplement preview to create and freeze retain original text',
    () async {
      Map<String, dynamic>? sent;
      final repository = ProductionOutputSupplementRepository(
        _api(
          responseOverride: (request) {
            if (request.path.endsWith('/actual-output-supplements')) {
              sent = Map<String, dynamic>.from(request.data as Map);
              return {'id': 'supplement', 'status': 'PENDING'};
            }
            return null;
          },
        ),
      );
      await repository.create(
        ProductionOutputSupplementPreview({
          'sourceSegmentId': 'segment-1',
          'fingerprint': 'exact-fingerprint',
          'actualQty': 10000000000000.0,
          'actualQtyExact': '9999999999999.9999',
        }),
        billDate: '2026-10-07',
      );
      expect(sent!['actualQty'], '9999999999999.9999');
      await expectLater(
        repository.create(
          ProductionOutputSupplementPreview({
            'sourceSegmentId': 'segment-1',
            'fingerprint': 'legacy-fingerprint',
            'actualQty': 10000000000000.0,
          }),
          billDate: '2026-10-07',
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'exact daily quantity typed fractional large value reaches preview and create unchanged',
    (tester) async {
      const quantity = '9999999999999.9999';
      Map<String, dynamic>? previewed;
      final saved = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: const {
            'maxReportQty': 100,
            'allowActualOverproduction': true,
          },
          onCreate: saved.add,
          previewResult: (body) {
            previewed = body;
            return {
              'requiresSupplements': false,
              'lines': [
                {
                  'inputLineIndex': 0,
                  'sourceExecutionSegmentId': 'segment-1',
                  'actualQty': double.parse(quantity),
                  'actualQtyExact': quantity,
                  'withinAuthorizationQty': '100',
                  'overLimitQty': '9999999999899.9999',
                  'requiresSupplement': false,
                },
              ],
            };
          },
        ),
      );
      final row = _productRows(tester).firstWhere((row) => !row.isSubRow);
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && identical(widget.controller, row.qty),
        ),
        quantity,
      );
      row.overLimitReason.text = '记录本次真实产量';
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(
        _precisionOnlyItem((previewed!['report'] as Map)['items'])['qty'],
        quantity,
      );
      await tester.tap(find.text('按实际数量保存'));
      await tester.pumpAndSettle();
      expect(_precisionOnlyItem(saved.single['items'])['qty'], quantity);
      expect(
        _precisionOnlyItem(saved.single['items'])['executionSegmentId'],
        'segment-1',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
