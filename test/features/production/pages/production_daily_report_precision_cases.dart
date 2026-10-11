part of 'production_daily_report_exact_segment_test.dart';

Map<String, dynamic> _precisionOnlyItem(Object? value) =>
    Map<String, dynamic>.from((value as List).single as Map);

void registerDailyReportPrecisionTests() {
  for (final sample in [
    ('100000000000000', 0.1, '完工申报量超过系统计量范围'),
    ('10000000000000', 10.0, '换算后的基本量超过系统计量范围'),
    ('99999999999999.9999', 1.0, null),
  ]) {
    testWidgets(
      'exact daily quantity storage boundary: ${sample.$1} rate=${sample.$2}',
      (tester) async {
        final sent = <Map<String, dynamic>>[];
        await _pumpNewReport(
          tester,
          _api(
            sourceOverrides: {
              'unitRate': sample.$2,
              'maxReportQty': 100000000000000.0,
              'maxReportQtyExact': '99999999999999.9999',
            },
            onCreate: sent.add,
          ),
        );
        final row = _productRows(tester).single;
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField && identical(widget.controller, row.qty),
          ),
          sample.$1,
        );
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(row.qty.text, sample.$1);
        if (sample.$3 case final issue?) {
          expect(sent, isEmpty);
          expect(find.textContaining('第 1 行$issue'), findsOneWidget);
        } else {
          expect(_precisionOnlyItem(sent.single['items'])['qty'], sample.$1);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'exact daily typed short fractions retain output and defect values when saving',
    (tester) async {
      final sent = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: const {'unitRate': null, 'unitRateExact': '0.4'},
          onCreate: sent.add,
        ),
      );
      final row = _productRows(tester).single;
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && identical(widget.controller, row.qty),
        ),
        '.5',
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              identical(widget.controller, row.defectQty),
        ),
        '.1',
      );
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final submitted = _precisionOnlyItem(sent.single['items']);
      expect(submitted['qty'], 0.5);
      expect(submitted['defectQty'], 0.1);
      expect(submitted['unitRate'], 0.4);
      expect(row.qty.text, '.5');
      expect(row.defectQty.text, '.1');
      expect(productionExactQuantityText('1.'), '1');
      expect(productionExactQuantityText('.'), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exact daily material and defect storage overflow fail before dispatch',
    (tester) async {
      Map<String, dynamic>? sent;
      final grid = await _pumpEditDraftPage(
        tester,
        withMaterials: true,
        materialsOverride: [
          {
            'planId': 'plan-1',
            'demandId': 'demand-1',
            'goodsId': 'raw-1',
            'goodsName': '范围测试原料',
            'executionSegmentId': 'segment-1',
            'issuedQty': 100000000000000.0,
            'issuedQtyExact': '100000000000000',
            'availableToSettleQty': 100000000000000.0,
            'availableToSettleQtyExact': '100000000000000',
            'requiredQty': 100,
            'requiredForProductQty': 100,
            'requirementMode': 'LINEAR',
          },
        ],
        onPutBody: (body) => sent = body,
      );
      final material = _materialRows(tester).single;
      material.materialUsed.text = '100000000000000';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(sent, isNull);
      expect(find.textContaining('本次实际用料超过系统计量范围'), findsWidgets);
      expect(material.materialUsed.text, '100000000000000');
      material.materialUsed.text = '0';
      grid.rows.single.defectQty.text = '100000000000000';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(sent, isNull);
      expect(find.textContaining('不良数超过系统计量范围'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  for (final rate in [0.4, 0.5]) {
    testWidgets(
      'exact daily base conversion respects half-up boundary rate=$rate',
      (tester) async {
        final sent = <Map<String, dynamic>>[];
        await _pumpNewReport(
          tester,
          _api(sourceOverrides: {'unitRate': rate}, onCreate: sent.add),
        );
        final row = _productRows(tester).single;
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField && identical(widget.controller, row.qty),
          ),
          '0.0001',
        );
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(row.qty.text, '0.0001');
        if (rate == 0.4) {
          expect(sent, isEmpty);
          expect(find.textContaining('第 1 行换算后的基本量为 0'), findsOneWidget);
        } else {
          expect(_precisionOnlyItem(sent.single['items'])['qty'], 0.0001);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final exactCap in [true, false]) {
    testWidgets(
      'exact daily cap rejects one tick over a large limit exact=$exactCap',
      (tester) async {
        final sent = <Map<String, dynamic>>[];
        await _pumpNewReport(
          tester,
          _api(
            sourceOverrides: {
              'maxReportQty': 10000000000000.0,
              if (exactCap) 'maxReportQtyExact': '10000000000000',
            },
            onCreate: sent.add,
          ),
        );
        final row = _productRows(tester).single;
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField && identical(widget.controller, row.qty),
          ),
          '10000000000000.0001',
        );
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(sent, isEmpty);
        expect(
          find.textContaining(
            exactCap ? '超过当前可报数量 10000000000000' : '来源可报数量缺少精确原文',
          ),
          findsOneWidget,
        );
        expect(row.qty.text, '10000000000000.0001');
        if (exactCap) {
          await tester.enterText(
            find.byWidgetPredicate(
              (widget) =>
                  widget is TextField && identical(widget.controller, row.qty),
            ),
            '10000000000000',
          );
          await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
          await tester.pumpAndSettle();
          expect(
            _precisionOnlyItem(sent.single['items'])['qty'],
            '10000000000000',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'exact daily same-source sum rejects one tick and permits its exact boundary',
    (tester) async {
      final sent = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: const {
            'maxReportQty': 10000000000000.0,
            'maxReportQtyExact': '10000000000000',
          },
          onCreate: sent.add,
        ),
      );
      final first = _productRows(tester).single;
      first.qty.text = '9999999999999.9999';
      final second = first.clone()..qty.text = '0.0002';
      final grid = tester
          .widget<UtenEditableGrid<DailyGridRow>>(
            find.byType(UtenEditableGrid<DailyGridRow>),
          )
          .controller;
      grid.addRow(second);
      grid.setSelected([second], true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(find.textContaining('多行用了同一个来源任务'), findsOneWidget);
      second.qty.text = '0.0001';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final items = sent.single['items'] as List;
      expect(items, hasLength(2));
      expect((items.first as Map)['qty'], '9999999999999.9999');
      expect((items.last as Map)['qty'], 0.0001);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'exact daily ordinary same-source rows require reason on cumulative excess',
    (tester) async {
      final sent = <Map<String, dynamic>>[];
      await _pumpNewReport(
        tester,
        _api(
          sourceOverrides: const {
            'maxReportQty': 100,
            'remainingActualSurplusQty': 0,
            'allowActualOverproduction': true,
          },
          onCreate: sent.add,
        ),
      );
      final first = _productRows(tester).single..qty.text = '60';
      final second = first.clone()
        ..qty.text = '60'
        ..maxReportQty = 120
        ..maxReportQtyExact = '120';
      final grid = tester
          .widget<UtenEditableGrid<DailyGridRow>>(
            find.byType(UtenEditableGrid<DailyGridRow>),
          )
          .controller;
      grid.addRow(second);
      grid.setSelected([second], true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(find.textContaining('第 2 行与同源行累计超出当前有效额度 20'), findsOneWidget);
      second.overLimitReason.text = '登记这次实际超出数量';
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      final items = sent.single['items'] as List;
      expect(items, hasLength(2));
      expect((items.first as Map)['qty'], 60);
      expect((items.last as Map)['qty'], 60);
      expect((items.last as Map)['overLimitReason'], '登记这次实际超出数量');
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'exact daily material cap and proportional suggestion preserve high four-decimal facts',
    () {
      final material = ProductionMaterialClearanceRow.fromJson({
        'planId': 'plan',
        'demandId': 'demand',
        'goodsId': 'raw',
        'availableToSettleQty': 10000000000000.0,
        'availableToSettleQtyExact': '10000000000000',
        'issuedQty': 10000000000000.0,
        'issuedQtyExact': '10000000000000',
        'requiredQty': 2,
        'requiredForProductQty': 1,
        'requirementMode': 'LINEAR',
      });
      final row = DailyGridRow()
        ..depth = 2
        ..material = material;
      addTearDown(row.dispose);
      row.materialUsed.text = '10000000000000.0001';
      expect(row.materialInvalid, isTrue);
      row.materialUsed.text = '10000000000000';
      expect(row.materialInvalid, isFalse);
      expect(
        expectedMaterialUsageText(
          reportedQty: '4999999999999.9999',
          material: material,
        ),
        '9999999999999.9998',
      );
      row.material = ProductionMaterialClearanceRow.fromJson({
        'planId': 'plan',
        'demandId': 'demand',
        'goodsId': 'raw',
        'availableToSettleQty': 10000000000000.0,
      });
      expect(row.materialCapText, isNull);
      expect(
        row.materialInvalid,
        isTrue,
        reason: 'rounded legacy cap cannot authorize any material amount',
      );
    },
  );

  test(
    'exact daily shared-demand products sum once and retain cap provenance on copy',
    () {
      final first = DailyGridRow()
        ..qty.text = '9999999999999.9999'
        ..maxReportQty = 10000000000000.0
        ..maxReportQtyExact = '10000000000000'
        ..allowActualOverproduction = true
        ..remainingActualSurplusQty = 0.0001
        ..remainingActualSurplusQtyExact = '0.0001';
      final second = first.clone()..qty.text = '0.0001';
      final material = ProductionMaterialClearanceRow.fromJson({
        'planId': 'plan',
        'demandId': 'demand',
        'goodsId': 'raw',
      });
      final rows = [
        for (final parent in [first, first, second])
          DailyGridRow()
            ..depth = 2
            ..material = material
            ..materialParent = parent,
      ];
      addTearDown(() {
        for (final row in [...rows, first, second]) {
          row.dispose();
        }
      });
      expect(
        materialReportedQuantityText('demand', rows, {first, second}),
        '10000000000000',
      );
      expect(second.reportQtyCapText, '10000000000000.0001');
      second.maxReportQty = null;
      second.remainingActualSurplusQty = null;
      expect(second.hasReportQtyCap, isTrue);
      expect(
        second.reportQtyCapText,
        '10000000000000.0001',
        reason:
            'exact-only facts determine capacity without rounded numeric fallback',
      );
      second.maxReportQtyExact = null;
      expect(
        second.reportQtyCapText,
        '0.0001',
        reason: 'exact-only surplus is a real finite capacity',
      );
      second
        ..fqcRecoveryAuthorizationId = 'fqc-authority'
        ..maxReportQtyExact = '0.0001'
        ..remainingActualSurplusQtyExact = '100';
      expect(second.canRecordOverLimit, isFalse);
      expect(
        second.reportQtyCapText,
        '0.0001',
        reason:
            'recovery uses its exact authorization and never adds ordinary surplus',
      );
      final batch = ProductionDailyReportOutputBatch.fromJson({
        'batchKey': 'same-physical-batch',
        'itemIds': ['demand-slice', 'surplus-slice'],
        'qty': 10000000000000.0,
        'qtyExact': '9999999999999.9999',
        'summary': '服务端冻结的批次摘要',
        'groups': [
          {
            'itemIds': ['demand-slice', 'surplus-slice'],
            'qty': 10000000000000.0,
            'qtyExact': '9999999999999.9999',
            'demandQty': 10000000000000.0,
            'demandQtyExact': '9999999999999.9998',
            'publicQtyExact': '0',
            'actualSurplusQtyExact': '0.0001',
          },
        ],
      });
      expect(batch.qtyText, '9999999999999.9999');
      expect(batch.groups.single.qtyText, batch.qtyText);
      expect(batch.groups.single.demandQtyText, '9999999999999.9998');
      expect(batch.groups.single.publicQtyText, '0');
      expect(batch.groups.single.actualSurplusQtyText, '0.0001');
      expect(productionQuantityWithUnit('0.0001', '个'), '0.0001 个');
      expect(
        const ProductionDailyReportOutputBatch(
          batchKey: 'legacy',
          itemIds: [],
          qty: 10000000000000,
          summary: '',
        ).qtyText,
        isNull,
      );
    },
  );

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
