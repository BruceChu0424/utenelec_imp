import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  testWidgets('the trailing column action scrolls with the table header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: MasterDataTableView<int>(
              columns: [
                for (var i = 0; i < 6; i++)
                  MasterColumnDef(
                    key: 'c$i',
                    label: '列 $i',
                    width: 120,
                    minimumWidthOf: (_) => 120,
                    value: (_) => '值 $i',
                  ),
              ],
              items: const [1],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              idOf: (row) => '$row',
              selectable: true,
              onSelectedIdsChanged: (_) {},
              enableTextSelection: false,
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('platform-table-add-column'));
    final toolbar = find.text('表头设置 6/6');
    expect(button, findsOneWidget);
    expect(button.hitTestable(), findsNothing);
    expect(toolbar.hitTestable(), findsOneWidget);

    final body = Scrollable.of(
      tester.element(find.text('值 1')),
      axis: Axis.horizontal,
    ).position;
    expect(body.maxScrollExtent, greaterThan(250));
    await tester.drag(find.text('值 1'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(body.pixels, greaterThan(0));
    expect(button.hitTestable(), findsNothing);

    body.jumpTo(body.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(button.hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('master-data-table-select-all')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('显示列'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('many-column chooser visibly scrolls to quantity and weight', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const labels = <String>[
      '所属类型',
      '物料编码',
      '物料系列',
      '库位号',
      '型号',
      '客户型号',
      '货品名称',
      '规格',
      '颜色',
      '单位',
      '备注',
      '库存重量',
      '库存数量',
      '待检量',
      '成本金额',
      '多排数量',
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 600,
            child: MasterDataTableView<Map<String, String>>(
              columns: [
                for (var i = 0; i < labels.length; i++)
                  MasterColumnDef<Map<String, String>>(
                    key: 'c$i',
                    label: labels[i],
                    width: 100,
                    value: (row) => row['c$i'],
                  ),
              ],
              items: const [<String, String>{}],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('表头设置 16/16'));
    await tester.pumpAndSettle();

    final chooser = find.byKey(const ValueKey('uten-column-chooser-scroll'));
    expect(chooser, findsOneWidget);
    final chooserScroll = find.descendant(
      of: chooser,
      matching: find.byType(Scrollable),
    );
    expect(chooserScroll, findsOneWidget);
    expect(
      tester.state<ScrollableState>(chooserScroll).position.maxScrollExtent,
      greaterThan(0),
      reason: '菜单必须真实可滚；滚动条外观由下拉菜单主题独立控制',
    );

    final weightOption = find.descendant(
      of: chooser,
      matching: find.text('库存重量'),
    );
    await tester.scrollUntilVisible(
      weightOption,
      180,
      scrollable: chooserScroll,
    );
    await tester.pumpAndSettle();
    expect(weightOption, findsOneWidget);

    await tester.tap(weightOption);
    await tester.pumpAndSettle();
    expect(find.text('表头设置 15/16'), findsOneWidget);

    final quantityOption = find.descendant(
      of: chooser,
      matching: find.text('库存数量'),
    );
    expect(quantityOption, findsOneWidget);
  });
}
