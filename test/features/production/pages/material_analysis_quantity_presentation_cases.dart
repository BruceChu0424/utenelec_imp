part of 'material_analysis_one_table_test.dart';

Map<String, dynamic> _committedPublicMaterial(Map<String, dynamic> data) {
  final result = _sharedAggregateSubmit({
    'groups': [
      {'qty': '4000', 'clientGroupKey': 'shared', 'route': 'BUY'},
    ],
  }, _threeSharedBuySources(data));
  final next = (result['analysis'] as Map).cast<String, dynamic>();
  for (var i = 0; i < 3; i++) {
    _fixtureMaterial(next, 'shared-$i').addAll({
      'preparationAvailableQty': 1000,
      'mainWarehousePublicAvailableQty': 0,
      'sharedFutureClaimableQty': 1000,
    });
  }
  return next;
}

void materialQuantityPresentationCases() {
  for (final scale in [1.0, 1.6]) {
    testWidgets(
      'quantity unit layout auto width includes long unit at scale $scale',
      (tester) async {
        Future<void> pumpUnit(String unit) => _pump(
          tester,
          fontFactor: scale,
          mutate: (data) {
            _fixtureMaterial(data, 'm-2')['unitName'] = unit;
            return data;
          },
        );
        await pumpUnit('个');
        final shortWidth = _quantityColumnWidth(tester);
        await pumpUnit('UAT-FLUID-个');
        expect(
          _quantityColumnWidth(tester),
          greaterThan(shortWidth + 30),
          reason: '默认下单列必须测量真实单位，不能仍只量数字',
        );
        final fullUnit = find.descendant(
          of: _orderQty('m-2'),
          matching: find.text('UAT-FLUID-个'),
        );
        expect(
          tester
              .renderObject<RenderParagraph>(
                find.descendant(of: fullUnit, matching: find.byType(RichText)),
              )
              .didExceedMaxLines,
          false,
          reason: '自动宽度有余量时应完整显示单位',
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'quantity unit layout narrow column reserves digits and one unit line at scale $scale',
      (tester) async {
        const unit = 'UAT-FLUID-个';
        await _pump(
          tester,
          fontFactor: scale,
          mutate: (data) {
            _fixtureMaterial(data, 'm-2')['unitName'] = unit;
            return data;
          },
        );
        final originalQuantity = _qtyText(tester, _orderQty('m-2'));
        final handle = find.byWidgetPredicate(
          (widget) =>
              widget is UtenColumnResizeHandle && widget.label == '下单数量',
        );
        tester
            .widget<UtenColumnResizeHandle>(handle)
            .onResize(110 - _quantityColumnWidth(tester));
        await tester.pumpAndSettle();
        final field = _orderQty('m-2');
        final editable = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        expect(
          tester.getSize(editable).width,
          greaterThanOrEqualTo(36 * scale),
          reason: '手工缩窄后数字仍需独立可编辑空间',
        );
        final suffix = find.descendant(of: field, matching: find.text(unit));
        expect(suffix, findsOneWidget);
        expect(tester.widget<Text>(suffix).maxLines, 1);
        expect(tester.widget<Text>(suffix).softWrap, false);
        expect(
          find.descendant(of: field, matching: find.byTooltip(unit)),
          findsOneWidget,
        );
        final fieldHeight = tester.getSize(field).height;
        expect(fieldHeight, lessThan(36 * scale + 24), reason: '单位不能折成多行撑高输入框');
        expect(_qtyText(tester, field), originalQuantity);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'quantity unit layout append preserves its raw editor in a narrow column',
    (tester) async {
      const unit = 'UAT-FLUID-个';
      await _pump(
        tester,
        fontFactor: 1.6,
        mutate: (data) {
          _fixtureMaterial(data, 'm-3')['unitName'] = unit;
          return data;
        },
      );
      final field = _appendQty('m-3');
      final original = _qtyText(tester, field);
      final handle = find.byWidgetPredicate(
        (widget) => widget is UtenColumnResizeHandle && widget.label == '追加下单',
      );
      final column = find
          .ancestor(
            of: handle,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Container &&
                  widget.constraints?.hasBoundedWidth == true,
            ),
          )
          .first;
      tester
          .widget<UtenColumnResizeHandle>(handle)
          .onResize(110 - tester.getSize(column).width);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(
              find.descendant(of: field, matching: find.byType(EditableText)),
            )
            .width,
        greaterThanOrEqualTo(57.6),
      );
      expect(
        tester
            .widget<Text>(find.descendant(of: field, matching: find.text(unit)))
            .maxLines,
        1,
      );
      expect(
        find.descendant(of: field, matching: find.byTooltip(unit)),
        findsOneWidget,
      );
      expect(_qtyText(tester, field), original);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quantity unit layout aggregate uses the same single-line editor',
    (tester) async {
      const unit = 'UAT-FLUID-个';
      await _pump(
        tester,
        fontFactor: 1.6,
        mutate: (data) {
          _threeSharedBuySources(data);
          for (final row in (data['flatMaterials'] as List)) {
            (row as Map)['unitName'] = unit;
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
      expect(field, findsOneWidget);
      final handle = find.byWidgetPredicate(
        (widget) => widget is UtenColumnResizeHandle && widget.label == '下单数量',
      );
      tester
          .widget<UtenColumnResizeHandle>(handle)
          .onResize(110 - _quantityColumnWidth(tester));
      await tester.pumpAndSettle();
      final suffix = find.descendant(of: field, matching: find.text(unit));
      expect(tester.widget<Text>(suffix).maxLines, 1);
      expect(
        find.descendant(of: field, matching: find.byTooltip(unit)),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(
              find.descendant(of: field, matching: find.byType(EditableText)),
            )
            .width,
        greaterThanOrEqualTo(57.6),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quantity presentation separates source3000 public1000 and shows the shared pool once',
    (tester) async {
      await _pump(tester, mutate: _committedPublicMaterial);
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      // 2026-10-09 合并口径：已全部并入同料合并批次且无剩余待办的来源路径
      // 折叠（与下达车间同款），聚合行自身携带已下单分解与合并单据号。
      expect(
        find.byKey(
          const ValueKey('material-table-toggle-AGGREGATE|g-m-2|本色|unit-1'),
        ),
        findsNothing,
        reason: '已合并下单的来源不再逐条展开',
      );
      expect(
        find.textContaining('已下单 4000 = 需求份 3000 + 公共备货 1000'),
        findsWidgets,
      );
      // 2026-10-10 T9：单位列退役，锁定的累计已下单量内联单位。
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('material-aggregate-order-g-m-2|本色|unit-1'),
              ),
            )
            .data,
        '4000 个',
      );
      final table = tester.widget<MasterDataTableView<dynamic>>(
        find.byWidgetPredicate(
          (widget) =>
              widget is MasterDataTableView<dynamic> &&
              widget.columns.any(
                (column) => column.key == 'publicAvailableQty',
              ),
        ),
      );
      final dynamic publicColumn = table.columns.singleWhere(
        (column) => column.key == 'publicAvailableQty',
      );
      expect(
        table.items
            .where(
              // 列定义的行类型是页面私有泛型，测试只能经 dynamic 取
              // exactValueOf（运行时按 _MaterialTableRow 校验）。
              // ignore: avoid_dynamic_calls
              (row) => publicColumn.exactValueOf(row) == '1000',
            )
            .length,
        1,
        reason:
            'header calculation and export must not count the same shared pool on source paths',
      );
    },
  );

  testWidgets(
    'quantity presentation preserves three half-unit source shortages and total1.5',
    (tester) async {
      await _pump(
        tester,
        mutate: (data) {
          _threeSharedBuySources(data);
          for (var i = 0; i < 3; i++) {
            _fixtureMaterial(data, 'shared-$i').addAll({
              'requiredQty': 0.5,
              'sourceRequiredQty': 0.5,
              'shortageQty': 0.5,
              'netShortageQty': 0.5,
              'planningUncoveredQty': 0.5,
              'additionalSupplyRecommendedQty': 0.5,
              'demandSupplyGapQty': 0.5,
            });
          }
          return data;
        },
      );
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('material-table-toggle-AGGREGATE|g-m-2|本色|unit-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'material-analysis-net-shortage-AGGREGATE|g-m-2|本色|unit-1',
            ),
          ),
          matching: find.text('1.5 个'),
        ),
        findsOneWidget,
      );
      for (var i = 0; i < 3; i++) {
        expect(
          find.descendant(
            of: find.byKey(
              ValueKey('material-analysis-net-shortage-shared-$i'),
            ),
            matching: find.text('0.5 个'),
          ),
          findsOneWidget,
        );
      }
    },
  );
}

double _quantityColumnWidth(WidgetTester tester) {
  final handle = find.byWidgetPredicate(
    (widget) => widget is UtenColumnResizeHandle && widget.label == '下单数量',
  );
  final column = find
      .ancestor(
        of: handle,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.constraints?.hasBoundedWidth == true,
        ),
      )
      .first;
  return tester.getSize(column).width;
}
