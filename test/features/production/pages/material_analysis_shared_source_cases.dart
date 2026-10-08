part of 'material_analysis_one_table_test.dart';

void materialSharedSourceCases() {
  testWidgets('真库13种材料全部下单后只有3个顶层待下达且采购委外无伪待单', (tester) async {
    final snapshot =
        jsonDecode(
              File(
                'test/fixtures/material_three_1000_after_all_materials.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final products = _records(snapshot['products']);
    final roots = products
        .where((row) => row['sourceType'] == 'SALES_ORDER_ITEM')
        .toList();
    expect(roots, hasLength(3));
    for (final root in roots) {
      expect(_num(root['requestedQty']), 1000);
      expect(_num(root['issuedPlanQty']), 0);
    }
    final actions = _records(snapshot['supplyActions'])
        .where(
          (row) =>
              row['operationType'] == 'AGGREGATE_SUPPLY' &&
              row['status'] != 'CANCELLED',
        )
        .toList();
    expect(actions, hasLength(13));
    await _pump(
      tester,
      mutate: (_) => snapshot,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
    );
    final cards = tester
        .widgetList<MaterialPreparationRouteCard>(
          find.byType(MaterialPreparationRouteCard),
        )
        .toList();
    final workshop = cards.singleWhere((card) => card.routeId == 'workshop');
    expect(
      workshop.pendingCount,
      3,
      reason: '已有共享供给完全覆盖的UK canonical只是结构上下文，不能成为第四个零量待下达任务',
    );
    for (final route in ['buy', 'subcontract']) {
      final card = cards.singleWhere((card) => card.routeId == route);
      expect(card.pendingCount, 0, reason: '$route真实单据已存在，不能因原来源转交再次要求下单');
      expect(
        card.inProgressCount,
        greaterThan(0),
        reason: '尚未收货的真实在途业务仍保留黄色进行中计数',
      );
    }
    await tester.ensureVisible(
      find.byKey(const Key('material-analysis-entry-workshop')),
    );
    await tester.tap(find.byKey(const Key('material-analysis-entry-workshop')));
    await tester.pumpAndSettle();
    for (final root in roots) {
      expect(find.text(root['goodsName'] as String), findsOneWidget);
    }
    expect(find.text('UK开关滑杆'), findsNothing);
    expect(find.text('当前状态不可创建'), findsNothing);
    expect(
      requests.where(
        (request) =>
            request.method == 'POST' &&
            (request.path.endsWith('/aggregate-orders/submit') ||
                request.path.endsWith('/issue-plans')),
      ),
      isEmpty,
    );
  });
}
