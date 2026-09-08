import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
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
    final scrollbar = find.ancestor(
      of: chooser,
      matching: find.byType(Scrollbar),
    );
    expect(scrollbar, findsOneWidget);
    expect(tester.widget<Scrollbar>(scrollbar).thumbVisibility, isTrue);

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
