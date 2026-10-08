part of 'material_analysis_one_table_test.dart';

void materialPolicyCases() {
  materialBoundaryCases();
  testWidgets(
    'material policy: malformed exact residual fails closed without parsing NaN',
    (tester) async {
      await _pump(
        tester,
        mutate: (data) {
          _fractionalTapeSources(data);
          _fixtureMaterial(data, 'shared-0')['quantityFactsExact'] = {
            'additionalSupplyRecommendedQty': 'broken',
          };
          return data;
        },
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(
        const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
      );
      await tester.enterText(field, '1.5');
      await tester.pump();
      final frame = find
          .ancestor(of: field, matching: find.byType(RequiredCellFrame))
          .first;
      expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isTrue);
      expect(tester.takeException(), isNull);
      expect(_aggregateSubmits(), isEmpty);
    },
  );
  testWidgets(
    'material policy: fractional BOM 0.5 x 3 accepts exact 1.5 and sends it unchanged',
    (tester) async {
      await _pump(
        tester,
        mutate: _fractionalTapeSources,
        aggregatePreview: _fractionalTapePreview,
        aggregateSubmit: _fractionalTapeSubmit,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(
        const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
      );
      final frame = find
          .ancestor(of: field, matching: find.byType(RequiredCellFrame))
          .first;
      await tester.enterText(field, '1.5');
      await tester.pump();
      expect(
        tester.widget<RequiredCellFrame>(frame).isEmpty(),
        isFalse,
        reason: '单位个与真实0.5 BOM不等于整数订货策略，未配置MOQ/倍数时1.5必须合法',
      );
      await tester.enterText(field, '1.4999');
      await tester.pump();
      expect(
        tester.widget<RequiredCellFrame>(frame).isEmpty(),
        isTrue,
        reason: '汇总完整办理不得吞掉真实0.0001缺口',
      );
      await tester.enterText(field, '1.5');
      await _settlePreview(tester);
      await _submitSelected(tester);
      expect(
        _aggregateSubmits(),
        hasLength(1),
        reason:
            '${_notices(tester)}; calls=${requests.map((request) => request.path).toList()}',
      );
      final group = _records(_aggregateSubmits().single.body!['groups']).single;
      expect(group['qty'], '1.5');
      expect(group['materialLineIds'], ['shared-0', 'shared-1', 'shared-2']);
    },
  );

  for (final configured in [false, true]) {
    testWidgets(
      'material policy: product fractional demand keeps ${configured ? 'explicit MOQ recommendation' : '0.5 without integer-unit rounding'}',
      (tester) async {
        await _pump(
          tester,
          overSupply: true,
          permissions: _overSupplyPermissions,
          mutate: (data) {
            _fractionalTapeSources(data);
            if (configured) {
              for (var i = 0; i < 3; i++) {
                _fixtureMaterial(
                  data,
                  'shared-$i',
                ).addAll({'minOrderQty': 2, 'orderMultipleQty': 0.5});
              }
            }
            return data;
          },
        );
        for (var i = 0; i < 3; i++) {
          final field = _orderQty('shared-$i');
          expect(_qtyText(tester, field), configured ? '2' : '0.5');
          final frame = find
              .ancestor(of: field, matching: find.byType(RequiredCellFrame))
              .first;
          expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isFalse);
        }
        if (configured) {
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Tooltip &&
                  (widget.message ?? '').contains('按起订量与整包装建议下单 2'),
            ),
            findsNWidgets(3),
          );
        }
      },
    );
  }

  testWidgets(
    'material policy: fractional additional order remains additional with no initial-demand floor',
    (tester) async {
      await _pump(
        tester,
        overSupply: true,
        permissions: _overSupplyPermissions,
        mutate: (data) {
          _fractionalTapeSources(data);
          for (var i = 0; i < 3; i++) {
            _fixtureMaterial(data, 'shared-$i').addAll({
              'additionalSupplyRecommendedQty': 0,
              'netShortageQty': 0,
              'aggregatePreparation': {
                'requiredQty': 0.5,
                'orderedQty': 0.5,
                'allocatedOrderedQty': 0.5,
                'totalOrderedQty': 1.5,
                'orderedQtyExact': true,
                'planningUncoveredQty': 0,
                'netShortageQty': 0,
                'targetMaterialLineIds': <String>[],
                'actionable': true,
              },
            });
          }
          return data;
        },
      );
      await tester.enterText(_appendQty('shared-0'), '0.25');
      await tester.pump();
      final productFrame = find
          .ancestor(
            of: _appendQty('shared-0'),
            matching: find.byType(RequiredCellFrame),
          )
          .first;
      expect(tester.widget<RequiredCellFrame>(productFrame).isEmpty(), isFalse);
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(
        const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
      );
      await tester.enterText(field, '0.25');
      await tester.pump();
      final frame = find
          .ancestor(of: field, matching: find.byType(RequiredCellFrame))
          .first;
      expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isFalse);
    },
  );

  testWidgets(
    'material policy: authoritative fractional 3001.5006 lower bound is never rounded',
    (tester) async {
      await _pump(
        tester,
        overSupply: true,
        permissions: _overSupplyPermissions,
        mutate: (data) {
          _threeSharedBuySources(data);
          // 每来源 1000.5002：合计 3001.5006 与任何粗粒度值都差 6 个 10^-4
          // tick，超出「来源数个 tick」的分摊噪声预算——真分数下限必须原样
          // 保留，不得像定点分摊尾巴（83.3334×3）那样按整数呈现与校验。
          for (var i = 0; i < 3; i++) {
            _fixtureMaterial(data, 'shared-$i').addAll({
              'requiredQty': 1000.5002,
              'sourceRequiredQty': 1000.5002,
              'shortageQty': 1000.5002,
              'demandSupplyGapQty': 1000.5002,
              'additionalSupplyRecommendedQty': 1000.5002,
              'netShortageQty': 1000.5002,
            });
          }
          return data;
        },
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(
        const ValueKey('material-aggregate-qty-g-m-2|本色|unit-1'),
      );
      final frame = find
          .ancestor(of: field, matching: find.byType(RequiredCellFrame))
          .first;
      await tester.enterText(field, '3001.5004');
      await tester.pump();
      expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isTrue);
      await tester.enterText(field, '3001.5006');
      await tester.pump();
      expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isFalse);
    },
  );

  for (final issued in [false, true]) {
    testWidgets(
      'material policy: aggregate ratio is ${issued ? 'locked after issued 4000' : 'editable before issue'}',
      (tester) async {
        await _pump(
          tester,
          overSupply: true,
          permissions: {
            ..._overSupplyPermissions,
            Perm.productionMaterialAnalysisGenerate,
          },
          mutate: (data) {
            _threeSharedMakeSources(data);
            data['overproductionDefaults'] = {'split-make': 0.1};
            if (issued) {
              for (var i = 0; i < 3; i++) {
                _fixtureMaterial(data, 'shared-$i').addAll({
                  'additionalSupplyRecommendedQty': 0,
                  'netShortageQty': 0,
                  'aggregatePreparation': {
                    'requiredQty': 1000,
                    'orderedQty': 1000,
                    'allocatedOrderedQty': 1000,
                    'totalOrderedQty': 4000,
                    'orderedQtyExact': true,
                    'planningUncoveredQty': 0,
                    'netShortageQty': 0,
                    'targetMaterialLineIds': <String>[],
                    'actionable': true,
                  },
                });
              }
            }
            return data;
          },
          defaultWorkshops: _workshopDefaultsFor(const ['split-make']),
        );
        await tester.tap(
          find.byKey(const ValueKey('material-bom-layout-material')),
        );
        await tester.pumpAndSettle();
        final editor = find.descendant(
          of: find.byKey(
            const ValueKey('material-aggregate-rate-split-make|本色|unit-1'),
          ),
          matching: find.byType(TextField),
        );
        if (issued) {
          expect(
            editor.evaluate().isEmpty ||
                !tester.widget<TextField>(editor).enabled!,
            isTrue,
            reason: '汇总行与按产品行同样冻结已下达工单的比例，不能在追加界面直接改',
          );
        } else {
          expect(tester.widget<TextField>(editor).enabled, isTrue);
        }
      },
    );
  }
}

void materialBoundaryCases() {
  for (final large in [false, true]) {
    testWidgets(
      'material boundary: product order detects one exact tick short large=$large',
      (tester) async {
        final need = large ? '9999999999999.9999' : '0.5';
        await _pump(
          tester,
          mutate: (data) {
            _fractionalTapeSources(data);
            _fixtureMaterial(data, 'shared-0').addAll({
              'requiredQty': double.parse(need),
              'additionalSupplyRecommendedQty': double.parse(need),
              'netShortageQty': double.parse(need),
              'quantityFactsExact': {
                'requiredQty': need,
                'additionalSupplyRecommendedQty': need,
                'netShortageQty': need,
              },
            });
            return data;
          },
        );
        final field = _orderQty('shared-0');
        final frame = find
            .ancestor(of: field, matching: find.byType(RequiredCellFrame))
            .first;
        await tester.enterText(field, large ? '9999999999999.9998' : '0.4999');
        await tester.pump();
        expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isTrue);
        await tester.enterText(field, need);
        await tester.pump();
        expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isFalse);
      },
    );
  }

  testWidgets(
    'material boundary: product invalid exact residual stays red without crashing',
    (tester) async {
      await _pump(
        tester,
        mutate: (data) {
          _fractionalTapeSources(data);
          _fixtureMaterial(data, 'shared-0')['quantityFactsExact'] = {
            'additionalSupplyRecommendedQty': 'broken',
          };
          return data;
        },
      );
      final field = _orderQty('shared-0');
      await tester.enterText(field, '0.5');
      await tester.pump();
      final frame = find
          .ancestor(of: field, matching: find.byType(RequiredCellFrame))
          .first;
      expect(tester.widget<RequiredCellFrame>(frame).isEmpty(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'material boundary: MAKE partial issue explains the remaining exact tick',
    (tester) async {
      await _pump(
        tester,
        permissions: {..._permissions, Perm.productionMaterialAnalysisGenerate},
        defaultWorkshops: _workshopDefaultsFor(const ['g-m-2']),
        mutate: (data) {
          _fractionalTapeSources(data);
          (data['allowedActions'] as List).add('GENERATE_PLAN');
          _fixtureMaterial(
            data,
            'shared-0',
          ).addAll({'sourceConfirmed': 'MAKE', 'sourceSuggestion': 'MAKE'});
          return data;
        },
      );
      await tester.enterText(_orderQty('shared-0'), '0.4999');
      await _settleRebuild(tester);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip && (widget.message ?? '').contains('少 0.0001'),
        ),
        findsOneWidget,
      );
    },
  );

  for (final root in [false, true]) {
    testWidgets(
      'material boundary: issued 0.0001 locks actual assignment root=$root',
      (tester) async {
        final line = root ? 'm-root' : 'm-7';
        await _pump(
          tester,
          permissions: {
            ..._overSupplyPermissions,
            Perm.productionMaterialAnalysisGenerate,
          },
          overSupply: true,
          defaultWorkshops: _workshopDefaultsFor(['g-$line']),
          mutate: (data) {
            if (!root) _withIssuedMakeRow(data);
            (data['allowedActions'] as List).add('GENERATE_PLAN');
            final product = (data['products'] as List)
                .cast<Map<String, dynamic>>()
                .singleWhere(
                  (row) =>
                      row['analysisLineId'] ==
                      (root ? 'product-1' : 'anchor-7'),
                );
            product.addAll(<String, dynamic>{
              'issuedPlanQty': 0.0001,
              'latestPlanId': null,
              'remainingQty': 0,
              'canSchedule': false,
              'canIssueSurplus': true,
              'quantityFactsExact': {
                'issuedPlanQty': '0.0001',
                'remainingQty': '0',
              },
              'planExecutionWorkshopId': 'issued-workshop',
              'planExecutionWorkshopName': '已下达实际车间',
              'planExecutionResponsibleId': 'issued-worker',
              'planExecutionResponsibleName': '已下达实际负责人',
            });
            return data;
          },
        );
        final workshop = find.byKey(
          ValueKey('material-analysis-workshop-${_groupKey(line)}'),
        );
        final worker = find.byKey(
          ValueKey('material-analysis-worker-${_groupKey(line)}'),
        );
        expect(tester.widget(workshop), isA<Tooltip>());
        expect(
          find.descendant(of: workshop, matching: find.byType(InkWell)),
          findsNothing,
        );
        expect(
          find.descendant(of: workshop, matching: find.text('已下达实际车间')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: worker, matching: find.text('已下达实际负责人')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'material boundary: remaining 0.0001 is private demand not public-only production',
    (tester) async {
      await _pump(
        tester,
        permissions: {
          ..._overSupplyPermissions,
          Perm.productionMaterialAnalysisGenerate,
        },
        overSupply: true,
        defaultWorkshops: _workshopDefaultsFor(const ['g-m-root']),
        mutate: (data) {
          (data['allowedActions'] as List).add('GENERATE_PLAN');
          final product =
              (data['products'] as List).first as Map<String, dynamic>;
          product.addAll({
            'issuedPlanQty': 1,
            'latestPlanId': 'tiny-open-plan',
            'remainingQty': 0.0001,
            'quantityFactsExact': {
              'issuedPlanQty': '1',
              'remainingQty': '0.0001',
            },
            'canSchedule': true,
            'canIssueSurplus': true,
          });
          _fixturePlanAssignment(product);
          _fixtureMaterial(data, 'm-root').addAll({
            'additionalSupplyRecommendedQty': 0.0001,
            'netShortageQty': 0.0001,
            'aggregatePreparation': {
              'requiredQty': 1.0001,
              'orderedQty': 1,
              'allocatedOrderedQty': 1,
              'totalOrderedQty': 1,
              'orderedQtyExact': true,
              'planningUncoveredQty': 0.0001,
              'planningUncoveredQtyExact': '0.0001',
              'netShortageQty': 0.0001,
              'targetMaterialLineIds': <String>[],
              'actionable': true,
            },
          });
          return data;
        },
      );
      await tester.enterText(_appendQty('m-root'), '0.0001');
      await _settleRebuild(tester);
      await _onlyRoot(tester);
      await _submitSelected(tester);
      final line = _records(_submits().single.body!['lines']).single;
      expect(line['publicSurplusOnly'], isNot(true));
      expect(line['qty'], 0.0001);
    },
  );
}

Map<String, dynamic> _fractionalTapeSources(Map<String, dynamic> data) {
  _threeSharedBuySources(data);
  for (var i = 0; i < 3; i++) {
    _fixtureMaterial(data, 'shared-$i').addAll({
      'goodsCode': 'UT3015',
      'goodsName': '优腾封箱胶',
      'unitName': '个',
      'requiredQty': 0.5,
      'sourceRequiredQty': 0.5,
      'shortageQty': 0.5,
      'demandSupplyGapQty': 0.5,
      'additionalSupplyRecommendedQty': 0.5,
      'netShortageQty': 0.5,
      'minOrderQty': null,
      'orderMultipleQty': null,
    });
  }
  return data;
}

Map<String, dynamic> _fractionalTapePreview(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) {
  return {
    'analysisId': data['analysisId'],
    'version': data['version'],
    'fingerprint': data['fingerprint'],
    'previewFingerprint': 'c' * 64,
    'analysis': data,
    'groups': [
      for (final group in _records(body['groups']))
        <String, dynamic>{
          'clientGroupKey': group['clientGroupKey'],
          'compatibilityKey': 'fractional-tape',
          'route': 'BUY',
          'goodsId': 'g-m-2',
          'goodsName': '优腾封箱胶',
          'unitId': 'unit-1',
          'unitName': '个',
          'sourceRequiredQty': 1.5,
          'orderedQty': 0,
          'remainingQty': 1.5,
          'requestedQty': double.parse(group['qty'].toString()),
          'publicExtraQty': 0,
          'safetyQty': 0,
          'sources': [
            for (var i = 0; i < 3; i++)
              <String, dynamic>{
                'materialLineId': 'shared-$i',
                'analysisLineId': 'product-$i',
                'sourceLabel': '测试产品$i',
                'allocationPriority': i + 1,
                'sourceRequiredQty': 0.5,
                'remainingQty': 0.5,
                'allocatedQty': 0.5,
                'orderedQty': 0,
              },
          ],
          'sharedBomChildren': <Object>[],
        },
    ],
  };
}

Map<String, dynamic> _fractionalTapeSubmit(
  Map<String, dynamic> body,
  Map<String, dynamic> data,
) => _defaultAggregateSubmit({
  ...body,
  'groups': [
    for (final group in _records(body['groups']))
      {
        ...group,
        'sourceRequestedQtyByMaterialLineId': {
          for (final id in group['materialLineIds'] as List) id: '0.5',
        },
      },
  ],
}, data);
