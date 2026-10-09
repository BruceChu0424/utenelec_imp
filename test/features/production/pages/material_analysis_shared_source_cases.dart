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

  // 2026-10-09 用户口径「合并下单的显示要合并，跟下达车间的一样」：真库快照
  // （3 产品 ×1000、13 种材料全部经同料合并批次下单）切到按物料汇总视图后——
  // ① 聚合物料行进度与顶层同一词表，显示合并批次的真实单据阶段（采购「等待
  // 采购下单」/委外「等待委外下单」），不再显示「保障 N/N」覆盖率；② 已全部
  // 并入合并批次且无剩余待办的来源路径折叠，不再逐条展开；③ 采购/委外的
  // 真实单据保持逐物料分开（本测试不触碰采购/委外管理页）。
  testWidgets('汇总视图下单后显示合并口径：进度=批次单据阶段且来源折叠', (tester) async {
    final snapshot = _snapshotWithBatchLinks();
    await _pump(
      tester,
      mutate: (_) => snapshot.snapshot,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
    );
    final layoutToggle = find.byKey(
      const ValueKey('material-bom-layout-material'),
    );
    await tester.ensureVisible(layoutToggle);
    await tester.tap(layoutToggle);
    await tester.pumpAndSettle();

    // ① 聚合行进度＝合并批次单据阶段（与顶层/分桶页同一词表）。
    expect(
      find.text('等待采购下单'),
      findsNWidgets(snapshot.buyMergedRowCount),
      reason: '采购聚合行显示批次真实阶段，不再显示「保障 N/N」',
    );
    expect(
      find.text('等待委外下单'),
      findsNWidgets(snapshot.subcontractMergedRowCount),
      reason: '委外聚合行显示批次真实阶段',
    );
    expect(find.textContaining('保障 '), findsNothing);

    // ② 已并入合并批次且无剩余待办的来源路径折叠：该聚合行的展开开关消失
    //（用真实聚合键断言——无路径可展开时 toggle 不渲染）。
    expect(
      find.byKey(snapshot.buyToggleKey),
      findsNothing,
      reason: '已合并下单的来源不再逐条展开（与下达车间的折叠同款）',
    );
  });

  // 2026-10-09 用户口径（分桶页）：下达采购/下达委外页里合并下单的行要合并成
  // 一行（跟下达车间一样），已下达单据号要显示出来（部分同料路径没有
  // allocation 锚点，逐行引用取不到单号）。单据层不动：申请仍逐物料分开。
  testWidgets('下达采购分桶页合并批次成一行并显示单据号', (tester) async {
    final snapshot = _snapshotWithBatchLinks();
    await _pump(
      tester,
      mutate: (_) => snapshot.snapshot,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
    );
    await tester.ensureVisible(
      find.byKey(const Key('material-analysis-entry-buy')),
    );
    await tester.tap(find.byKey(const Key('material-analysis-entry-buy')));
    await tester.pumpAndSettle();

    // 同一货品的多个来源行合并成一行，名称带「N 来源 · 合并下单」标识。
    expect(
      find.textContaining('来源 · 合并下单'),
      findsNWidgets(snapshot.buyMergedRowCount),
    );
    // 合并行显示批次真实单据号（不再因逐行引用缺锚点而空白）。
    for (final documentNo in snapshot.buyDocumentNos) {
      expect(find.text(documentNo), findsOneWidget);
    }
  });

  // 2026-10-09 用户口径（车间分桶页）：共享制造批次每批一行（锚点行代表），
  // 供应方式显示「自制」不再空缺，需要数量并入批次事实（不再显示 0）。
  testWidgets('下达车间分桶页组件按批次合并且供应方式与数量完整', (tester) async {
    final snapshot = _snapshotWithBatchLinks();
    await _pump(
      tester,
      mutate: (_) => snapshot.snapshot,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
    );
    await tester.ensureVisible(
      find.byKey(const Key('material-analysis-entry-workshop')),
    );
    await tester.tap(find.byKey(const Key('material-analysis-entry-workshop')));
    await tester.pumpAndSettle();
    // 切「进行中」页签：共享制造锚点行（每批次一行）在这里。
    final inProgress = find.text('进行中');
    await tester.ensureVisible(inProgress);
    await tester.tap(inProgress);
    await tester.pumpAndSettle();

    // 行类型是页面私有，经动态读公开成员判定锚点行。
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MasterDataTableView<dynamic> &&
            widget.columns.any((column) => column.key == 'requiredQty'),
      ),
    );
    final anchorItems = table.items
        .where(
          // 行类型是页面私有，经动态读公开成员判定锚点行。
          // ignore: avoid_dynamic_calls
          (row) => (row as dynamic).product?.sourceType == 'AGGREGATE_MAKE',
        )
        .toList();
    expect(
      anchorItems.length,
      snapshot.workshopMergedRowCount,
      reason: '每个共享制造批次一行（锚点行代表），组件原行不再重复出现',
    );
    // 锚点行供应方式锁定「自制」（旧口径锚点无根供给行显示「—」）。
    expect(
      find.text('自制'),
      findsNWidgets(snapshot.workshopMergedRowCount),
      reason: '共享制造锚点行的供应方式必须显示自制',
    );
    // 需要数量非 0：锚点数量缺失时回退批次 action 总量。
    final dynamic requiredColumn = table.columns.singleWhere(
      (column) => column.key == 'requiredQty',
    );
    for (final row in anchorItems) {
      // ignore: avoid_dynamic_calls
      final value = requiredColumn.exactValueOf(row) as String?;
      expect(
        value != null && double.parse(value) > 0,
        isTrue,
        reason: '共享制造批次行的需要数量不能显示 0（2026-10-09 用户反馈）',
      );
    }
  });
}

/// 真库快照（13 种材料全部经同料合并批次下单）+ 现行投影形态：
/// 把捕获时的字符串 notifiedTargets 升级为带 actionId 的 downstreamReferences
/// （按货品挂回对应的同料合并批次 action），并给出分桶合并断言用的计数。
/// 死亡状态集与产品代码同款（CANCELLED/WITHDRAWN/REVERSED）。
({
  Map<String, dynamic> snapshot,
  int buyMergedRowCount,
  int subcontractMergedRowCount,
  int workshopMergedRowCount,
  List<String> buyDocumentNos,
  ValueKey<String> buyToggleKey,
})
_snapshotWithBatchLinks() {
  final snapshot =
      jsonDecode(
            File(
              'test/fixtures/material_three_1000_after_all_materials.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final aggregateByGoods = <String, Map<String, dynamic>>{};
  for (final row in _records(snapshot['supplyActions'])) {
    if (row['operationType'] == 'AGGREGATE_SUPPLY' &&
        !const ['CANCELLED', 'WITHDRAWN', 'REVERSED'].contains(row['status'])) {
      aggregateByGoods[row['goodsId'] as String] = row;
    }
  }
  String? buyToggleGoods;
  for (final material in _records(snapshot['flatMaterials'])) {
    final action = aggregateByGoods[material['goodsId']];
    if (action == null) continue;
    if (action['route'] == 'BUY' && buyToggleGoods == null) {
      buyToggleGoods =
          'AGGREGATE|${material['goodsId']}|${material['colorId'] ?? ''}|${material['unitId'] ?? ''}';
    }
    material['notifiedTargets'] = [
      {
        'target': action['route'],
        'actionId': action['actionId'],
        'documentType': action['documentType'],
        'documentId': action['documentId'],
        'documentNo': action['documentNo'],
        'status': 'CREATED',
      },
    ];
  }
  return (
    snapshot: snapshot,
    buyMergedRowCount: aggregateByGoods.values
        .where((action) => action['route'] == 'BUY')
        .length,
    subcontractMergedRowCount: aggregateByGoods.values
        .where((action) => action['route'] == 'SUBCONTRACT')
        .length,
    workshopMergedRowCount: aggregateByGoods.values
        .where((action) => action['route'] == 'MAKE')
        .length,
    buyDocumentNos: [
      for (final action in aggregateByGoods.values)
        if (action['route'] == 'BUY') action['documentNo'] as String,
    ],
    buyToggleKey: ValueKey('material-table-toggle-${buyToggleGoods ?? ''}'),
  );
}
