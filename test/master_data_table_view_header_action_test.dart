import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

Widget _page({
  MasterHeaderFilterAction? action,
  Object scope = 'first',
  ValueChanged<String?>? onSelected,
}) => MaterialApp(
  home: Scaffold(
    body: MasterDataTableView<String>(
      columns: [
        MasterColumnDef(
          key: 'date',
          label: '修改时间',
          width: 220,
          value: (row) => row,
          columnSearchEnabled: false,
          headerFilterAction: action,
        ),
        MasterColumnDef(
          key: 'action',
          label: '操作',
          width: 180,
          value: (row) => row,
          columnSearchEnabled: false,
          facetSearchEnabled: true,
        ),
      ],
      items: const ['服务端返回的历史'],
      facets: const {
        'action': [
          MasterFacetBucket(value: 'CREATE', label: '新增', count: 0),
          MasterFacetBucket(value: 'DELETE', label: '删除', count: 0),
        ],
      },
      filters: const {},
      nullCounts: const {},
      facetSearchScope: scope,
      onFilterChanged: (_, value) => onSelected?.call(value),
    ),
  ),
);

void main() {
  testWidgets('custom header picker keeps native label and enabled state', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      _page(
        action: MasterHeaderFilterAction(onTap: () => opens++, value: '十月'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('修改时间：十月'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('master-column-filter-date')));
    await tester.pump();
    expect(opens, 1);
    await tester.pumpWidget(
      _page(
        action: MasterHeaderFilterAction(
          onTap: () => opens++,
          enabled: false,
          value: '十月',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('master-column-filter-date')));
    await tester.pump();
    expect(opens, 1);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'enum candidate search is local to complete candidates and selects one exact value',
    (tester) async {
      final selected = <String?>[];
      await tester.pumpWidget(_page(onSelected: selected.add));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('master-column-filter-action')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '删除',
      );
      await tester.pump();
      expect(find.text('新增'), findsNothing);
      expect(find.text('删除'), findsNWidgets(2));
      expect(find.widgetWithText(TextButton, '搜索'), findsNothing);
      expect(find.text('服务端返回的历史'), findsNWidgets(2));
      expect(selected, isEmpty);
      await tester.tap(find.text('删除').last);
      await tester.pump();
      expect(selected, ['DELETE']);
      expect(find.byType(Checkbox), findsNothing);
    },
  );

  testWidgets('candidate overlay closes when its owning query changes', (
    tester,
  ) async {
    final selected = <String?>[];
    await tester.pumpWidget(_page(onSelected: selected.add));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('master-column-filter-action')));
    await tester.pump();
    expect(find.byKey(const Key('uten-column-keyword-input')), findsOneWidget);
    await tester.pumpWidget(
      _page(onSelected: selected.add, scope: 'new-owner'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('uten-column-keyword-input')), findsNothing);
    expect(selected, isEmpty);
  });
}
