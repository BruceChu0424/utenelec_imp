part of 'material_analysis_one_table_test.dart';

Future<void> _showProductWithdrawalLayout(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
  await tester.pumpAndSettle();
}

Finder _productWithdrawal(String line, String target) =>
    find.byKey(ValueKey('material-product-$line-cancel-$target'));

void materialProductWithdrawalCases() {
  testWidgets('按产品撤回：已下单只保留可语义点击的准确撤回入口', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(
        tester,
        permissions: _unifiedHandlingPermissions,
        mutate: _unifiedHandlingFixture,
      );
      await _showProductWithdrawalLayout(tester);
      final withdrawal = tester.getSemantics(
        _productWithdrawal('root-0', 'plan'),
      );
      final withdrawalData = withdrawal.getSemanticsData();
      expect(_transferButton('root-0'), findsNothing);
      expect(withdrawalData.flagsCollection.isEnabled, ui.Tristate.isTrue);
      expect(withdrawalData.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(withdrawalData.label, contains('SJ-ROOT-001'));
      expect(withdrawalData.label, isNot(contains('调拨')));
      for (
        var parent = withdrawal.parent;
        parent != null;
        parent = parent.parent
      ) {
        expect(
          parent.getSemanticsData().flagsCollection.isEnabled,
          isNot(ui.Tristate.isFalse),
          reason: '可用撤回不能处于禁用动作的语义祖先中：${parent.getSemanticsData().label}',
        );
      }
      withdrawal.owner!.performAction(withdrawal.id, ui.SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-plan-cancel-reason')),
        findsOneWidget,
      );
      expect(
        requests.where((request) => request.path.endsWith('/withdraw')),
        isEmpty,
      );
    } finally {
      semantics.dispose();
    }
  });
  for (final entry in [
    ('root-0', 'plan', 'plan-root'),
    ('ordinary-component', 'plan', 'plan-component'),
  ]) {
    testWidgets('按产品撤回：${entry.$1}只撤准确计划且下单后不显示调拨', (tester) async {
      await _pump(
        tester,
        permissions: _unifiedHandlingPermissions,
        mutate: _unifiedHandlingFixture,
      );
      await _showProductWithdrawalLayout(tester);
      final button = _productWithdrawal(entry.$1, entry.$2);
      expect(button, findsOneWidget);
      expect(_transferButton(entry.$1), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        requests.where((request) => request.path.endsWith('/withdraw')),
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('material-plan-cancel-reason')),
        '核对本来源撤回',
      );
      await tester.tap(find.text('确认整批撤回'));
      await tester.pumpAndSettle();
      final request = requests.singleWhere(
        (request) => request.path.endsWith('/withdraw'),
      );
      expect(
        request.path,
        '/production/material-analyses/analysis-1/plans/${entry.$3}/withdraw',
      );
      expect(request.body?['version'], 3);
      expect(request.body?['fingerprint'], 'a' * 64);
      expect(request.body?['idempotencyKey'], isNotEmpty);
      expect(
        requests.where(
          (request) => request.path.contains('/planning-packages/'),
        ),
        isEmpty,
      );
      expect(
        requests.where((request) => request.path.contains('plan-unrelated')),
        isEmpty,
      );
    });
  }

  testWidgets('按产品撤回：单条共享来源核对整批全部来源并调用aggregate命令', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: _unifiedHandlingFixture,
    );
    await _showProductWithdrawalLayout(tester);
    await tester.tap(_productWithdrawal('shared-0', 'make-batch-1'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    for (var index = 0; index < 3; index++) {
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('测试产品$index'),
        ),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: dialog, matching: find.textContaining('总量 3100')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('公共备货 100')),
      findsOneWidget,
    );
    expect(find.textContaining('SJ-SAME-GOODS-UNRELATED'), findsNothing);
    expect(
      requests.where((request) => request.path.endsWith('/cancel')),
      isEmpty,
    );
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('确认整批撤回')),
    );
    await tester.pumpAndSettle();
    final request = requests.singleWhere(
      (request) => request.path.endsWith('/cancel'),
    );
    expect(
      request.path,
      '/production/material-analyses/analysis-1/aggregate-orders/actions/make-batch-1/cancel',
    );
    expect(request.body?['version'], 3);
    expect(request.body?['fingerprint'], 'a' * 64);
    expect(request.body?['idempotencyKey'], isNotEmpty);
    expect(
      requests.where((request) => request.path.endsWith('/withdraw')),
      isEmpty,
    );
  });

  testWidgets('按产品撤回：缺少反审权限时入口置灰，已下单仍不显示调拨', (tester) async {
    await _pump(
      tester,
      permissions: {..._unifiedHandlingPermissions}
        ..remove(Perm.productionPlanReverse),
      mutate: _unifiedHandlingFixture,
    );
    await _showProductWithdrawalLayout(tester);
    final button = _productWithdrawal('root-0', 'plan');
    expect(button, findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(_transferButton('root-0'), findsNothing);
  });

  testWidgets('按产品撤回：关闭整批确认不发送任何撤回请求', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: _unifiedHandlingFixture,
    );
    await _showProductWithdrawalLayout(tester);
    await tester.tap(_productWithdrawal('shared-0', 'make-batch-1'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    expect(
      requests.where(
        (request) =>
            request.path.endsWith('/cancel') ||
            request.path.endsWith('/withdraw'),
      ),
      isEmpty,
    );
  });

  testWidgets('按产品撤回：确认期间权限失效不沿用旧授权', (tester) async {
    final permissions = {..._unifiedHandlingPermissions};
    await _pump(
      tester,
      permissions: permissions,
      mutate: _unifiedHandlingFixture,
    );
    await _showProductWithdrawalLayout(tester);
    await tester.tap(_productWithdrawal('root-0', 'plan'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('material-plan-cancel-reason')),
      '核对本来源撤回',
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

  testWidgets('按产品撤回：来源链不完整时不能从树行执行共享撤回', (tester) async {
    await _pump(
      tester,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        (_fixtureMaterial(data, 'shared-0')['aggregatePreparation']
            as Map)['targetMaterialLineIds'] = [
          'missing-canonical',
        ];
        return data;
      },
    );
    await _showProductWithdrawalLayout(tester);
    final button = _productWithdrawal('shared-0', 'make-batch-1');
    expect(button, findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(
      requests.where((request) => request.path.endsWith('/cancel')),
      isEmpty,
    );
  });
}
