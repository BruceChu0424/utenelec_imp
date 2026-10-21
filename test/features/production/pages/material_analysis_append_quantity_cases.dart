part of 'material_analysis_one_table_test.dart';

void _appendQuantityRegressionTests() {
  for (final proof in [
    (total: 8000, exact: true, growable: 8000, output: 8000),
    (total: 12000, exact: true, growable: 8000, output: 8000),
    (total: 12000, exact: false, growable: 8000, output: 8000),
    (total: 8000, exact: true, growable: null, output: 8000),
    (total: 8000, exact: true, growable: null, output: 6000),
    (total: 8000, exact: true, growable: 7000, output: 8000),
  ]) {
    final estimates = proof.exact && proof.growable == 8000;
    testWidgets('委外父件已下8000再追加1000：公共备货与共享批次 $proof', (tester) async {
      Map<String, dynamic> prepare(Map<String, dynamic> data) {
        final parent = _fixtureMaterial(data, 'm-p');
        parent.addAll({
          'sourceRequiredQty': 5000,
          'requiredQty': 5000,
          'shortageQty': 5000,
          'allocatedAvailableQty': 0,
          'additionalSupplyRecommendedQty': 0,
          'netShortageQty': 0,
          'aggregatePreparation': {
            'requiredQty': 5000,
            'orderedQty': 8000,
            'allocatedOrderedQty': 5000,
            'totalOrderedQty': proof.total,
            'orderedQtyExact': proof.exact,
            'planningUncoveredQty': 0,
            'netShortageQty': 0,
            'targetMaterialLineIds': ['m-p'],
            'actionable': true,
          },
          'preparationPoolKey': 'pool-parent',
          'preparationSharedAvailableQty': 3000,
          'preparationOwnedAvailableQty': 0,
          'preparationUncoveredBeforeSharedQty': 0,
          'preparationAdoptableSharedQty': 0,
          'downstreamReferences': [
            {
              'actionId': 'act-p',
              'route': 'SUBCONTRACT',
              'status': 'CREATED',
              'documentNo': 'EB-8000',
              'allocatedQty': 5000,
              'growableLineQty': proof.growable,
            },
          ],
        });
        final child = _fixtureMaterial(data, 'm-pc');
        child.addAll({
          'sourceConfirmed': 'MAKE',
          'sourceRequiredQty': 5000,
          'requiredQty': proof.output,
          'shortageQty': proof.output,
          'allocatedAvailableQty': 0,
          'additionalSupplyRecommendedQty': proof.output,
          'netShortageQty': proof.output,
        });
        data['supplyActions'] = [
          ...(data['supplyActions'] as List? ?? const []).where(
            (raw) => (raw as Map)['actionId'] != 'act-p',
          ),
          {
            'actionId': 'act-p',
            'route': 'SUBCONTRACT',
            'operationType': 'SUPPLY',
            'requestedQty': 5000,
            'publicSurplusQty': 3000,
            'status': 'CREATED',
          },
        ];
        return data;
      }

      await _pump(
        tester,
        permissions: {
          ..._overSupplyPermissions,
          Perm.productionMaterialAnalysisGenerate,
        },
        overSupply: true,
        previewDelayMs: 1200,
        defaultWorkshops: _workshopDefaultsFor(const ['g-m-pc']),
        mutate: prepare,
        preview: (data, typed) {
          final quantity = proof.output + (typed['m-p'] ?? 0);
          _fixtureMaterial(data, 'm-pc').addAll({
            'requiredQty': quantity,
            'shortageQty': quantity,
            'allocatedAvailableQty': 0,
            'additionalSupplyRecommendedQty': quantity,
            'netShortageQty': quantity,
          });
          return data;
        },
      );
      expect(_qtyText(tester, _orderQty('m-pc')), '${proof.output}');
      await tester.enterText(_appendQty('m-p'), '500');
      await tester.pump(const Duration(milliseconds: 400));
      expect(previews.last['typedOutputs'], [
        {'materialLineId': 'm-p', 'qty': 500.0},
      ]);
      await tester.enterText(_appendQty('m-p'), '1000');
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _qtyText(tester, _orderQty('m-pc')),
        estimates ? '${proof.output + 1000}' : '${proof.output}',
        reason: '公共备货是父件实际产出；其他来源的整批量不属于本行。历史量不完整时等待服务端。',
      );
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        _qtyText(tester, _orderQty('m-pc')),
        estimates ? '${proof.output + 1000}' : '${proof.output + 500}',
      );
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(previews.last['typedOutputs'], [
        {'materialLineId': 'm-p', 'qty': 1000.0},
      ]);
      expect(_qtyText(tester, _orderQty('m-pc')), '${proof.output + 1000}');
      expect(_sourceRequiredText(tester, 'MATERIAL|m-pc'), '5000 个');
    });
  }

  testWidgets('自制父件部分完工入库后再追加：保留未结子件快照，等待服务端展开', (tester) async {
    await _pump(
      tester,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
      overSupply: true,
      previewDelayMs: 1200,
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root', 'g-m-6']),
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        final product =
            (data['products'] as List).first as Map<String, dynamic>;
        product.addAll({
          'issuedPlanQty': 8000,
          'planExecutionInboundQty': 2000,
          'remainingQty': 0,
          'canSchedule': false,
          'canIssueSurplus': true,
        });
        _fixturePlanAssignment(product);
        _fixtureMaterial(data, 'm-root').addAll({
          'requiredQty': 5000,
          'additionalSupplyRecommendedQty': 0,
          'netShortageQty': 0,
        });
        _fixtureMaterial(data, 'm-6').addAll({
          'requiredQty': 6000,
          'allocatedAvailableQty': 0,
          'shortageQty': 6000,
          'additionalSupplyRecommendedQty': 6000,
          'netShortageQty': 6000,
        });
        return data;
      },
      preview: (data, typed) {
        final quantity = 6000 + (typed['m-root'] ?? 0);
        _fixtureMaterial(data, 'm-6').addAll({
          'requiredQty': quantity,
          'allocatedAvailableQty': 0,
          'shortageQty': quantity,
          'additionalSupplyRecommendedQty': quantity,
          'netShortageQty': quantity,
        });
        return data;
      },
    );
    await tester.enterText(_appendQty('m-root'), '1000');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_qtyText(tester, _orderQty('m-6')), '6000');
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(_qtyText(tester, _orderQty('m-6')), '7000');
  });
}
