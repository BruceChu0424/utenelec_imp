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
  testWidgets(
    'quantity presentation separates source3000 public1000 and shows the shared pool once',
    (tester) async {
      await _pump(tester, mutate: _committedPublicMaterial);
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
        find.textContaining('已下单 4000 = 需求份 3000 + 公共备货 1000'),
        findsWidgets,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('material-aggregate-order-g-m-2|本色|unit-1'),
              ),
            )
            .data,
        '4000',
      );
      for (var i = 0; i < 3; i++) {
        final available = find.byKey(
          ValueKey('material-analysis-public-available-shared-$i'),
        );
        expect(
          find.descendant(of: available, matching: find.text('1000')),
          findsNothing,
        );
        expect(
          find.descendant(of: available, matching: find.text('—')),
          findsOneWidget,
        );
      }
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
          matching: find.text('1.5'),
        ),
        findsOneWidget,
      );
      for (var i = 0; i < 3; i++) {
        expect(
          find.descendant(
            of: find.byKey(
              ValueKey('material-analysis-net-shortage-shared-$i'),
            ),
            matching: find.text('0.5'),
          ),
          findsOneWidget,
        );
      }
    },
  );
}
