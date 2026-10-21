part of 'material_analysis_one_table_test.dart';

const _unifiedHandlingPermissions = {
  ..._permissions,
  Perm.productionPlanView,
  Perm.productionMaterialAnalysisGenerate,
  Perm.productionPlanReverse,
};

Future<void> _showUnifiedMaterialLayout(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('material-bom-layout-material')));
  await tester.pumpAndSettle();
}

void materialUnifiedHandlingCases() {
  for (final scenario in [
    (0, Perm.productionPlanDelete, true),
    (0, Perm.productionPlanReverse, false),
    (1, Perm.productionPlanReverse, true),
    (1, Perm.productionPlanDelete, false),
  ]) {
    final (status, lifecyclePermission, canWithdraw) = scenario;
    testWidgets('整计划撤回：审批状态$status准确匹配$lifecyclePermission=$canWithdraw', (
      tester,
    ) async {
      await _pump(
        tester,
        permissions: {
          ..._permissions,
          Perm.productionPlanView,
          Perm.productionMaterialAnalysisGenerate,
          lifecyclePermission,
        },
        mutate: (data) {
          _unifiedHandlingFixture(data);
          _records(
            _records(data['products']).first['planReferences'],
          ).single['status'] = status;
          return data;
        },
      );
      await _showUnifiedMaterialLayout(tester);
      final button = find.byKey(
        const ValueKey('material-top-level-cancel-plan'),
      );
      expect(find.text('整批撤回 SJ-ROOT-001'), findsOneWidget);
      expect(button, findsOneWidget);
      if (!canWithdraw) {
        expect(tester.widget<TextButton>(button).onPressed, isNull);
        return;
      }
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('material-plan-cancel-reason')),
        '撤回本计划',
      );
      await tester.tap(find.text('确认整批撤回'));
      await tester.pumpAndSettle();
      expect(
        requests
            .where((request) => request.path.endsWith('/withdraw'))
            .single
            .path,
        '/production/material-analyses/analysis-1/plans/plan-root/withdraw',
      );
      expect(
        requests.where(
          (request) => request.path.contains('/planning-packages/'),
        ),
        isEmpty,
      );
    });
  }

  for (final serverAllows in [true, false]) {
    testWidgets('整计划撤回：生成权限与服务端允许动作必须同时成立 server=$serverAllows', (
      tester,
    ) async {
      await _pump(
        tester,
        permissions: {
          ..._permissions,
          Perm.productionPlanView,
          Perm.productionPlanReverse,
          if (!serverAllows) Perm.productionMaterialAnalysisGenerate,
        },
        mutate: (data) {
          _unifiedHandlingFixture(data);
          if (!serverAllows) {
            (data['allowedActions'] as List).remove('GENERATE_PLAN');
          }
          return data;
        },
      );
      await _showUnifiedMaterialLayout(tester);
      final button = find.byKey(
        const ValueKey('material-top-level-cancel-plan'),
      );
      expect(button, findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      expect(find.text('整批撤回 SJ-ROOT-001'), findsOneWidget);
    });
  }

  testWidgets('整计划撤回：确认期间换账号不沿用原账号授权', (tester) async {
    final session = _OrderAuthoritySession();
    await _pump(
      tester,
      session: session,
      permissions: _unifiedHandlingPermissions,
      mutate: _unifiedHandlingFixture,
    );
    await _showUnifiedMaterialLayout(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-top-level-cancel-plan')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('material-plan-cancel-reason')),
      '撤回本计划',
    );
    session.switchAccount('second-account');
    await tester.pump();
    await tester.tap(find.text('确认整批撤回'));
    await tester.pumpAndSettle();
    expect(
      requests.where((request) => request.path.endsWith('/withdraw')),
      isEmpty,
    );
    expect(_notices(tester), contains('分析状态或撤回权限已变化'));
  });

  testWidgets('整计划撤回：确认期间反审核权限失效不得写请求', (tester) async {
    final permissions = {..._unifiedHandlingPermissions};
    await _pump(
      tester,
      permissions: permissions,
      mutate: _unifiedHandlingFixture,
    );
    await _showUnifiedMaterialLayout(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-top-level-cancel-plan')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('material-plan-cancel-reason')),
      '撤回本计划',
    );
    permissions.remove(Perm.productionPlanReverse);
    await tester.tap(find.text('确认整批撤回'));
    await tester.pumpAndSettle();
    expect(
      requests.where((request) => request.path.endsWith('/withdraw')),
      isEmpty,
    );
    expect(_notices(tester), contains('分析状态或撤回权限已变化'));
  });

  testWidgets('整计划撤回：原地修改同一权限Set也废止旧确认作用域', (tester) async {
    final permissions = {..._unifiedHandlingPermissions};
    await _pump(
      tester,
      permissions: permissions,
      mutate: _unifiedHandlingFixture,
    );
    await _showUnifiedMaterialLayout(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-top-level-cancel-plan')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('material-plan-cancel-reason')),
      '撤回本计划',
    );
    // Keep all withdrawal permissions. A changed permission set still means the
    // user's confirmation belongs to an older semantic authorization scope.
    expect(permissions.contains(Perm.salesOrderView), isFalse);
    permissions.add(Perm.salesOrderView);
    await tester.tap(find.text('确认整批撤回'));
    await tester.pumpAndSettle();
    expect(
      requests.where((request) => request.path.endsWith('/withdraw')),
      isEmpty,
    );
    expect(_notices(tester), contains('分析状态或撤回权限已变化'));
  });

  testWidgets('整计划撤回：网络段换账号后旧回包不得覆盖新页面', (tester) async {
    final session = _OrderAuthoritySession();
    await _pump(
      tester,
      session: session,
      permissions: _unifiedHandlingPermissions,
      mutate: _unifiedHandlingFixture,
      requestObserver: (request) {
        if (request.path.endsWith('/withdraw')) {
          session.switchAccount('second-account');
        }
      },
      analysisPlanWithdraw: (planId, body, data) {
        final next = _withdrawAnalysisPlanFixture(planId, body, data);
        _records(next['products']).first['goodsName'] = '旧账号计划撤回回包不得显示';
        return next;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-top-level-cancel-plan')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('material-plan-cancel-reason')),
      '撤回本计划',
    );
    await tester.tap(find.text('确认整批撤回'));
    await tester.pumpAndSettle();
    expect(
      requests.where((request) => request.path.endsWith('/withdraw')),
      hasLength(1),
    );
    expect(find.text('旧账号计划撤回回包不得显示'), findsNothing);
  });

  testWidgets('整计划撤回：执行包撤销保留正式计划时明确待重新安排而不恢复已下达量', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        _records(data['products']).first['planExecutionStatus'] =
            'PLANNING_REQUIRED';
        _fixtureMaterial(data, 'root-0')['flowStage'] =
            'MAKE_PLANNING_REQUIRED';
        return data;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    final row = find.byKey(const ValueKey('material-bom-product-product-0'));
    expect(
      find.descendant(of: row, matching: find.textContaining('计划保留 · 待重新安排')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('车间已收到')),
      findsNothing,
    );
    expect(find.text('整批撤回 SJ-ROOT-001'), findsOneWidget);
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const Key('material-analysis-material-table')),
    );
    final top = table.items.firstWhere(
      // The row type is private to the production page; read its public model.
      // ignore: avoid_dynamic_calls
      (dynamic item) => item.product?.analysisLineId == 'product-0',
    );
    final product =
        // ignore: avoid_dynamic_calls
        (top as dynamic).product as ProductionMaterialAnalysisProduct;
    expect(product.issuedPlanQty, 1000);
    expect(product.remainingQty, 0);
  });

  testWidgets('整计划撤回：同版本回包补上计划列表和审批状态后立即开放真实撤回', (tester) async {
    var detailReads = 0;
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        _records(data['products']).first.remove('planReferences');
        return data;
      },
      detailResponse: (data, count) {
        detailReads = count;
        if (count == 1) return data;
        final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        _records(next['products']).first['planReferences'] = [
          {'planId': 'plan-root', 'planNo': 'SJ-ROOT-001', 'status': 1},
        ];
        // The snapshot's version, fingerprint, quantities and latest plan stay
        // unchanged; the richer live projection still has to reach the page.
        expect(next['version'], 3);
        expect(next['fingerprint'], 'a' * 64);
        expect(_records(next['products']).first['issuedPlanQty'], 1000);
        expect(_records(next['products']).first['latestPlanId'], 'plan-root');
        return next;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    final cancel = find.byKey(const ValueKey('material-top-level-cancel-plan'));
    expect(cancel, findsOneWidget);
    expect(
      tester.widget<TextButton>(cancel).onPressed,
      isNull,
      reason: '旧响应缺审批状态时保留相同入口但不能猜撤回权限',
    );
    expect(find.text('整批撤回 SJ-ROOT-001'), findsOneWidget);
    await tester.pump(const Duration(seconds: 45));
    await tester.pumpAndSettle();
    expect(detailReads, greaterThanOrEqualTo(2));
    expect(cancel, findsOneWidget, reason: '同版本新计划列表与状态也必须刷新办理能力');
    expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
    expect(find.text('整批撤回 SJ-ROOT-001'), findsOneWidget);
  });

  testWidgets('统一办理：顶层、普通子件、共享制造都只有整批撤回加真实计划号入口', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: _unifiedHandlingFixture,
    );
    await _showUnifiedMaterialLayout(tester);
    for (final entry in [
      (
        'SJ-ROOT-001',
        'material-top-level-view-plan',
        'material-top-level-cancel-plan',
      ),
      (
        'SJ-COMPONENT-001',
        'material-aggregate-view-plan',
        'material-aggregate-cancel-plan',
      ),
      (
        'SJ-SHARED-001',
        'material-aggregate-view-plan-make-batch-1',
        'material-aggregate-cancel-make-batch-1',
      ),
    ]) {
      final (planNo, viewKey, cancelKey) = entry;
      final view = find.byKey(ValueKey(viewKey));
      final cancel = find.byKey(ValueKey(cancelKey));
      expect(view, findsNothing);
      expect(cancel, findsOneWidget);
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
      expect(
        find.text('整批撤回 $planNo'),
        findsOneWidget,
        reason: '办理文字及计划号只显示一次',
      );
      expect(find.text(planNo), findsNothing);
      expect(
        find.descendant(of: cancel, matching: find.byIcon(Icons.undo_rounded)),
        findsNothing,
        reason: '自制办理不再额外提供撤回图标',
      );
      expect(find.byTooltip('查看计划 $planNo'), findsNothing);
      final tooltip = find.ancestor(
        of: cancel,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip && widget.message?.contains(planNo) == true,
        ),
      );
      expect(tooltip, findsOneWidget);
      expect(
        tester.widget<Tooltip>(tooltip).message,
        allOf(startsWith('整批撤回 $planNo。'), contains('来源'), endsWith('阻止撤回。')),
      );
    }
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const Key('material-analysis-material-table')),
    );
    final dynamic handle = table.columns.singleWhere(
      (column) => column.key == 'handle',
    );
    for (final planNo in ['SJ-ROOT-001', 'SJ-COMPONENT-001', 'SJ-SHARED-001']) {
      expect(
        // The callback takes the page's private row type, so call at this boundary.
        // ignore: avoid_dynamic_calls
        table.items.where((row) => handle.value(row) == planNo),
        hasLength(1),
        reason: '排序与导出取值也必须使用真实计划号而不是已下单或内部制造编号',
      );
    }
    expect(find.textContaining('共享制造'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一办理：共享批次按精确锚点分别列出真实计划并去重', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) => _unifiedHandlingFixture(data, twoBatches: true),
    );
    await _showUnifiedMaterialLayout(tester);
    final row = find.byKey(
      const ValueKey('material-aggregate-split-make|本色|unit-1'),
    );
    for (var i = 1; i <= 2; i++) {
      final planNo = 'SJ-SHARED-00$i';
      expect(
        find.descendant(of: row, matching: find.text('整批撤回 $planNo')),
        findsOneWidget,
        reason: '三个来源引用同一批次不能重复列出其计划',
      );
      final view = find.byKey(
        ValueKey('material-aggregate-view-plan-make-batch-$i'),
      );
      final cancel = find.byKey(
        ValueKey('material-aggregate-cancel-make-batch-$i'),
      );
      expect(view, findsNothing);
      expect(cancel, findsOneWidget);
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.undo_rounded)),
        findsNothing,
      );
    }
    expect(find.textContaining('SJ-SAME-GOODS-UNRELATED'), findsNothing);
    expect(find.textContaining('共享制造'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一办理：顶层完整计划列表保留各批计划并按planId去重', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        final product = _records(data['products']).first;
        product['planReferences'] = [
          {'planId': 'plan-root-old', 'planNo': 'SJ-ROOT-OLD', 'status': 1},
          {'planId': 'plan-root', 'planNo': 'SJ-ROOT-001', 'status': 1},
          {'planId': 'plan-root-old', 'planNo': 'SJ-ROOT-OLD', 'status': 1},
        ];
        return data;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    final row = find.byKey(const ValueKey('material-bom-product-product-0'));
    expect(
      find.descendant(of: row, matching: find.text('整批撤回 SJ-ROOT-OLD')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('整批撤回 SJ-ROOT-001')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.byType(TextButton)),
      findsNWidgets(2),
      reason: '重复planId及latestPlan引用不能制造重复撤回入口',
    );
    final olderCancel = find.byKey(
      const ValueKey('material-top-level-cancel-plan'),
    );
    await tester.tap(olderCancel);
    await tester.pumpAndSettle();
    expect(
      requests.where(
        (request) => request.path.endsWith('/mrp/planning-package-result'),
      ),
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('material-plan-cancel-reason')),
      '撤回旧批次',
    );
    await tester.tap(find.text('确认整批撤回'));
    await tester.pumpAndSettle();
    expect(
      requests
          .where((request) => request.path.endsWith('/withdraw'))
          .single
          .path,
      '/production/material-analyses/analysis-1/plans/plan-root-old/withdraw',
    );
    final withdrawal = requests.singleWhere(
      (request) => request.path.endsWith('/withdraw'),
    );
    expect(withdrawal.body?['version'], 3);
    expect(withdrawal.body?['fingerprint'], 'a' * 64);
    expect(withdrawal.body?['idempotencyKey'], isNotEmpty);
    expect(
      find.text('整批撤回 SJ-ROOT-001'),
      findsOneWidget,
      reason: '只撤选中的旧计划，其它有效计划仍保留',
    );
    expect(find.textContaining('SJ-ROOT-OLD'), findsNothing);
  });

  testWidgets('统一办理：单个共享批次多张计划分别列出且保持唯一操作键', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        final anchor = _records(data['products']).singleWhere(
          (product) => product['analysisLineId'] == 'make-anchor-1',
        );
        anchor['planReferences'] = [
          {'planId': 'plan-shared-1', 'planNo': 'SJ-SHARED-001', 'status': 1},
          {
            'planId': 'plan-shared-1-extra',
            'planNo': 'SJ-SHARED-001-EXTRA',
            'status': 1,
          },
        ];
        return data;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    for (final entry in [
      ('SJ-SHARED-001', ''),
      ('SJ-SHARED-001-EXTRA', '-plan-shared-1-extra'),
    ]) {
      final (planNo, suffix) = entry;
      final view = find.byKey(
        ValueKey('material-aggregate-view-plan-make-batch-1$suffix'),
      );
      final cancel = find.byKey(
        ValueKey('material-aggregate-cancel-make-batch-1$suffix'),
      );
      expect(view, findsNothing);
      expect(cancel, findsOneWidget);
      expect(find.text('整批撤回 $planNo'), findsOneWidget);
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
      expect(
        find.descendant(of: cancel, matching: find.byIcon(Icons.undo_rounded)),
        findsNothing,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一办理：无查看权限仍使用整批撤回加真实单号文字入口', (tester) async {
    await _pump(
      tester,
      permissions: {..._unifiedHandlingPermissions}
        ..remove(Perm.productionPlanView),
      mutate: _unifiedHandlingFixture,
    );
    await _showUnifiedMaterialLayout(tester);
    for (final entry in [
      ('SJ-ROOT-001', 'material-top-level-cancel-plan'),
      ('SJ-COMPONENT-001', 'material-aggregate-cancel-plan'),
      ('SJ-SHARED-001', 'material-aggregate-cancel-make-batch-1'),
    ]) {
      final (planNo, cancelKey) = entry;
      final cancel = find.byKey(ValueKey(cancelKey));
      expect(find.text('整批撤回 $planNo'), findsOneWidget);
      expect(find.text(planNo), findsNothing);
      expect(find.byTooltip('查看计划 $planNo'), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.ancestor(
                of: find.text('整批撤回 $planNo'),
                matching: find.byType(TextButton),
              ),
            )
            .key,
        ValueKey(cancelKey),
        reason: '真实单号只属于撤回文字入口，不受查看权限影响',
      );
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一办理：无撤回权限保留相同文字入口但禁用撤回', (tester) async {
    await _pump(
      tester,
      permissions: {..._permissions, Perm.productionPlanView},
      mutate: _unifiedHandlingFixture,
    );
    await _showUnifiedMaterialLayout(tester);
    for (final entry in [
      (
        'SJ-ROOT-001',
        'material-top-level-cancel-plan',
        'material-top-level-view-plan',
      ),
      (
        'SJ-COMPONENT-001',
        'material-aggregate-cancel-plan',
        'material-aggregate-view-plan',
      ),
      (
        'SJ-SHARED-001',
        'material-aggregate-cancel-make-batch-1',
        'material-aggregate-view-plan-make-batch-1',
      ),
    ]) {
      final (planNo, cancelKey, viewKey) = entry;
      final cancel = find.byKey(ValueKey(cancelKey));
      expect(find.text('整批撤回 $planNo'), findsOneWidget);
      expect(cancel, findsOneWidget);
      expect(tester.widget<TextButton>(cancel).onPressed, isNull);
      expect(find.byKey(ValueKey(viewKey)), findsNothing);
      expect(find.byTooltip('查看计划 $planNo'), findsNothing);
    }
    expect(
      requests.where(
        (request) =>
            request.path.endsWith('/cancel') ||
            request.path.endsWith('/withdraw'),
      ),
      isEmpty,
    );
  });

  testWidgets('统一办理：共享锚点缺失时待核对，不能借用同货品另一批计划', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        (data['products'] as List).removeWhere(
          (product) => (product as Map)['analysisLineId'] == 'make-anchor-1',
        );
        return data;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    final row = find.byKey(
      const ValueKey('material-aggregate-split-make|本色|unit-1'),
    );
    expect(
      find.descendant(of: row, matching: find.text('整批撤回 · 生产任务待核对')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('material-aggregate-view-plan-make-batch-1')),
      findsNothing,
    );
    final cancel = find.byKey(
      const ValueKey('material-aggregate-cancel-make-batch-1'),
    );
    expect(cancel, findsOneWidget);
    expect(tester.widget<TextButton>(cancel).onPressed, isNull);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.undo_rounded)),
      findsNothing,
    );
    expect(find.textContaining('SJ-SHARED-001'), findsNothing);
    expect(find.textContaining('SJ-SAME-GOODS-UNRELATED'), findsNothing);
    expect(find.textContaining('共享制造'), findsNothing);
    expect(
      requests.where(
        (request) =>
            request.path.endsWith('/cancel') ||
            request.path.endsWith('/withdraw'),
      ),
      isEmpty,
      reason: '缺少正式计划锚点不能猜测生命周期授权，不写撤回请求',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一办理：共享锚点无计划时待核对，不能用内部批次号当生产计划', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        final anchor = _records(data['products']).singleWhere(
          (product) => product['analysisLineId'] == 'make-anchor-1',
        );
        anchor.remove('planReferences');
        anchor.remove('latestPlanId');
        anchor.remove('latestPlanNo');
        return data;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    final row = find.byKey(
      const ValueKey('material-aggregate-split-make|本色|unit-1'),
    );
    expect(
      find.descendant(of: row, matching: find.text('整批撤回 · 生产任务待核对')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('material-aggregate-view-plan-make-batch-1')),
      findsNothing,
    );
    final cancel = find.byKey(
      const ValueKey('material-aggregate-cancel-make-batch-1'),
    );
    expect(cancel, findsOneWidget);
    expect(tester.widget<TextButton>(cancel).onPressed, isNull);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.undo_rounded)),
      findsNothing,
    );
    expect(find.textContaining('SJ-SHARED-001'), findsNothing);
    expect(find.textContaining('SJ-SAME-GOODS-UNRELATED'), findsNothing);
    expect(find.textContaining('共享制造'), findsNothing);
    expect(
      requests.where(
        (request) =>
            request.path.endsWith('/cancel') ||
            request.path.endsWith('/withdraw'),
      ),
      isEmpty,
      reason: '共享锚点缺少真实计划时不能猜测生命周期授权，不写撤回请求',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一办理：共享真实计划撤回仍取消原批次并完整列出三来源及公共份', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: _unifiedHandlingFixture,
      aggregateCancel: (body, data) {
        final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
        next['version'] = (data['version'] as int) + 1;
        next['fingerprint'] = 'c' * 64;
        for (final material in _records(next['flatMaterials'])) {
          for (final target in _records(material['downstreamReferences'])) {
            if (target['actionId'] == 'make-batch-1') {
              target['status'] = 'CANCELLED';
            }
          }
        }
        _records(next['supplyActions']).single['status'] = 'CANCELLED';
        return next;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    requests.clear();
    await tester.tap(
      find.byKey(const ValueKey('material-aggregate-cancel-make-batch-1')),
    );
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.textContaining('总量 3100')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('公共备货 100')),
      findsOneWidget,
    );
    for (var i = 0; i < 3; i++) {
      expect(
        find.descendant(of: dialog, matching: find.textContaining('测试产品$i')),
        findsOneWidget,
      );
    }
    expect(
      requests.where((request) => request.path.endsWith('/cancel')),
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('material-aggregate-cancel-reason')),
      '重复安排',
    );
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('确认整批撤回')),
    );
    await tester.pumpAndSettle();
    final cancel = requests
        .where((request) => request.path.endsWith('/cancel'))
        .single;
    expect(
      cancel.path,
      '/production/material-analyses/analysis-1/aggregate-orders/actions/make-batch-1/cancel',
    );
    expect(cancel.body?['reason'], '重复安排');
    expect(cancel.body?['idempotencyKey'], isNotEmpty);
    expect(
      requests.where((request) => request.path.contains('/planning-packages/')),
      isEmpty,
    );
    expect(
      find.byKey(const ValueKey('material-aggregate-cancel-make-batch-1')),
      findsNothing,
    );
  });
  testWidgets('统一办理：旧普通子件的精确自制任务也完整撤计划，保留需求重新安排', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        _fixtureMaterial(data, 'ordinary-component')['downstreamReferences'] = [
          {
            'actionId': 'legacy-ordinary-action',
            'route': 'MAKE',
            'status': 'CREATED',
            'documentType': 'PREPLAN_MAKE_TASK',
            'documentId': 'ordinary-anchor',
            'documentNo': '旧普通制造任务',
            'allocatedQty': 1000,
          },
        ];
        (data['supplyActions'] as List).add(<String, dynamic>{
          'actionId': 'legacy-ordinary-action',
          'route': 'MAKE',
          'status': 'CREATED',
          'operationType': 'SUPPLY',
          'requestedQty': 1000,
          'publicSurplusQty': 0,
          'documentType': 'PREPLAN_MAKE_TASK',
          'documentId': 'ordinary-anchor',
          'documentNo': '旧普通制造任务',
        });
        return data;
      },
    );
    await _showUnifiedMaterialLayout(tester);
    final button = find.byKey(
      const ValueKey('material-aggregate-cancel-legacy-ordinary-action'),
    );
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    requests.clear();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-plan-cancel-reason')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('material-aggregate-cancel-reason')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const Key('material-plan-cancel-reason')),
      '重新安排普通子件',
    );
    await tester.tap(find.text('确认整批撤回'));
    await tester.pumpAndSettle();
    expect(
      requests
          .where((request) => request.path.endsWith('/withdraw'))
          .single
          .path,
      '/production/material-analyses/analysis-1/plans/plan-component/withdraw',
    );
    expect(
      requests.where((request) => request.path.endsWith('/cancel')),
      isEmpty,
    );
    expect(find.textContaining('SJ-COMPONENT-001'), findsNothing);
    expect(
      find.byKey(
        const ValueKey(
          'material-aggregate-order-g-ordinary-component|本色|unit-1',
        ),
      ),
      findsNothing,
      reason: '正式计划撤回后不再残留锁定的已下达量',
    );
    final quantity = find.byKey(
      const ValueKey('material-aggregate-qty-g-ordinary-component|本色|unit-1'),
    );
    expect(quantity, findsOneWidget, reason: '普通自制任务保留需求，重新开放下单输入');
    expect(_qtyText(tester, quantity), '1000');
  });
}

/// Each batch is bound by its exact documentId to a manufacturing anchor. The
/// extra anchor deliberately shares its goodsId, catching accidental lookups by
/// goods instead of the source graph and document identity.
Map<String, dynamic> _unifiedHandlingFixture(
  Map<String, dynamic> data, {
  bool twoBatches = false,
}) {
  _threeSharedMakeSources(data);
  (data['allowedActions'] as List).add('CANCEL_ACTION');
  final top = _records(data['products']).first;
  top.addAll({
    'issuedPlanQty': 1000,
    'remainingQty': 0,
    'canSchedule': false,
    'canIssueSurplus': true,
    'latestPlanId': 'plan-root',
    'latestPlanNo': 'SJ-ROOT-001',
    'planReferences': [
      {'planId': 'plan-root', 'planNo': 'SJ-ROOT-001', 'status': 1},
    ],
  });
  _fixturePlanAssignment(top);
  final batchCount = twoBatches ? 2 : 1;
  for (var i = 0; i < 3; i++) {
    final source = _fixtureMaterial(data, 'shared-$i');
    source.addAll({
      'additionalSupplyRecommendedQty': 0,
      'netShortageQty': 0,
      'downstreamReferences': [
        for (var batch = 1; batch <= batchCount; batch++)
          {
            'actionId': 'make-batch-$batch',
            'route': 'MAKE',
            'status': 'CREATED',
            'documentType': 'PREPLAN_MAKE_TASK',
            'documentId': 'make-anchor-$batch',
            'documentNo': '共享制造 内部批次$batch',
            'allocatedQty': twoBatches ? (batch == 1 ? 400 : 600) : 1000,
          },
      ],
      'aggregatePreparation': {
        'requiredQty': 1000,
        'orderedQty': 1000,
        'allocatedOrderedQty': 1000,
        'totalOrderedQty': twoBatches ? 3150 : 3100,
        'orderedQtyExact': true,
        'planningUncoveredQty': 0,
        'netShortageQty': 0,
        'targetMaterialLineIds': <String>[],
        'actionable': true,
      },
    });
  }
  data['supplyActions'] = <Map<String, dynamic>>[
    for (var batch = 1; batch <= batchCount; batch++)
      {
        'actionId': 'make-batch-$batch',
        'route': 'MAKE',
        'status': 'CREATED',
        'goodsId': 'split-make',
        'operationType': 'AGGREGATE_SUPPLY',
        'requestedQty': twoBatches ? (batch == 1 ? 1200 : 1800) : 3000,
        'publicSurplusQty': batch == 1 ? 100 : 50,
        'documentType': 'PREPLAN_MAKE_TASK',
        'documentId': 'make-anchor-$batch',
        'documentNo': '共享制造 内部批次$batch',
      },
  ];
  (data['products'] as List).addAll(<Map<String, dynamic>>[
    for (var batch = 1; batch <= batchCount; batch++)
      {
        'analysisLineId': 'make-anchor-$batch',
        'sourceType': 'AGGREGATE_MAKE',
        'goodsId': 'split-make',
        'goodsName': '功能件',
        'requestedQty': twoBatches ? (batch == 1 ? 1300 : 1850) : 3100,
        'issuedPlanQty': twoBatches ? (batch == 1 ? 1300 : 1850) : 3100,
        'remainingQty': 0,
        'canSchedule': false,
        'canIssueSurplus': true,
        'unitName': '个',
        'latestPlanId': 'plan-shared-$batch',
        'latestPlanNo': 'SJ-SHARED-00$batch',
        'planReferences': [
          {
            'planId': 'plan-shared-$batch',
            'planNo': 'SJ-SHARED-00$batch',
            'status': 1,
          },
          {
            'planId': 'plan-shared-$batch',
            'planNo': 'SJ-SHARED-00$batch',
            'status': 1,
          },
        ],
      },
    {
      'analysisLineId': 'unrelated-same-goods-anchor',
      'sourceType': 'AGGREGATE_MAKE',
      'goodsId': 'split-make',
      'goodsName': '功能件',
      'requestedQty': 999,
      'issuedPlanQty': 999,
      'remainingQty': 0,
      'latestPlanId': 'plan-unrelated',
      'latestPlanNo': 'SJ-SAME-GOODS-UNRELATED',
    },
  ]);
  final component = _material(
    line: 'ordinary-component',
    name: '普通自制子件',
    confirmed: 'MAKE',
    netShortageQty: 0,
    stockQty: 0,
    planAnchorAnalysisLineId: 'ordinary-anchor',
  )..['analysisLineId'] = 'product-0';
  (data['flatMaterials'] as List).add(component);
  final ordinary = <String, dynamic>{
    'analysisLineId': 'ordinary-anchor',
    'sourceType': 'MAKE_COMPONENT',
    'parentAnalysisLineId': 'product-0',
    'goodsId': component['goodsId'],
    'goodsName': '普通自制子件',
    'requestedQty': 1000,
    'issuedPlanQty': 1000,
    'remainingQty': 0,
    'canSchedule': false,
    'canIssueSurplus': true,
    'unitName': '个',
    'latestPlanId': 'plan-component',
    'latestPlanNo': 'SJ-COMPONENT-001',
    'planReferences': [
      {'planId': 'plan-component', 'planNo': 'SJ-COMPONENT-001', 'status': 1},
    ],
  };
  _fixturePlanAssignment(ordinary);
  (data['products'] as List).add(ordinary);
  return data;
}

Map<String, dynamic> _withdrawAnalysisPlanFixture(
  String planId,
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) {
  final next = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  next['version'] = (data['version'] as int) + 1;
  next['fingerprint'] = 'd' * 64;
  for (final product in _records(next['products'])) {
    final references = _records(product['planReferences']);
    final linked =
        product['latestPlanId'] == planId ||
        references.any((reference) => reference['planId'] == planId);
    if (!linked) continue;
    references.removeWhere((reference) => reference['planId'] == planId);
    product['planReferences'] = references;
    if (product['latestPlanId'] == planId) {
      product['latestPlanId'] = references.isEmpty
          ? null
          : references.last['planId'];
      product['latestPlanNo'] = references.isEmpty
          ? null
          : references.last['planNo'];
    }
    if (references.isNotEmpty) continue;
    final requiredQty = _num(product['requestedQty']);
    product['issuedPlanQty'] = 0;
    product['remainingQty'] = requiredQty;
    product['canSchedule'] = true;
    product['maxSchedulableQty'] = requiredQty;
    product.remove('planExecutionStatus');
    product.remove('planExecutionPlannedQty');
    product.remove('planExecutionProgressRatio');
    for (final material in _records(next['flatMaterials'])) {
      if (material['materialLineId'] != product['rootMaterialLineId'] &&
          material['planAnchorAnalysisLineId'] != product['analysisLineId']) {
        continue;
      }
      material['additionalSupplyRecommendedQty'] = requiredQty;
      material['netShortageQty'] = requiredQty;
      material['shortageQty'] = requiredQty;
      material['demandSupplyGapQty'] = requiredQty;
      material['allocatedAvailableQty'] = 0;
      material['availableQty'] = 0;
      material.remove('flowStage');
    }
  }
  return next;
}
