part of 'material_analysis_one_table_test.dart';

Finder _orderMethod(String line) =>
    find.byKey(ValueKey('material-analysis-order-method-${_groupKey(line)}'));

Future<void> _chooseRowOrderMethod(
  WidgetTester tester,
  Finder field, {
  required bool extra,
}) async {
  await selectMaterialOrderMethod(
    tester,
    field,
    extra ? 'ORDER_ALL' : 'AVAILABLE_THEN_ORDER',
  );
  await _settlePreview(tester);
}

void materialRowOrderMethodCases() {
  testWidgets('全选下单：顶层10000回执后按最新需求下达子件，分段显示进度', (tester) async {
    void applyRequirements(Map<String, dynamic> data, double output) {
      for (final (id, qty) in [('m-6', output), ('m-2', output / 2)]) {
        final covered = id == 'm-6' ? 1000 : 0;
        _fixtureMaterial(data, id).addAll({
          'requiredQty': qty,
          'shortageQty': qty - covered,
          'additionalSupplyRecommendedQty': qty - covered,
          'planningUncoveredQty': qty - covered,
          'netShortageQty': qty - covered,
        });
      }
    }

    await _pump(
      tester,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
      overSupply: true,
      delayMs: 900,
      defaultWorkshops: _workshopDefaultsFor(const ['g-m-root', 'g-m-6']),
      mutate: (data) {
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        (data['flatMaterials'] as List).removeWhere(
          (raw) => !{
            'm-root',
            'm-6',
            'm-2',
          }.contains((raw as Map)['materialLineId']),
        );
        for (final (id, qty, stock, ratio) in [
          ('m-root', 1000, 0, 1),
          ('m-6', 1000, 1000, 1),
          ('m-2', 500, 0, 0.5),
        ]) {
          _fixtureMaterial(data, id).addAll({
            'requiredQty': qty,
            'sourceRequiredQty': qty,
            'allocatedAvailableQty': stock,
            'availableQty': stock,
            'shortageQty': qty - stock,
            'additionalSupplyRecommendedQty': qty - stock,
            'netShortageQty': qty - stock,
            'bomQty': ratio,
            'perProductQty': ratio,
            'parentPerProductQty': 1,
          });
        }
        return data;
      },
      preview: (data, typed) {
        applyRequirements(data, typed['m-root'] ?? 1000);
        return data;
      },
      afterWrite: (data) {
        final product = (data['products'] as List).first as Map;
        applyRequirements(data, _num(product['issuedPlanQty']));
        return data;
      },
    );
    await tester.enterText(_orderQty('m-root'), '10000');
    await _settlePreview(tester);
    await _chooseRowOrderMethod(tester, _orderMethod('m-6'), extra: true);
    final selectAll = find
        .byKey(const Key('master-data-table-select-all'))
        .first;
    if (tester.widget<Checkbox>(selectAll).value != true) {
      await tester.tap(selectAll);
      await _settlePreview(tester);
    }
    expect(_qtyText(tester, _orderQty('m-6')), '10000');
    expect(_qtyText(tester, _orderQty('m-2')), '5000');

    final submit = tester
        .widget<UtenButton>(
          find.byKey(const Key('material-analysis-submit-orders')),
        )
        .onPressed!;
    submit();
    submit();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('共 3 种，合计 25000'), findsOneWidget);
    await tester.tap(find.widgetWithText(UtenButton, '确认下单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 整批一个进度弹窗走完两段, 不叠页面遮罩。
    final dialog = find.byKey(const ValueKey('uten-progress-cancel'));
    expect(dialog, findsOneWidget);
    expect(
      find.byKey(const Key('material-analysis-plan-submission-progress')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump(const Duration(milliseconds: 400));
    expect(dialog, findsOneWidget);
    expect(
      find.byKey(const Key('material-analysis-action-busy')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final root = _records(_submits().single.body!['lines']).single;
    expect(root['qty'], 10000);
    final groups = _records(_aggregateSubmits().single.body!['groups']);
    expect(
      {for (final group in groups) group['route']: group['qty']},
      {'MAKE': '10000', 'BUY': '5000'},
    );
    expect(
      {
        for (final group in groups)
          ...(group['sourceRequestedQtyByMaterialLineId'] as Map),
      },
      {'m-6': '10000', 'm-2': '5000'},
    );
    expect(
      find.byKey(const Key('material-analysis-action-busy')),
      findsNothing,
    );
  });

  testWidgets('逐行下单方式：父改量即时更新子件且预览保留精确数量与原需求基线', (tester) async {
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
        (data['flatMaterials'] as List).removeWhere(
          (raw) => !{'m-root', 'm-2'}.contains((raw as Map)['materialLineId']),
        );
        _fixtureMaterial(data, 'm-root').addAll({
          'requiredQty': 1000,
          'sourceRequiredQty': 1000,
          'allocatedAvailableQty': 0,
          'availableQty': 0,
          'shortageQty': 1000,
          'additionalSupplyRecommendedQty': 1000,
          'netShortageQty': 1000,
        });
        _fixtureMaterial(data, 'm-2').addAll({
          'requiredQty': 500,
          'sourceRequiredQty': 500,
          'allocatedAvailableQty': 0,
          'availableQty': 0,
          'shortageQty': 500,
          'additionalSupplyRecommendedQty': 500,
          'netShortageQty': 500,
          'bomQty': 0.5,
          'perProductQty': 0.5,
          'parentPerProductQty': 1,
        });
        return data;
      },
      preview: (data, typed) {
        final required = (typed['m-root'] ?? 1000) * 0.5;
        _fixtureMaterial(data, 'm-2').addAll({
          'requiredQty': required,
          'shortageQty': required,
          'additionalSupplyRecommendedQty': required,
          'netShortageQty': required,
        });
        return data;
      },
    );
    expect(_qtyText(tester, _orderQty('m-2')), '500');
    await tester.enterText(_orderQty('m-root'), '1500');
    await tester.pump();
    expect(_qtyText(tester, _orderQty('m-2')), '750');
    await _settlePreview(tester);
    expect(_qtyText(tester, _orderQty('m-2')), '750');
    expect(_sourceRequiredText(tester, 'MATERIAL|m-2'), '500 个');
    expect(previews.last['typedOutputs'], [
      {
        'materialLineId': 'm-root',
        'qty': '1500',
        'quantityMode': 'COVERAGE_TOTAL',
        'orderMethod': 'ORDER_ALL',
      },
    ]);
    expect(_aggregateSubmits(), isEmpty);
    expect(_submits(), isEmpty);
  });

  testWidgets('逐行下单方式：仅修改方式的草稿关闭重开后保留三种选择和数量', (tester) async {
    final storage = MemoryFormDraftStorage();
    await _pump(
      tester,
      session: _OrderAuthoritySession(),
      draftStorage: storage,
      mutate: _threeSharedBuySources,
    );
    final owner = _materialDraftOwner(tester);
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('shared-0'),
      'AVAILABLE_ONLY',
    );
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('shared-0'),
      'ORDER_ALL',
    );
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('shared-1'),
      'AVAILABLE_ONLY',
    );
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('shared-2'),
      'AVAILABLE_THEN_ORDER',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final records = await _storedPreparationDrafts(storage, owner);
    expect(records, hasLength(1));
    final saved = records.values.single['data'] as Map;
    expect(saved['orderMethodByGroup'], {
      _groupKey('shared-0'): 'ORDER_ALL',
      _groupKey('shared-1'): 'AVAILABLE_ONLY',
      _groupKey('shared-2'): 'AVAILABLE_THEN_ORDER',
    });
    expect(_submits(), isEmpty);
    expect(_aggregateSubmits(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pump(
      tester,
      session: _OrderAuthoritySession(),
      draftStorage: storage,
      preparationDraftId: records.values.single['id'] as String,
      mutate: _threeSharedBuySources,
    );
    for (final (index, method) in const [
      'ORDER_ALL',
      'AVAILABLE_ONLY',
      'AVAILABLE_THEN_ORDER',
    ].indexed) {
      expect(
        tester.widget<UtenDropdownField>(_orderMethod('shared-$index')).value,
        method,
      );
      expect(_qtyText(tester, _orderQty('shared-$index')), '1000');
    }
    expect(_submits(), isEmpty);
    expect(_aggregateSubmits(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('逐行下单方式：实际字体在1920、1440和窄屏保持完整单行', (tester) async {
    await loadAuditScreenshotFonts(tester);
    for (final width in [1920.0, 1440.0, 390.0]) {
      await _pump(
        tester,
        platform: TargetPlatform.windows,
        screenshot: true,
        size: Size(width, 1000),
        mutate: (data) {
          (data['flatMaterials'] as List).removeWhere(
            (raw) => !{
              'm-root',
              'm-2',
              'm-4',
            }.contains((raw as Map)['materialLineId']),
          );
          return data;
        },
      );
      final method = _orderMethod('m-2');
      final initialWidth = tester.getSize(method).width;
      await selectMaterialOrderMethod(tester, method, 'AVAILABLE_THEN_ORDER');
      final text = find.descendant(
        of: method,
        matching: find.text('使用可用数量，不足再采购'),
      );
      expect(text, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: '$width宽视口不能截断下单方式');
      final methodWidth = tester.getSize(method).width;
      expect(methodWidth, greaterThan(initialWidth));
      expect(methodWidth, lessThan(240));
      final arrow = find.descendant(
        of: method,
        matching: find.byIcon(Icons.arrow_drop_down_rounded),
      );
      expect(tester.getSize(arrow).width, UtenDropdownField.flatArrowWidth);
      expect(tester.getSize(method).height, 28);
      if (width == 390) {
        final rect = tester.getRect(method);
        expect(rect.left, greaterThanOrEqualTo(64), reason: '完整控件应位于固定勾选列右侧');
        expect(rect.right, lessThanOrEqualTo(width - 16));
      }
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('UTEN_ROW_METHOD_CAPTURE')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('row-order-method-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final output = Directory(
              'output/material-row-order-method-20261106',
            )..createSync(recursive: true);
            await File(
              '${output.path}/order-method-${width.toInt()}.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
    }
  });

  testWidgets('逐行下单方式：按内容适配并紧随数量列，三路线文案明确', (tester) async {
    await _pump(
      tester,
      size: const Size(1440, 1000),
      mutate: (data) {
        (data['flatMaterials'] as List).removeWhere(
          (raw) => !{
            'm-root',
            'm-2',
            'm-6',
            'm-p',
          }.contains((raw as Map)['materialLineId']),
        );
        return data;
      },
    );
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const Key('material-analysis-material-table')),
    );
    final keys = table.columns.map((column) => column.key).toList();
    expect(keys.indexOf('orderMethod'), keys.indexOf('orderQty') + 1);
    for (final entry in {'m-2': '采购', 'm-6': '车间', 'm-p': '委外'}.entries) {
      final field = _orderMethod(entry.key);
      final dropdown = tester.widget<UtenDropdownField>(field);
      expect(dropdown.allowClear, isFalse);
      expect(dropdown.searchable, isFalse);
      expect(dropdown.items.map((item) => item.label), [
        '全部下单${entry.value}',
        '仅使用可用数量',
        '使用可用数量，不足再${entry.value}',
      ]);
      expect(tester.getSize(field).width, lessThan(240));
      expect(tester.getSize(field).height, 28);
    }
    expect(
      find.byKey(const Key('material-preparation-supply-usage')),
      findsNothing,
    );
    expect(find.text('本次下单是否使用可用数量抵扣？'), findsNothing);
  });

  for (final stock in [120, 1000]) {
    testWidgets('逐行下单方式：需求1000库存$stock仍默认下单1000', (tester) async {
      await _pump(
        tester,
        mutate: (data) {
          (data['flatMaterials'] as List).removeWhere(
            (raw) =>
                !{'m-root', 'm-2'}.contains((raw as Map)['materialLineId']),
          );
          _fixtureMaterial(data, 'm-2').addAll({
            'requiredQty': 1000,
            'sourceRequiredQty': 1000,
            'allocatedAvailableQty': stock,
            'availableQty': stock,
            'additionalSupplyRecommendedQty': 1000 - stock,
            'planningUncoveredQty': 1000 - stock,
            'netShortageQty': 1000 - stock,
            'mainWarehousePublicAvailableQty': stock,
          });
          return data;
        },
      );
      expect(_sourceRequiredText(tester, 'MATERIAL|m-2'), '1000 个');
      final table = tester.widget<MasterDataTableView<dynamic>>(
        find.byKey(const Key('material-analysis-material-table')),
      );
      final row = table.items.singleWhere((dynamic row) {
        // ignore: avoid_dynamic_calls
        return row.key == 'MATERIAL|m-2';
      });
      final dynamic quantityColumn = table.columns.singleWhere(
        (column) => column.key == 'orderQty',
      );
      expect(
        // ignore: avoid_dynamic_calls
        quantityColumn.value(row),
        '1000',
        reason: '含齐套只读行在内的真实显示数量不得先扣库存',
      );
      expect(
        _qtyText(tester, _orderQty('m-2')),
        '1000',
        reason: '库存决定使用已有供给还是新增采购，不得先从本行需求数量扣除',
      );
      expect(_orderMethod('m-2'), findsOneWidget);
      expect(
        tester.widget<UtenDropdownField>(_orderMethod('m-2')).value,
        stock < 1000 ? 'ORDER_ALL' : 'AVAILABLE_ONLY',
      );
      expect(find.text('本次下单是否使用可用数量抵扣？'), findsNothing);
      expect(
        find.byKey(const Key('material-preparation-supply-usage')),
        findsNothing,
      );
      expect(_submits(), isEmpty);
      expect(_aggregateSubmits(), isEmpty);
    });
  }

  testWidgets('逐行下单方式：同货品三来源三种方式同批提交互不串用', (tester) async {
    await _pump(
      tester,
      mutate: (data) {
        _threeSharedBuySources(data);
        // 78730ed45：AVAILABLE_ONLY / AVAILABLE_THEN_ORDER 的覆盖总量预览按
        // 服务端增量折算核对，行上须有权威 planningUncoveredQty；等于需求量
        // （计划尚未覆盖任何需求）保持「新增 = 输入」的既有数量口径。
        for (var i = 0; i < 3; i++) {
          _fixtureMaterial(data, 'shared-$i')['planningUncoveredQty'] = 1000;
        }
        return data;
      },
    );
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('shared-1'),
      'AVAILABLE_ONLY',
    );
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('shared-2'),
      'AVAILABLE_THEN_ORDER',
    );
    await _settlePreview(tester);
    for (var i = 0; i < 3; i++) {
      expect(_qtyText(tester, _orderQty('shared-$i')), '1000');
    }
    for (var i = 0; i < 3; i++) {
      await _check(tester, _rowCheckbox('shared-$i'));
    }
    await _settlePreview(tester);
    await _openSubmitConfirmation(tester);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('确认下单'),
      ),
      findsOneWidget,
      reason: _notices(tester),
    );
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    await _submitSelected(tester);
    final groups = [
      for (final request in _aggregateSubmits())
        ..._records(request.body!['groups']),
    ];
    expect(groups, hasLength(3), reason: '相同货品不同下单方式必须保持三个独立意图');
    const modes = ['ORDER_ALL', 'AVAILABLE_ONLY', 'AVAILABLE_THEN_ORDER'];
    for (var i = 0; i < 3; i++) {
      final group = groups.singleWhere(
        (group) => (group['materialLineIds'] as List).contains('shared-$i'),
      );
      expect(group['orderMethod'], modes[i]);
      expect(group['quantityMode'], 'COVERAGE_TOTAL');
      expect(group['qty'], '1000');
      expect(group['sourceRequestedQtyByMaterialLineId'], {
        'shared-$i': '1000',
      });
    }
    expect(find.text('本次下单是否使用可用数量抵扣？'), findsNothing);
  });

  testWidgets('逐行下单方式：父件库存充足也不限制子件直接下单，上级需求保持不变', (tester) async {
    String? parentMethod;
    Map<String, dynamic>? parentInput;
    await _pump(
      tester,
      permissions: {
        ..._overSupplyPermissions,
        Perm.productionMaterialAnalysisGenerate,
      },
      overSupply: true,
      defaultWorkshops: _workshopDefaultsFor(const ['g-covered-make']),
      mutate: (data) {
        (data['flatMaterials'] as List).removeWhere(
          (raw) =>
              !{'m-root', 'm-covered'}.contains((raw as Map)['materialLineId']),
        );
        (data['allowedActions'] as List).add('GENERATE_PLAN');
        _fixtureMaterial(data, 'm-covered').addAll({
          'sourceConfirmed': 'SUBCONTRACT',
          'sourceSuggestion': 'SUBCONTRACT',
          'planningUncoveredQty': 0,
          'preparationPoolKey': 'covered-parent-pool',
          'preparationOwnedAvailableQty': 1000,
          'preparationSharedAvailableQty': 0,
          'preparationUncoveredBeforeSharedQty': 0,
          'preparationAdoptableSharedQty': 0,
          'preparationSharedSupplySlices': <Object>[],
        });
        for (final (id, route) in [
          ('covered-make', 'MAKE'),
          ('covered-buy', 'BUY'),
        ]) {
          (data['flatMaterials'] as List).add({
            ..._material(
              line: id,
              name: id,
              confirmed: route,
              netShortageQty: 0,
              requiredQty: 0,
              stockQty: 0,
              level: 2,
              parentLine: 'm-covered',
            ),
            'sourceRequiredQty': 880,
            'requirementState': 'INACTIVE_PARENT_COVERED',
            'actionable': false,
            'planningUncoveredQty': 0,
          });
        }
        return data;
      },
      requestObserver: (request) {
        if (!request.path.endsWith('/issue-plans/preview')) return;
        for (final row in _records((request.data as Map)['typedOutputs'])) {
          if (row['materialLineId'] == 'm-covered') {
            parentInput = row;
            parentMethod = row['orderMethod'] as String?;
          }
        }
      },
      preview: (data, typed) {
        final active =
            parentMethod == 'ORDER_ALL' && typed['m-covered'] == 1000;
        for (final id in ['covered-make', 'covered-buy']) {
          _fixtureMaterial(data, id).addAll({
            'requiredQty': active ? 880 : 0,
            'shortageQty': active ? 880 : 0,
            'demandSupplyGapQty': active ? 880 : 0,
            'additionalSupplyRecommendedQty': active ? 880 : 0,
            'planningUncoveredQty': active ? 880 : 0,
            'netShortageQty': active ? 880 : 0,
            'requirementState': active ? 'ACTIVE' : 'INACTIVE_PARENT_COVERED',
            'actionable': active,
          });
        }
        return data;
      },
    );
    expect(
      tester.widget<UtenDropdownField>(_orderMethod('m-covered')).value,
      'AVAILABLE_ONLY',
    );
    for (final id in ['covered-make', 'covered-buy']) {
      expect(_qtyText(tester, _orderQty(id)), '880');
      expect(tester.widget<Checkbox>(_rowCheckbox(id)).onChanged, isNotNull);
      expect(_nodeSelected(tester, id), isFalse);
    }
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('m-covered'),
      'ORDER_ALL',
    );
    await _check(tester, _rowCheckbox('m-covered'));
    await _settlePreview(tester);
    expect(parentInput?['orderMethod'], 'ORDER_ALL');
    expect(parentInput?['quantityMode'], 'COVERAGE_TOTAL');
    for (final id in ['covered-make', 'covered-buy']) {
      expect(_qtyText(tester, _orderQty(id)), '880');
      expect(tester.widget<Checkbox>(_rowCheckbox(id)).onChanged, isNotNull);
    }
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('m-covered'),
      'AVAILABLE_ONLY',
    );
    await _settlePreview(tester);
    for (final id in ['covered-make', 'covered-buy']) {
      expect(_qtyText(tester, _orderQty(id)), '880');
      expect(
        tester.widget<Checkbox>(_rowCheckbox(id)).onChanged,
        isNotNull,
        reason: '父仅用库存也不能限制子件独立下单',
      );
    }
    expect(_aggregateSubmits(), isEmpty);
    expect(_submits(), isEmpty);
    tester.widget<Checkbox>(_rowCheckbox('m-covered').last).onChanged!(false);
    await tester.pumpAndSettle();
    await _check(tester, _rowCheckbox('covered-buy'));
    await _submitSelected(tester);
    final submitted = _records(
      _aggregateSubmits().single.body!['groups'],
    ).single;
    expect(submitted['materialLineIds'], ['covered-buy']);
    expect(submitted['qty'], '880');
    expect(submitted['orderMethod'], 'ORDER_ALL');
    expect(_submits(), isEmpty, reason: '子件独立下单不得替父件下达新的生产或委外');
    expect(tester.takeException(), isNull);
  });

  testWidgets('逐行下单方式：汇总显示混合来源并允许统一选择，切回保留数量', (tester) async {
    await _pump(tester, mutate: _threeSharedBuySources);
    await tester.enterText(_orderQty('shared-0'), '1200');
    await _settleRebuild(tester);
    await selectMaterialOrderMethod(
      tester,
      _orderMethod('shared-1'),
      'AVAILABLE_ONLY',
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pumpAndSettle();
    final aggregateMethod = find.byKey(
      const ValueKey('material-aggregate-order-method-g-m-2|本色|unit-1'),
    );
    expect(tester.widget<UtenDropdownField>(aggregateMethod).value, isNull);
    await selectMaterialOrderMethod(
      tester,
      aggregateMethod,
      'AVAILABLE_THEN_ORDER',
    );
    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      expect(
        tester.widget<UtenDropdownField>(_orderMethod('shared-$i')).value,
        'AVAILABLE_THEN_ORDER',
      );
    }
    expect(_qtyText(tester, _orderQty('shared-0')), '1200');
    expect(_aggregateSubmits(), isEmpty);
    expect(_submits(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
