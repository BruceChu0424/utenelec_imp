import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

/// 2026-10-09 用户口径「搜索无结果/加载/错误时表格骨架也要在，页面不许跳」：
/// 组件统一渲染同一张表（工具条+表头+列），只有行区内容随状态变——
/// 空结果行区显示 emptyMessage（含表头筛选生效数描述）、加载显示转圈、
/// 错误显示重试；业务动作与前缀按钮任何状态都在；主行为空但有前导分组时
/// 先渲染紧凑「无符合…」提示条、后跟分组行（「类似人员」两段式）。
/// 2026-09-28 口径维持：空态不出「清除筛选」按钮。
void main() {
  Widget host({
    required Map<String, String?> filters,
    required void Function(String key, String? value) onFilterChanged,
    bool showFullscreenToggle = false,
    bool embedded = true,
    bool selectable = false,
    bool showSelectionSummary = true,
    bool isLoading = false,
    String? error,
    VoidCallback? onRetry,
    Set<String> selectedIds = const {},
    Widget? floatingActionButton,
    List<Widget>? leading,
    List<Widget>? actions,
    List<MasterDataGroup<Map<String, String>>>? groups,
    String emptyMessage = '没有数据',
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
          isLoading: isLoading,
          error: error,
          onRetry: onRetry,
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
          toolbarActions: actions,
          leadingGroups: groups,
          emptyMessage: emptyMessage,
        ),
      ),
    ),
  );

  testWidgets(
    'compact group placeholder keeps its real table instead of a lone add-column action',
    (tester) async {
      await tester.pumpWidget(
        host(
          filters: const {},
          onFilterChanged: (_, _) {},
          groups: [
            MasterDataGroup(
              id: 'archived',
              title: '历史分组',
              items: const [],
              onExpand: () {},
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('状态'), findsOneWidget);
      expect(find.text('历史分组'), findsOneWidget);
      expect(
        find.byKey(const Key('platform-table-add-column')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final embedded in [false, true]) {
    testWidgets(
      'empty state keeps the table skeleton with business actions: embedded=$embedded',
      (tester) async {
        var created = 0;
        Widget page(List<Map<String, String>> rows) => host(
          filters: const {},
          onFilterChanged: (_, _) {},
          embedded: embedded,
          items: rows,
          leading: const [Text('分类筛选')],
          actions: [
            TextButton(onPressed: () => created++, child: const Text('新建')),
          ],
        );
        final addColumn = find.byKey(const Key('platform-table-add-column'));
        // 空结果：表头 + 提示 + 业务动作都在，页面骨架不换。
        await tester.pumpWidget(page(const []));
        await tester.pumpAndSettle();
        expect(find.text('没有数据'), findsOneWidget);
        expect(find.text('状态'), findsOneWidget);
        expect(find.text('分类筛选'), findsOneWidget);
        expect(find.text('新建'), findsOneWidget);
        await tester.tap(find.text('新建'));
        expect(created, 1);

        await tester.pumpWidget(
          page(const [
            {'status': '甲'},
          ]),
        );
        await tester.pumpAndSettle();
        expect(addColumn, findsOneWidget);
        expect(find.text('甲'), findsOneWidget);

        // 再回空结果：骨架仍在，动作仍可点。
        await tester.pumpWidget(page(const []));
        await tester.pumpAndSettle();
        expect(find.text('甲'), findsNothing);
        expect(find.text('状态'), findsOneWidget);
        expect(find.text('没有数据'), findsOneWidget);
        await tester.tap(find.text('新建'));
        expect(created, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'loading keeps the skeleton and renders the spinner in the rows area',
    (tester) async {
      await tester.pumpWidget(
        host(filters: const {}, onFilterChanged: (_, _) {}, isLoading: true),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // 骨架（表头）仍在，不再整块换转圈占位。
      expect(find.text('状态'), findsOneWidget);
      var retries = 0;
      await tester.pumpWidget(
        host(
          filters: const {},
          onFilterChanged: (_, _) {},
          error: '加载失败',
          onRetry: () => retries++,
        ),
      );
      await tester.pumpAndSettle();
      // 错误也保留骨架，行区显示重试。
      expect(find.text('状态'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty state with an active filter reports the count, no clear button',
    (tester) async {
      await tester.pumpWidget(
        host(
          filters: const {'status': 'x', 'other': null, 'blank': ''},
          onFilterChanged: (_, _) {},
          leading: const [Text('视图切换')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('没有数据'), findsOneWidget);
      // 只数有值的列（空串/null 不算激活筛选）。
      expect(find.text('当前有 1 个表头筛选生效'), findsOneWidget);
      expect(find.text('视图切换'), findsOneWidget);
      // 2026-09-28 口径：清除筛选按钮全站退役。
      expect(
        find.byKey(const ValueKey('master-table-clear-filters')),
        findsNothing,
      );
      expect(find.text('清除筛选'), findsNothing);
    },
  );

  testWidgets('empty state without an active filter has no filter note', (
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

  // 2026-10-09 统一骨架口径：工具条（含「全屏」）在任何状态都渲染同一结构——
  // 空表也有全屏入口（例如放大查看「类似人员」分组），不再按空态隐藏。
  testWidgets('empty state keeps the fullscreen toggle in the stable toolbar', (
    tester,
  ) async {
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
    // 全屏中把行数换成 0：骨架与退出入口都还在。
    await tester.pumpWidget(
      host(
        filters: const {'status': 'x'},
        onFilterChanged: (_, _) {},
        showFullscreenToggle: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);
    expect(find.text('没有数据'), findsOneWidget);
    await tester.tap(find.text('退出全屏'));
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsNothing);
    expect(find.text('全屏'), findsOneWidget);
  });

  // 「无符合人员 / 类似人员」两段式（2026-10-09）：主行为空但有前导分组时，
  // 行区先渲染紧凑「无符合…」提示条，后跟分组标题行与分组行。
  testWidgets(
    'empty main rows with a leading group render notice then group rows',
    (tester) async {
      await tester.pumpWidget(
        host(
          filters: const {},
          onFilterChanged: (_, _) {},
          groups: [
            const MasterDataGroup(
              id: 'similar',
              title: '类似人员（2）',
              subtitle: '没有精确匹配，按相似度推荐',
              items: [
                {'status': '李晓明'},
                {'status': '李小红'},
              ],
              initiallyExpanded: true,
            ),
          ],
          emptyMessage: '无符合「李小明」的员工',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('无符合「李小明」的员工'), findsOneWidget);
      expect(find.text('类似人员（2）'), findsOneWidget);
      // initiallyExpanded：分组行直接展开可见，不需要再点一下。
      expect(find.text('李晓明'), findsOneWidget);
      expect(find.text('李小红'), findsOneWidget);
      expect(find.text('状态'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
