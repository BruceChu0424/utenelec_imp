part of 'production_daily_report_exact_segment_test.dart';

void registerDailyReportProductCardTests() {
  testWidgets(
    '250-product report reveals offscreen collapsed material error without losing quantities',
    (tester) async {
      final items = [
        for (var i = 0; i < 250; i++)
          <String, dynamic>{
            'id': 'window-line-$i',
            'goodsId': 'goods-1',
            'planId': 'plan-1',
            'planItemId': 'window-plan-item-$i',
            'planNo': 'SJ-001',
            // Keep the real page's material-source request limit in force:
            // many product batches can belong to the same execution source.
            'executionSegmentId': i == 230
                ? 'window-segment-230'
                : 'window-segment-shared',
            'unitId': 'unit-1',
            'unitRate': 1,
            'qty': 1,
            'outputBatchId': 'window-batch-$i',
            'outputBatchQty': 1,
          },
      ];
      Map<String, dynamic>? saved;
      final grid = await _pumpEditDraftPage(
        tester,
        withMaterials: true,
        itemsOverride: items,
        materialsBySegment: {
          'window-segment-230': [
            {
              'planId': 'plan-1',
              'demandId': 'window-material',
              'goodsId': 'raw-1',
              'goodsName': '离屏用料',
              'executionSegmentId': 'window-segment-230',
              'issuedQty': 10,
              'unclearedQty': 10,
              'availableToSettleQty': 10,
              'requiredQty': 10,
              'requiredForProductQty': 10,
              'requirementMode': 'LINEAR',
            },
          ],
        },
        candidatesOverride: {'candidates': <dynamic>[], 'receiverLimit': 30},
        onPutBody: (body) => saved = body,
      );
      expect(grid.rows, hasLength(250));
      final product = grid.rows[230];
      final showProduct = grid.revealRow(product, alignment: .5);
      await tester.pumpAndSettle();
      expect(await showProduct, isTrue);
      final card = find.byKey(
        ValueKey('daily-product-details-${product.localRowId}'),
      );
      final material = tester
          .widget<ProductionDailyProductDetailsCard>(card)
          .materialRows
          .single;
      material.materialUsed.text = '';
      await tester.pumpAndSettle();
      final collapse = find.descendant(
        of: card,
        matching: find.byTooltip('收起子件用料'),
      );
      expect(collapse.hitTestable(), findsOneWidget);
      await tester.tap(collapse);
      await tester.pumpAndSettle();
      final showFirst = grid.revealRow(grid.rows.first);
      await tester.pumpAndSettle();
      expect(await showFirst, isTrue);
      expect(card, findsNothing);

      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('项用料需要先改正'), findsOneWidget);
      expect(card.hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<ProductionDailyProductDetailsCard>(card)
            .materialsExpanded,
        isTrue,
      );
      expect(material.materialUsed.text, isEmpty);
      expect(grid.rows, hasLength(250));
      expect(grid.rows.every((row) => row.qty.text == '1'), isTrue);
      expect(grid.mountedRowCount, lessThan(100));
      expect(saved, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('多个货品：竖排卡片对齐货品列、独立折叠且提交完整数量', (tester) async {
    final capture = Platform.environment['UTEN_CAPTURE_DAILY_CARDS'] == '1';
    final captureKey = capture ? GlobalKey() : null;
    if (capture) await loadAuditScreenshotFonts(tester);
    Future<void> tapVisible(Finder target) async {
      if (target.hitTestable().evaluate().isEmpty) {
        await Scrollable.ensureVisible(tester.element(target), alignment: 0.35);
        await tester.pumpAndSettle();
      }
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    const products = [
      ('V5—一开单控功能件', 'V5G001', 3000, 3, 4),
      ('V5—一开双控功能件', 'V5G002', 2000, 2, 2),
      ('V5—二开单控功能件', 'V5G003', 1500, 2, 1),
    ];
    const materialNames = [
      'V5一开压板',
      'V5一开单控10A后座（带UTEN）',
      'V5开关打子',
      'V5开关滑杆组件',
    ];
    final items = <Map<String, dynamic>>[];
    final materials = <String, List<Map<String, dynamic>>>{};
    final candidates = <String, Map<String, dynamic>>{};
    for (var p = 0; p < products.length; p++) {
      final (name, code, total, destinationCount, materialCount) = products[p];
      final segment = 'multi-segment-$p';
      items.addAll([
        for (var d = 0; d < destinationCount; d++)
          {
            'id': 'multi-line-$p-$d',
            'goodsId': 'multi-goods-$p',
            'goodsName': name,
            'goodsCode': code,
            'planId': 'multi-plan-$p',
            'planItemId': 'multi-plan-item-$p',
            'planNo': 'SJ20261011000${p + 1}',
            'executionSegmentId': segment,
            'executionSegmentCode': 'HP03575$p',
            'unitId': 'unit-1',
            'colorId': 'color-1',
            'unitRate': 1,
            'qty': total ~/ destinationCount,
            'outputBatchId': 'multi-batch-$p',
            'outputBatchQty': total,
            'destination': 'WORKSHOP',
            'directTransferDemandId': 'multi-target-$p-$d',
          },
      ]);
      materials[segment] = [
        for (var m = 0; m < materialCount; m++)
          {
            'planId': 'multi-plan-$p',
            'demandId': 'multi-material-$p-$m',
            'goodsId': 'multi-raw-$p-$m',
            'goodsName': materialNames[m],
            'goodsCode': 'V5M0$p$m',
            'colorName': '深灰色',
            'unitName': '个',
            'executionSegmentId': segment,
            'issuedQty': total,
            'unclearedQty': total,
            'availableToSettleQty': total,
            'requiredQty': total,
            'requiredForProductQty': total,
            'requirementMode': 'LINEAR',
          },
      ];
      candidates[segment] = {
        'candidates': [
          for (var d = 0; d < destinationCount; d++)
            {
              'demandId': 'multi-target-$p-$d',
              'executionSegmentId': 'multi-receiver-$p-$d',
              'executionSegmentCode': 'HP${35800 + p * 10 + d}',
              'planNo': 'ZX00000${326 + p * 10 + d}',
              'receivingGoodsName': '$name · 面板及底座总成（${d + 1}）',
              'receivingGoodsCode': '$code-R${d + 1}',
              'receivingColorName': d.isEven ? '深灰色' : '乳白色',
              'remainingQty': total ~/ destinationCount,
              'unitName': '个',
            },
        ],
        'receiverLimit': 30,
      };
    }
    Map<String, dynamic>? saved;
    final grid = await _pumpEditDraftPage(
      tester,
      withMaterials: true,
      itemsOverride: items,
      materialsBySegment: materials,
      candidatesBySegment: candidates,
      surfaceSize: const Size(1920, 1600),
      captureKey: captureKey,
      theme: capture ? auditScreenshotTheme(buildLightTheme()) : null,
      onPutBody: (body) => saved = body,
    );
    expect(grid.rows, hasLength(3));
    for (var p = 0; p < products.length; p++) {
      grid.rows[p].goods = GoodsOption(
        id: 'multi-goods-$p',
        code: products[p].$2,
        name: products[p].$1,
      );
    }
    await tester.pumpAndSettle();
    final firstMaterials = _materialRows(
      tester,
    ).where((row) => identical(row.materialParent, grid.rows.first));
    expect(_materialRows(tester), hasLength(7));
    firstMaterials.first.materialUsed.text = '2950.1234';
    for (final product in grid.rows.take(2)) {
      final details = find.byKey(
        ValueKey('daily-product-details-${product.localRowId}'),
      );
      final expand = find.descendant(
        of: details,
        matching: find.byTooltip('展开产出去向'),
      );
      await tapVisible(expand);
      final allocations = find.byKey(
        ValueKey('daily-product-allocations-card-${product.localRowId}'),
      );
      final usage = find.byKey(
        ValueKey('daily-product-materials-card-${product.localRowId}'),
      );
      expect(
        tester.getTopLeft(allocations).dx,
        tester.getTopLeft(find.byType(UtenEditableGrid<DailyGridRow>)).dx +
            UtenEditableGrid.selectionColumnWidth,
      );
      expect(tester.getTopLeft(usage).dx, tester.getTopLeft(allocations).dx);
      expect(
        tester.getTopLeft(usage).dy,
        greaterThan(tester.getBottomLeft(allocations).dy),
      );
    }
    final lastDetails = find.byKey(
      ValueKey('daily-product-details-${grid.rows.last.localRowId}'),
    );
    final lastMaterialsToggle = find.descendant(
      of: lastDetails,
      matching: find.byTooltip('收起子件用料'),
    );
    await tapVisible(lastMaterialsToggle);
    expect(_visibleAllocationRows(tester), hasLength(5));
    expect(_visibleMaterialRows(tester), hasLength(6));
    if (capture) {
      await tester.ensureVisible(find.byType(UtenEditableGrid<DailyGridRow>));
      await tester.pumpAndSettle();
      await saveAuditScreenshot(
        tester,
        captureKey!,
        'daily-product-cards-multiple',
      );
    }
    final firstDetails = find.byKey(
      ValueKey('daily-product-details-${grid.rows.first.localRowId}'),
    );
    final firstAllocationToggle = find.descendant(
      of: firstDetails,
      matching: find.byTooltip('收起产出去向'),
    );
    await tapVisible(firstAllocationToggle);
    expect(_visibleAllocationRows(tester), hasLength(2));
    expect(firstMaterials.first.materialUsed.text, '2950.1234');
    // Folding only affects rendering; saving must retain every product,
    // destination, and hidden material with its original source identity.
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    final submitted = (saved!['items'] as List).cast<Map<String, dynamic>>();
    expect(submitted.map((item) => item['qty']), [3000, 2000, 1500]);
    expect(submitted.map((item) => item['executionSegmentId']), [
      'multi-segment-0',
      'multi-segment-1',
      'multi-segment-2',
    ]);
    for (var p = 0; p < products.length; p++) {
      final allocations = (submitted[p]['allocations'] as List)
          .cast<Map<String, dynamic>>();
      expect(allocations, hasLength(products[p].$4));
      expect(
        allocations.fold<num>(
          0,
          (sum, allocation) => sum + (allocation['qty'] as num),
        ),
        products[p].$3,
      );
    }
    final usages = (saved!['materialLines'] as List)
        .cast<Map<String, dynamic>>();
    expect(usages, hasLength(7));
    expect(
      usages.singleWhere(
        (usage) => usage['demandId'] == 'multi-material-0-0',
      )['qtyBase'],
      2950.1234,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('产品详情卡片：11条去向和4项用料占独立整宽，不改变主表列序与提交事实', (tester) async {
    final capture = Platform.environment['UTEN_CAPTURE_DAILY_CARDS'] == '1';
    final captureKey = capture ? GlobalKey() : null;
    if (capture) await loadAuditScreenshotFonts(tester);
    final items = [
      for (var i = 0; i < 11; i++)
        <String, dynamic>{
          'id': 'card-line-$i',
          'goodsId': 'goods-1',
          'goodsName': 'V5—一开单控功能件',
          'goodsCode': 'V5G001',
          'planId': 'plan-1',
          'planItemId': 'plan-item-1',
          'planNo': 'SJ202610110001',
          'executionSegmentId': 'segment-1',
          'executionSegmentCode': 'HP035750',
          'unitId': 'unit-1',
          'colorId': 'color-1',
          'unitRate': 1,
          'qty': 1000,
          'outputBatchId': 'card-batch',
          'outputBatchQty': 11000,
          'destination': 'WORKSHOP',
          'directTransferDemandId': 'card-target-$i',
        },
    ];
    const names = ['V5一开压板', 'V5一开单控10A后座（带UTEN）', 'V5开关打子', 'V5开关滑杆组件'];
    const codes = ['V50010', 'V50014', 'V50026', 'V5ZJ001'];
    final materials = [
      for (var i = 0; i < 4; i++)
        <String, dynamic>{
          'planId': 'plan-1',
          'demandId': 'card-material-$i',
          'goodsId': 'raw-$i',
          'goodsName': names[i],
          'goodsCode': codes[i],
          'colorName': '深灰色',
          'unitName': '个',
          'executionSegmentId': 'segment-1',
          'issuedQty': 11000,
          'unclearedQty': 11000,
          'availableToSettleQty': 11000,
          'requiredQty': 11000,
          'requiredForProductQty': 11000,
          'requirementMode': 'LINEAR',
        },
    ];
    final candidates = {
      'candidates': [
        for (var i = 0; i < 11; i++)
          {
            'demandId': 'card-target-$i',
            'executionSegmentId': 'card-receiver-$i',
            'executionSegmentCode': 'HP${35754 + i}',
            'planNo': 'ZX00000${326 + i}',
            'receivingGoodsName':
                '测试产品${i == 0 ? '' : '（$i）'} · V5系列一开单控开关功能件及面板底座总成',
            'receivingGoodsCode': 'V5-TEST-${i + 1}',
            'receivingColorName': i.isEven ? '深灰色' : '乳白色',
            'remainingQty': 1000,
            'unitName': '个',
          },
      ],
      'receiverLimit': 30,
    };
    final grid = await _pumpEditDraftPage(
      tester,
      withMaterials: true,
      itemsOverride: items,
      materialsOverride: materials,
      candidatesOverride: candidates,
      surfaceSize: const Size(1920, 1520),
      captureKey: captureKey,
      theme: capture ? auditScreenshotTheme(buildLightTheme()) : null,
    );
    final product = grid.rows.single;
    product.goods = const GoodsOption(
      id: 'goods-1',
      code: 'V5G001',
      name: 'V5—一开单控功能件',
    );
    await tester.pumpAndSettle();
    expect(product.qty.text, '11000');
    final gridWidget = tester.widget<UtenEditableGrid<DailyGridRow>>(
      find.byType(UtenEditableGrid<DailyGridRow>),
    );
    expect(gridWidget.columns.map((column) => column.key), [
      'goods',
      'goodsCode',
      'color',
      'qty',
      'overLimitReason',
      'defectQty',
      'planNo',
      'remark',
    ]);
    expect(_materialRows(tester), hasLength(4));
    expect(product.allocationRows, hasLength(11));
    final material = _materialRows(tester).first;
    material.materialUsed.text = '10850.1234';
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('展开产出去向'));
    await tester.tap(find.byTooltip('展开产出去向'));
    await tester.pumpAndSettle();
    expect(_visibleAllocationRows(tester), hasLength(11));
    final card = find.byKey(
      ValueKey('daily-product-details-${product.localRowId}'),
    );
    expect(tester.getSize(card).width, closeTo(1920, 120));
    if (capture) {
      await tester.ensureVisible(find.byType(UtenEditableGrid<DailyGridRow>));
      await tester.pumpAndSettle();
      await saveAuditScreenshot(
        tester,
        captureKey!,
        'daily-product-cards-expanded',
      );
    }
    await tester.ensureVisible(find.byTooltip('收起产出去向'));
    await tester.tap(find.byTooltip('收起产出去向'));
    await tester.pumpAndSettle();
    expect(product.allocationRows, hasLength(11));
    expect(
      outputAllocationBody(
        product,
      )!.fold<num>(0, (sum, line) => sum + (line['qty'] as num)),
      11000,
    );
    expect(material.materialUsed.text, '10850.1234');
    expect(grid.rows, hasLength(1));
    if (capture) {
      await saveAuditScreenshot(
        tester,
        captureKey!,
        'daily-product-cards-collapsed',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
