import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

// 2026-10-09「拼音打一半丢输入法」根因修复的回归锁：
// toolbarLeadingActions（搜索框所在）经 GlobalKey 稳定挂载——表格在
// 首屏加载 → 有数据 → 搜索命中 0 条（空态）之间切换时，搜索框的 Element
// 不重建、焦点不丢、已输入文本不丢。
void main() {
  final columns = [
    MasterColumnDef<Map<String, String>>(
      key: 'status',
      label: '状态',
      width: 120,
      value: (row) => row['status'],
    ),
  ];

  Widget page({
    required List<Map<String, String>> items,
    required bool loading,
    required GlobalKey searchKey,
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 900,
        height: 500,
        child: MasterDataTableView<Map<String, String>>(
          columns: columns,
          items: items,
          isLoading: loading,
          facets: const {
            'status': [MasterFacetBucket(value: 'x', count: 1, label: '甲')],
          },
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          toolbarLeadingActions: [
            SizedBox(
              width: 220,
              child: UtenSearchBar(
                key: searchKey,
                hint: '搜索员工',
                onChanged: (_) {},
              ),
            ),
          ],
          emptyMessage: '没有数据',
        ),
      ),
    ),
  );

  testWidgets(
    'leading search box survives loading → data → empty state switches',
    (tester) async {
      final searchKey = GlobalKey();
      await tester.pumpWidget(
        page(items: const [], loading: true, searchKey: searchKey),
      );
      await tester.pump();
      // 首屏加载态也渲染前缀动作：一进页面就能输入。
      expect(find.byType(UtenSearchBar), findsOneWidget);
      final stateOnLoading = searchKey.currentState;
      expect(stateOnLoading, isNotNull);

      // 加载完成，有数据行。
      await tester.pumpWidget(
        page(
          items: const [
            {'status': '甲'},
          ],
          loading: false,
          searchKey: searchKey,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('甲'), findsOneWidget);
      expect(searchKey.currentState, same(stateOnLoading));

      // 搜索命中 0 条 → 空态：搜索框仍在同一 Element 上。
      await tester.pumpWidget(
        page(items: const [], loading: false, searchKey: searchKey),
      );
      await tester.pumpAndSettle();
      expect(find.text('没有数据'), findsOneWidget);
      expect(find.byType(UtenSearchBar), findsOneWidget);
      expect(searchKey.currentState, same(stateOnLoading));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('focus and typed text survive the empty-result switch', (
    tester,
  ) async {
    final searchKey = GlobalKey();
    await tester.pumpWidget(
      page(
        items: const [
          {'status': '甲'},
        ],
        loading: false,
        searchKey: searchKey,
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, '李');
    await tester.pump();
    expect(find.text('李'), findsOneWidget);

    // 搜索 0 命中 → 空态：焦点仍在搜索框、文字仍在。
    await tester.pumpWidget(
      page(items: const [], loading: false, searchKey: searchKey),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有数据'), findsOneWidget);
    expect(find.text('李'), findsOneWidget);
    final focus = FocusManager.instance.primaryFocus;
    expect(focus, isNotNull);
    // 焦点节点必须仍挂在搜索框子树里（而不是落到页面别处）。
    expect(
      focus!.context!.findAncestorWidgetOfExactType<UtenSearchBar>(),
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
