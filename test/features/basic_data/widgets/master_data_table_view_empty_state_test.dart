import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

/// 2026-09-10（F2a-flow / F2b）：成功空态必须保留「全屏/退出全屏」、
/// `toolbarLeadingActions`，并在有激活表头筛选时给「清除筛选」出口 +
/// 「当前有 N 个表头筛选生效」提示——列头筛选控件随表头一起不渲染，
/// 否则用户没有入口撤掉看不见的筛选（全屏里还会被困住）。
void main() {
  Widget host({
    required Map<String, String?> filters,
    required void Function(String key, String? value) onFilterChanged,
    bool showFullscreenToggle = false,
    bool embedded = true,
    bool selectable = false,
    bool showSelectionSummary = true,
    Set<String> selectedIds = const {},
    Widget? floatingActionButton,
    List<Widget>? leading,
    List<Map<String, String>> items = const [],
  }) => MaterialApp(
    home: Scaffold(
      floatingActionButton: floatingActionButton,
      body: SizedBox(
        width: 900,
        height: 500,
        child: MasterDataTableView<Map<String, String>>(
          columns: [
            MasterColumnDef<Map<String, String>>(
              key: 'status',
              label: '状态',
              width: 120,
              value: (row) => row['status'],
            ),
          ],
          items: items,
          facets: const {
            'status': [MasterFacetBucket(value: 'x', count: 1, label: '甲')],
          },
          nullCounts: const {},
          filters: filters,
          onFilterChanged: onFilterChanged,
          embedded: embedded,
          selectable: selectable,
          idOf: selectable ? (row) => row['status'] : null,
          selectedIds: selectedIds,
          showSelectionSummary: showSelectionSummary,
          showFullscreenToggle: showFullscreenToggle,
          toolbarLeadingActions: leading,
          emptyMessage: '没有数据',
        ),
      ),
    ),
  );

  testWidgets(
    'empty state with an active filter offers clear-filters and reports the count',
    (tester) async {
      final cleared = <(String, String?)>[];
      await tester.pumpWidget(
        host(
          filters: const {'status': 'x', 'other': null, 'blank': ''},
          onFilterChanged: (key, value) => cleared.add((key, value)),
          leading: const [Text('视图切换')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('没有数据'), findsOneWidget);
      expect(find.text('当前有 1 个表头筛选生效'), findsOneWidget);
      expect(find.text('视图切换'), findsOneWidget);
      final clear = find.byKey(const ValueKey('master-table-clear-filters'));
      expect(clear, findsOneWidget);
      expect(find.text('清除筛选'), findsOneWidget);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      // 只对有值的列回调 null；空串/null 的列不算激活筛选。
      expect(cleared, [('status', null)]);
    },
  );

  testWidgets('empty state without an active filter has no clear button', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(filters: const {'status': null}, onFilterChanged: (_, _) {}),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有数据'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsNothing,
    );
    expect(find.textContaining('个表头筛选生效'), findsNothing);
  });

  testWidgets('empty selection stays only in the host floating action group', (
    tester,
  ) async {
    Widget page(List<Map<String, String>> items) => host(
      filters: const {'status': 'x'},
      onFilterChanged: (_, _) {},
      embedded: false,
      selectable: true,
      showSelectionSummary: false,
      selectedIds: const {'甲'},
      items: items,
      leading: const [Text('分类筛选')],
      floatingActionButton: const UtenFloatingActionGroup(
        children: [
          UtenSelectionSummaryPill(
            key: Key('host-floating-selection'),
            count: 1,
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      page(const [
        {'status': '甲'},
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
    await tester.pumpWidget(page(const []));
    await tester.pumpAndSettle();
    expect(find.text('没有数据'), findsOneWidget);
    expect(find.text('分类筛选'), findsOneWidget);
    expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
    final summary = find.byKey(const Key('host-floating-selection'));
    expect(
      find.ancestor(
        of: summary,
        matching: find.byType(UtenFloatingActionGroup),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(MasterDataTableView<Map<String, String>>),
        matching: find.byType(UtenSelectionSummaryPill),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty table retains its selection summary when requested', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(filters: const {}, onFilterChanged: (_, _) {}, selectable: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有数据'), findsOneWidget);
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 2026-09-11 口径变更：空表不再提供「进全屏」——放大一张没有行的表毫无意义，
  // 用户反而以为数据被按钮挡住了（销售订单财务确认「待确认」空态反馈）。
  // 已在全屏中时按钮保留，那是唯一的退出口。
  testWidgets('empty state does not offer entering fullscreen', (tester) async {
    await tester.pumpWidget(
      host(
        filters: const {'status': 'x'},
        onFilterChanged: (_, _) {},
        showFullscreenToggle: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('master-table-fullscreen-toggle')),
      findsNothing,
    );
    expect(find.text('全屏'), findsNothing);
    // 其余空态出口（清除筛选）照常在。
    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsOneWidget,
    );
  });

  testWidgets('全屏中行数掉到 0 仍留「退出全屏」，不会被困住', (tester) async {
    await tester.pumpWidget(
      host(
        filters: const {'status': 'x'},
        onFilterChanged: (_, _) {},
        showFullscreenToggle: true,
        items: const [
          {'status': '甲'},
        ],
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('master-table-fullscreen-toggle'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    // 全屏中把行数换成 0：退出入口与清除筛选都必须还在。
    await tester.pumpWidget(
      host(
        filters: const {'status': 'x'},
        onFilterChanged: (_, _) {},
        showFullscreenToggle: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsOneWidget,
    );
    await tester.tap(find.text('退出全屏'));
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsNothing);
    expect(find.text('全屏'), findsNothing);
  });
}
