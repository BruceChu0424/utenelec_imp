part of 'production_daily_report_exact_segment_test.dart';

const _warehouseLayoutCandidates = <String, dynamic>{
  'candidates': <dynamic>[],
  'unavailableReason': '本任务没有可接收的车间内后续工单',
  'receiverLimit': 30,
};

const _transferLayoutCandidates = <String, dynamic>{
  'candidates': [
    {
      'demandId': 'A',
      'executionSegmentId': 'segment-a',
      'executionSegmentCode': 'ZX-A',
      'receivingGoodsName': '装配接收工单',
      'remainingQty': 100,
    },
  ],
  'receiverLimit': 30,
};

Map<String, dynamic> _destinationLayoutItem(
  String suffix, {
  String? demandId,
  int qty = 10,
  String? lineSuffix,
}) => {
  'id': 'layout-line-${lineSuffix ?? suffix}',
  'goodsId': 'layout-goods-$suffix',
  'goodsName': suffix == 'warehouse' ? 'V5一开按钮' : 'V5开关面板',
  'goodsCode': suffix == 'warehouse' ? 'V50001' : 'V50041',
  'planId': 'layout-plan-$suffix',
  'planItemId': 'layout-plan-item-$suffix',
  'planNo': 'SJ-$suffix',
  'executionSegmentId': 'layout-segment-$suffix',
  'executionSegmentCode': 'ZX-$suffix',
  'unitId': 'unit-1',
  'unitRate': 1,
  'qty': qty,
  'outputBatchId': 'layout-batch-$suffix',
  'outputBatchQty': 10,
  'destination': demandId == null ? 'WAREHOUSE' : 'WORKSHOP',
  'directTransferDemandId': ?demandId,
};

Map<String, dynamic> _destinationLayoutMaterial(String suffix) => {
  'planId': 'layout-plan-$suffix',
  'demandId': 'layout-material-$suffix',
  'goodsId': 'layout-raw-$suffix',
  'goodsName': '铜片-$suffix',
  'executionSegmentId': 'layout-segment-$suffix',
  'issuedQty': 100,
  'unclearedQty': 100,
  'availableToSettleQty': 100,
  'requiredQty': 100,
  'requiredForProductQty': 100,
  'requirementMode': 'LINEAR',
};

UtenEditableGrid<DailyGridRow> _destinationLayoutGrid(WidgetTester tester) =>
    tester.widget<UtenEditableGrid<DailyGridRow>>(
      find.byType(UtenEditableGrid<DailyGridRow>),
    );

Finder _destinationLayoutHeader(String label) => find.descendant(
  of: find.byElementPredicate((element) {
    if (element.widget is! UtenColumnHeaderMenuRegion) return false;
    var main = false;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is UtenEditableGrid<EditableGridRow>) {
        main = widget.tableKey == 'production.daily.items';
        return false;
      }
      return true;
    });
    return main;
  }),
  matching: find.text(label, findRichText: true),
);

Finder _destinationLayoutAllocationCard(DailyGridRow product) => find.byKey(
  ValueKey('daily-product-allocations-card-${product.localRowId}'),
);

Finder _destinationLayoutMaterialCard(DailyGridRow product) =>
    find.byKey(ValueKey('daily-product-materials-card-${product.localRowId}'));

void _expectDestinationLayoutHeaderOrder(WidgetTester tester) {
  final keys = _destinationLayoutGrid(
    tester,
  ).columns.map((column) => column.key);
  expect(keys, [
    'goods',
    'goodsCode',
    'color',
    'qty',
    'destination',
    'overLimitReason',
    'defectQty',
    'planNo',
    'remark',
  ]);
  final quantity = _destinationLayoutHeader('完工申报量 *');
  final destination = _destinationLayoutHeader('产出去向');
  final reason = _destinationLayoutHeader('超限原因');
  expect(quantity, findsOneWidget);
  expect(destination, findsOneWidget);
  expect(reason, findsOneWidget);
  expect(
    tester.getTopLeft(quantity).dx,
    lessThan(tester.getTopLeft(destination).dx),
  );
  expect(
    tester.getTopLeft(destination).dx,
    lessThan(tester.getTopLeft(reason).dx),
  );
}

void registerDailyReportDestinationLayoutTests() {
  testWidgets('去向布局：新建日报仅送仓无需下方卡片，保存仍带原数量和来源', (tester) async {
    final capture = Platform.environment['UTEN_CAPTURE_DAILY_CARDS'] == '1';
    final captureKey = capture ? GlobalKey() : null;
    if (capture) await loadAuditScreenshotFonts(tester);
    Map<String, dynamic>? saved;
    final grid = await _pumpAllocationPage(
      tester,
      candidatesOverride: _warehouseLayoutCandidates,
      attachmentUpload: true,
      captureKey: captureKey,
      theme: capture ? auditScreenshotTheme(buildLightTheme()) : null,
      onCreate: (body) => saved = body,
    );
    final product = grid.rows.single;
    expect(find.text('新建生产日报'), findsOneWidget);
    expect(showsWarehouseOnlyDestination(product), isTrue);
    _expectDestinationLayoutHeaderOrder(tester);
    final destination = _destinationLayoutGrid(
      tester,
    ).columns.singleWhere((column) => column.key == 'destination');
    expect(destination.textOf!(product), '送入仓库');
    expect(find.byType(ProductionDailyProductDetailsCard), findsNothing);
    final attachmentSection = tester.getRect(
      find.byType(PendingAttachmentSection),
    );
    final addFile = tester.getRect(
      find.byKey(const ValueKey('pending-attachment-add')),
    );
    expect(addFile.right, closeTo(attachmentSection.right, 0.1));
    expect(
      addFile.bottom,
      lessThan(tester.getTopLeft(_destinationLayoutHeader('完工申报量 *')).dy),
    );
    if (capture) {
      await saveAuditScreenshot(
        tester,
        captureKey!,
        'daily-output-create-warehouse-inline',
      );
    }
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    final item = (saved!['items'] as List).single as Map;
    expect(item['qty'], 10);
    expect(item['goodsId'], 'goods-1');
    expect(item['planItemId'], 'plan-item-1');
    expect(item['executionSegmentId'], 'segment-1');
    expect(item['planNo'], 'SJ-001');
    expect(item.containsKey('allocations'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('去向布局：已确认仅送仓在完工量后显示去向，不创建下方卡片', (tester) async {
    Map<String, dynamic>? saved;
    final grid = await _pumpEditDraftPage(
      tester,
      itemsOverride: [_destinationLayoutItem('warehouse')],
      candidatesOverride: _warehouseLayoutCandidates,
      onPutBody: (body) => saved = body,
    );
    final product = grid.rows.single;
    expect(showsWarehouseOnlyDestination(product), isTrue);
    _expectDestinationLayoutHeaderOrder(tester);
    final destination = _destinationLayoutGrid(
      tester,
    ).columns.singleWhere((column) => column.key == 'destination');
    expect(destination.textOf!(product), '送入仓库');
    expect(_destinationLayoutAllocationCard(product), findsNothing);
    expect(find.byType(ProductionDailyProductDetailsCard), findsNothing);
    expect(product.allocationRows.single.allocationQty.text, '10');

    product.qty.text = '7';
    await tester.pumpAndSettle();
    expect(product.allocationRows.single.allocationQty.text, '7');
    product.qty.clear();
    await tester.pumpAndSettle();
    expect(_destinationLayoutAllocationCard(product), findsNothing);
    product.qty.text = '10';
    await tester.pumpAndSettle();
    _expectDestinationLayoutHeaderOrder(tester);
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    final item = (saved!['items'] as List).single as Map;
    expect(item['qty'], 10);
    expect(item['goodsId'], 'layout-goods-warehouse');
    expect(item['planItemId'], 'layout-plan-item-warehouse');
    expect(item['executionSegmentId'], 'layout-segment-warehouse');
    expect(item.containsKey('allocations'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('去向布局：支持车间流转时仅在下方选择，不加主表产出去向列', (tester) async {
    final grid = await _pumpEditDraftPage(tester);
    final product = grid.rows.single;
    expect(showsWarehouseOnlyDestination(product), isFalse);
    expect(
      _destinationLayoutGrid(tester).columns.map((column) => column.key),
      isNot(contains('destination')),
    );
    expect(_destinationLayoutHeader('产出去向'), findsNothing);
    expect(_destinationLayoutAllocationCard(product), findsOneWidget);
    expect(find.byTooltip('展开产出去向'), findsOneWidget);
    await tester.tap(find.byTooltip('展开产出去向'));
    await tester.pumpAndSettle();
    expect(
      _visibleAllocationRows(tester).map((row) => row.allocationDemandId),
      ['A', null],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('去向布局：混合货品共享动态列，送仓行仍保留材料和完整提交事实', (tester) async {
    final capture = Platform.environment['UTEN_CAPTURE_DAILY_CARDS'] == '1';
    final captureKey = capture ? GlobalKey() : null;
    if (capture) await loadAuditScreenshotFonts(tester);
    Map<String, dynamic>? saved;
    final grid = await _pumpEditDraftPage(
      tester,
      withMaterials: true,
      attachmentUpload: true,
      itemsOverride: [
        _destinationLayoutItem('warehouse'),
        _destinationLayoutItem('transfer', demandId: 'A', qty: 6),
        _destinationLayoutItem('transfer', qty: 4, lineSuffix: 'remainder'),
      ],
      candidatesBySegment: {
        'layout-segment-warehouse': _warehouseLayoutCandidates,
        'layout-segment-transfer': _transferLayoutCandidates,
      },
      materialsBySegment: {
        'layout-segment-warehouse': [_destinationLayoutMaterial('warehouse')],
        'layout-segment-transfer': [_destinationLayoutMaterial('transfer')],
      },
      surfaceSize: const Size(1920, 1300),
      captureKey: captureKey,
      theme: capture ? auditScreenshotTheme(buildLightTheme()) : null,
      onPutBody: (body) => saved = body,
    );
    expect(grid.rows, hasLength(2));
    final warehouse = grid.rows.first;
    final transfer = grid.rows.last;
    warehouse.goods = const GoodsOption(
      id: 'layout-goods-warehouse',
      code: 'V50001',
      name: 'V5一开按钮',
    );
    transfer.goods = const GoodsOption(
      id: 'layout-goods-transfer',
      code: 'V50041',
      name: 'V5开关面板',
    );
    await tester.pumpAndSettle();
    _expectDestinationLayoutHeaderOrder(tester);
    final destination = _destinationLayoutGrid(
      tester,
    ).columns.singleWhere((column) => column.key == 'destination');
    expect(destination.textOf!(warehouse), '送入仓库');
    expect(destination.textOf!(transfer), '下方分配');
    expect(_destinationLayoutAllocationCard(warehouse), findsNothing);
    expect(_destinationLayoutAllocationCard(transfer), findsOneWidget);
    expect(_destinationLayoutMaterialCard(warehouse), findsOneWidget);
    expect(_destinationLayoutMaterialCard(transfer), findsOneWidget);
    final materials = _materialRows(tester);
    expect(materials, hasLength(2));
    materials.first.materialUsed.text = '8.125';
    materials.last.materialUsed.text = '9.25';
    await tester.pumpAndSettle();
    if (capture) {
      await saveAuditScreenshot(
        tester,
        captureKey!,
        'daily-output-mixed-inline',
      );
    }

    // A fixed receiver remains owned by the product even when its quantity is
    // temporarily zero and no allocation row is visible in the collapsed card.
    final fixed = transfer.allocationRows.firstWhere(
      (row) => row.allocationDemandId == 'A',
    );
    for (final qty in ['2', '', '10']) {
      transfer.qty.text = qty;
      warehouse.qty.text = qty;
      await tester.pumpAndSettle();
      expect(transfer.allocationRows, contains(same(fixed)));
      expect(fixed.allocationRequested, 6);
      expect(showsWarehouseOnlyDestination(transfer), isFalse);
      expect(_destinationLayoutAllocationCard(transfer), findsOneWidget);
      expect(_destinationLayoutAllocationCard(warehouse), findsNothing);
      expect(_materialRows(tester).first.materialUsed.text, '8.125');
      expect(_materialRows(tester).last.materialUsed.text, '9.25');
    }
    expect(fixed.allocationQty.text, '6');
    expect(transfer.allocationRows.last.allocationQty.text, '4');
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    final submitted = (saved!['items'] as List).cast<Map<String, dynamic>>();
    expect(submitted.map((item) => item['qty']), [10, 10]);
    expect(submitted.map((item) => item['executionSegmentId']), [
      'layout-segment-warehouse',
      'layout-segment-transfer',
    ]);
    expect(submitted.first.containsKey('allocations'), isFalse);
    expect(submitted.last['allocations'], [
      {'directTransferDemandId': 'A', 'qty': 6.0},
      {'directTransferDemandId': null, 'qty': 4.0},
    ]);
    expect(saved!['materialLines'], [
      {'demandId': 'layout-material-warehouse', 'qtyBase': 8.125},
      {'demandId': 'layout-material-transfer', 'qtyBase': 9.25},
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final failed in [false, true]) {
    testWidgets('去向布局：候选${failed ? '读取失败' : '已失效'}仍保留旧直送明细，不静默送仓', (
      tester,
    ) async {
      final grid = await _pumpEditDraftPage(
        tester,
        candidatesOverride: _warehouseLayoutCandidates,
        candidatesResponseOverride: failed
            ? (request) => DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
              )
            : null,
      );
      final product = grid.rows.single;
      expect(product.directTransferLoadFailed, failed);
      expect(showsWarehouseOnlyDestination(product), isFalse);
      expect(
        _destinationLayoutGrid(tester).columns.map((column) => column.key),
        isNot(contains('destination')),
      );
      expect(_destinationLayoutAllocationCard(product), findsOneWidget);
      final fixed = product.allocationRows.firstWhere(
        (row) => row.allocationDemandId == 'A',
      );
      expect(fixed.allocationQty.text, '6');
      await tester.tap(find.byTooltip('展开产出去向'));
      await tester.pumpAndSettle();
      expect(_visibleAllocationRows(tester), contains(same(fixed)));
      product.qty.clear();
      await tester.pumpAndSettle();
      expect(product.allocationRows, contains(same(fixed)));
      expect(showsWarehouseOnlyDestination(product), isFalse);
      expect(_destinationLayoutAllocationCard(product), findsOneWidget);
      product.qty.text = '10';
      await tester.pumpAndSettle();
      expect(fixed.allocationDemandId, 'A');
      expect(fixed.allocationQty.text, '6');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('去向布局：同一表格恢复不同来源后动态列仍紧跟完工量', (tester) async {
    await _pumpEditDraftPage(
      tester,
      candidatesBySegment: {
        'segment-1': _transferLayoutCandidates,
        'layout-segment-warehouse': _warehouseLayoutCandidates,
      },
    );
    final state =
        tester.state(find.byType(ProductionDailyReportEditPage))
            as FormDraftMixin<ProductionDailyReportEditPage>;
    final transferDraft = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(state.captureFormDraft())) as Map,
    );
    final warehouseRow =
        Map<String, dynamic>.from((transferDraft['rows'] as List).single as Map)
          ..['planId'] = 'layout-plan-warehouse'
          ..['planItemId'] = 'layout-plan-item-warehouse'
          ..['executionSegmentId'] = 'layout-segment-warehouse'
          ..['allocations'] = <dynamic>[];
    final warehouseDraft = {
      ...transferDraft,
      'rows': [warehouseRow],
    };
    expect(_destinationLayoutHeader('产出去向'), findsNothing);
    for (var cycle = 0; cycle < 2; cycle++) {
      final restoreWarehouse = state.restoreFormDraft(warehouseDraft);
      await tester.pumpAndSettle();
      await restoreWarehouse;
      await tester.pumpAndSettle();
      _expectDestinationLayoutHeaderOrder(tester);
      expect(
        _destinationLayoutAllocationCard(_productRows(tester).single),
        findsNothing,
      );
      final restoreTransfer = state.restoreFormDraft(transferDraft);
      await tester.pumpAndSettle();
      await restoreTransfer;
      await tester.pumpAndSettle();
      expect(_destinationLayoutHeader('产出去向'), findsNothing);
      expect(
        _destinationLayoutAllocationCard(_productRows(tester).single),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });
}
