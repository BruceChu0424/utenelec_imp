part of 'material_analysis_one_table_test.dart';

Finder _handlingDensityRow(String line) =>
    find.byKey(ValueKey('material-table-row-$line')).first;

Future<void> _expandHandlingDensitySources(
  WidgetTester tester,
  String aggregateKey,
) async {
  await tester.tap(
    find.byKey(ValueKey('material-table-toggle-AGGREGATE|$aggregateKey')),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _handlingDensityMinimal(Map<String, dynamic> data) {
  (data['flatMaterials'] as List).removeWhere(
    (row) => !{'m-root', 'm-2'}.contains((row as Map)['materialLineId']),
  );
  return data;
}

void materialHandlingDensityCases() {
  testWidgets('办理紧凑：真实已下单在产品、汇总和来源路径均不再显示调拨', (tester) async {
    await _pump(
      tester,
      platform: TargetPlatform.windows,
      permissions: _unifiedHandlingPermissions,
      mutate: (data) {
        _unifiedHandlingFixture(data);
        // Fully issued sources are intentionally absent from the aggregate
        // expansion. Keep a real open remainder while preserving its order.
        final material = _fixtureMaterial(data, 'shared-0');
        material['netShortageQty'] = 1;
        (material['aggregatePreparation'] as Map)
          ..['planningUncoveredQty'] = 1
          ..['netShortageQty'] = 1;
        return data;
      },
    );
    await _showProductWithdrawalLayout(tester);
    for (final line in ['root-0', 'ordinary-component', 'shared-0']) {
      expect(_transferButton(line), findsNothing, reason: '$line 已有真实订单');
    }
    expect(_productWithdrawal('root-0', 'plan'), findsOneWidget);
    expect(_productWithdrawal('ordinary-component', 'plan'), findsOneWidget);
    expect(_productWithdrawal('shared-0', 'make-batch-1'), findsOneWidget);

    await _showMaterialSummary(tester);
    expect(_transferButton('root-0'), findsNothing);
    expect(
      find.byKey(
        const ValueKey('material-aggregate-transfer-split-make|本色|unit-1'),
      ),
      findsNothing,
    );
    await _expandHandlingDensitySources(tester, 'split-make|本色|unit-1');
    expect(_handlingDensityRow('shared-0'), findsOneWidget);
    expect(_transferButton('shared-0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    'FUTURE_TRANSFER',
    'SHARED_FUTURE_CLAIM',
    'ADOPTED_ONLY',
    'CANCELLED_ORDER',
  ]) {
    testWidgets('办理紧凑：$scenario 不能冒充真实下单，两个视图保留调拨', (tester) async {
      final semantics = scenario == 'SHARED_FUTURE_CLAIM'
          ? tester.ensureSemantics()
          : null;
      try {
        await _pump(
          tester,
          platform: TargetPlatform.windows,
          permissions: {
            ..._permissions,
            if (scenario == 'SHARED_FUTURE_CLAIM')
              Perm.productionMaterialAnalysisClaimSharedFuture,
          },
          mutate: (data) {
            _threeSharedBuySources(data);
            if (scenario == 'SHARED_FUTURE_CLAIM') {
              (data['allowedActions'] as List).add('CANCEL_ACTION');
            }
            final material = _fixtureMaterial(data, 'shared-0');
            material['downstreamReferences'] = <Object>[];
            if (scenario == 'ADOPTED_ONLY') {
              material['preparationAdoptedQty'] = 2;
            } else {
              material['downstreamReferences'] = [
                {
                  'actionId': 'density-source-action',
                  'route': 'BUY',
                  'status': scenario == 'CANCELLED_ORDER'
                      ? 'CANCELLED'
                      : 'REQUESTED',
                  'documentNo': 'PR-DENSITY-SOURCE',
                  'allocatedQty': 100,
                },
              ];
              data['supplyActions'] = [
                {
                  'actionId': 'density-source-action',
                  'route': 'BUY',
                  'operationType': scenario == 'CANCELLED_ORDER'
                      ? 'SUPPLY'
                      : scenario,
                  'status': scenario == 'CANCELLED_ORDER'
                      ? 'CANCELLED'
                      : 'REQUESTED',
                  'documentNo': 'PR-DENSITY-SOURCE',
                  'requestedQty': 100,
                },
              ];
            }
            return data;
          },
        );
        expect(_transferButton('shared-0'), findsOneWidget);
        await _showMaterialSummary(tester);
        expect(
          find.byKey(
            const ValueKey('material-aggregate-transfer-g-m-2|本色|unit-1'),
          ),
          findsOneWidget,
          reason: '仅采用、认领、调拨或已取消来源均未产生本行有效订单',
        );
        if (scenario == 'SHARED_FUTURE_CLAIM') {
          final withdrawal = tester.getSemantics(
            find.byKey(
              const ValueKey('material-aggregate-cancel-density-source-action'),
            ),
          );
          final transfer = tester.getSemantics(
            find.byKey(
              const ValueKey('material-aggregate-transfer-g-m-2|本色|unit-1'),
            ),
          );
          expect(withdrawal.id, isNot(transfer.id));
          final data = withdrawal.getSemanticsData();
          expect(data.flagsCollection.isEnabled, ui.Tristate.isTrue);
          expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
          expect(data.label, contains('撤回认领'));
          expect(data.label, isNot(contains('调拨')));
          expect(
            transfer.getSemanticsData().flagsCollection.isEnabled,
            ui.Tristate.isFalse,
          );
          for (
            var parent = withdrawal.parent;
            parent != null;
            parent = parent.parent
          ) {
            expect(
              parent.getSemanticsData().flagsCollection.isEnabled,
              isNot(ui.Tristate.isFalse),
              reason: '置灰调拨不能污染可用认领撤回的语义祖先',
            );
          }
        }
        await _expandHandlingDensitySources(tester, 'g-m-2|本色|unit-1');
        expect(_transferButton('shared-0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics?.dispose();
      }
    });
  }

  testWidgets('办理紧凑：无历史引用但权威已下单0.0001仍隐藏产品和汇总路径调拨', (tester) async {
    await _pump(
      tester,
      platform: TargetPlatform.windows,
      mutate: (data) {
        _threeSharedBuySources(data);
        final material = _fixtureMaterial(data, 'shared-0');
        material['downstreamReferences'] = <Object>[];
        material['aggregatePreparation'] = {
          'requiredQty': 1000,
          'orderedQty': 0.0001,
          'allocatedOrderedQty': 0.0001,
          'totalOrderedQty': 0.0001,
          'orderedQtyExact': true,
          'targetMaterialLineIds': <String>[],
          'actionable': true,
        };
        return data;
      },
    );
    expect(_transferButton('shared-0'), findsNothing);
    expect(
      find.byKey(const ValueKey('material-product-shared-0-issued')),
      findsOneWidget,
    );
    await _showMaterialSummary(tester);
    expect(
      find.byKey(const ValueKey('material-aggregate-transfer-g-m-2|本色|unit-1')),
      findsNothing,
    );
    await _expandHandlingDensitySources(tester, 'g-m-2|本色|unit-1');
    expect(_transferButton('shared-0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final entry in [
    ('root-0', 'plan-root'),
    ('ordinary-component', 'plan-component'),
  ]) {
    testWidgets('办理紧凑：${entry.$1}准确撤回当前计划后恢复未下单调拨', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.windows,
        permissions: _unifiedHandlingPermissions,
        mutate: _unifiedHandlingFixture,
      );
      await _showProductWithdrawalLayout(tester);
      expect(_transferButton(entry.$1), findsNothing);
      await tester.tap(_productWithdrawal(entry.$1, 'plan'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('material-plan-cancel-reason')),
        '撤回后重新安排物料',
      );
      await tester.tap(find.text('确认整批撤回'));
      await tester.pumpAndSettle();
      final request = requests.singleWhere(
        (request) => request.path.endsWith('/withdraw'),
      );
      expect(
        request.path,
        '/production/material-analyses/analysis-1/plans/${entry.$2}/withdraw',
      );
      expect(request.body?['version'], 3);
      expect(request.body?['fingerprint'], 'a' * 64);
      expect(_transferButton(entry.$1), findsOneWidget);
      expect(_productWithdrawal(entry.$1, 'plan'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('办理紧凑：$platform 只收紧单元格留白并保留控件命中高度', (tester) async {
      await _pump(
        tester,
        platform: platform,
        size: const Size(1800, 1000),
        mutate: _handlingDensityMinimal,
      );
      final row = _handlingDensityRow('m-2');
      final transfer = _transferButton('m-2');
      final input = _orderQty('m-2');
      final touch = platform == TargetPlatform.android;
      final controlHeight = touch ? 48.0 : 32.0;
      expect(
        tester.getSize(transfer).height,
        greaterThanOrEqualTo(controlHeight),
      );
      expect(tester.getSize(input).height, greaterThanOrEqualTo(controlHeight));
      expect(
        tester.getSize(row).height,
        inInclusiveRange(controlHeight + 8, controlHeight + 9),
        reason: '32/48px控件加上下各4px及校验细框，不保留旧48px桌面展开占位',
      );
      final bounds = tester.getRect(row);
      for (final control in [transfer, input]) {
        final rect = tester.getRect(control);
        expect(rect.top, greaterThanOrEqualTo(bounds.top));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('办理紧凑：大字校验和真实多行分单说明自然撑高而不裁切', (tester) async {
    await _pump(
      tester,
      platform: TargetPlatform.windows,
      size: const Size(1800, 1000),
      textScaler: const TextScaler.linear(2),
      mutate: _handlingDensityMinimal,
    );
    final row = _handlingDensityRow('m-2');
    final field = _orderQty('m-2');
    await tester.enterText(field, '0');
    await _settleRebuild(tester);
    expect(_framedRed(tester, field), isTrue);
    expect(tester.getSize(row).height, greaterThan(48));
    expect(
      tester.getRect(field).bottom,
      lessThanOrEqualTo(tester.getRect(row).bottom),
    );
    expect(tester.takeException(), isNull);

    await _pump(
      tester,
      platform: TargetPlatform.windows,
      size: const Size(1800, 1000),
      fontFactor: 1.6,
      permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
      mutate: (data) {
        _threeSharedMakeSources(data);
        _fixtureMaterial(data, 'shared-0')
          ..['owningWorkshopId'] = 'ws-2'
          ..['owningWorkshopName'] = '装配二车间';
        return data;
      },
      defaultWorkshops: _workshopDefaultsFor([
        'parent-0',
        'parent-1',
        'parent-2',
        'split-make',
      ]),
      departmentTree: _twoWorkshopTree,
    );
    await _showMaterialSummary(tester);
    final aggregate = find.byKey(
      const ValueKey('material-aggregate-split-make|本色|unit-1'),
    );
    final note = find.byKey(
      const ValueKey('material-aggregate-split-split-make|本色|unit-1'),
    );
    expect(note, findsOneWidget);
    expect(_splitDetail(tester, note), contains('装配二车间'));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: note, matching: find.byType(RichText)).first,
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.getSize(aggregate).height, greaterThan(48));
    final bounds = tester.getRect(aggregate);
    final noteBounds = tester.getRect(note);
    expect(noteBounds.top, greaterThanOrEqualTo(bounds.top));
    expect(noteBounds.bottom, lessThanOrEqualTo(bounds.bottom));
    expect(tester.takeException(), isNull);
  });
}
