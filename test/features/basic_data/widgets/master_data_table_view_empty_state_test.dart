import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

/// 2026-09-10（F2a-flow / F2b）：成功空态必须保留「退出全屏」、
/// `toolbarLeadingActions`，并在有激活表头筛选时报「当前有 N 个表头筛选生效」
/// ——列头筛选控件随表头一起不渲染，提示用户表为何为空。
/// 2026-09-28 用户口径：空态「清除筛选」按钮全站退役（表外分段条等入口承担
/// 清除），本文件同步锁住「永不出按钮」。
void main() {
  Widget host({
    required Map<String, String?> filters,
    required void Function(String key, String? value) onFilterChanged,
    bool showFullscreenToggle = false,
    bool embedded = true,
    bool selectable = false,
    bool showSelectionSummary = true,
    bool compactCards = false,
    bool isLoading = false,
    String? error,
    VoidCallback? onRetry,
    Set<String> selectedIds = const {},
    Widget? floatingActionButton,
    Widget? scrollingHeader,
    List<Widget>? leading,
    List<Widget>? actions,
    List<MasterDataGroup<Map<String, String>>>? groups,
    List<Map<String, String>> items = const [],
  }) => MaterialApp(
    home: Scaffold(
      floatingActionButton: floatingActionButton,
      body: SizedBox(
        width: compactCards ? 400 : 900,
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
          scrollingHeader: scrollingHeader,
          compactCards: compactCards,
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
          emptyMessage: '没有数据',
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
          compactCards: true,
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
    for (final compactCards in [false, true]) {
      testWidgets(
        'add-column follows visible rows while business actions survive empty state: embedded=$embedded cards=$compactCards',
        (tester) async {
          var created = 0;
          Widget page(List<Map<String, String>> rows) => host(
            filters: const {'status': 'x'},
            onFilterChanged: (_, _) {},
            embedded: embedded,
            compactCards: compactCards,
            items: rows,
            leading: const [Text('分类筛选')],
            actions: [
              TextButton(onPressed: () => created++, child: const Text('新建')),
            ],
          );
          final addColumn = find.byKey(const Key('platform-table-add-column'));
          await tester.pumpWidget(page(const []));
          await tester.pumpAndSettle();
          expect(find.text('没有数据'), findsOneWidget);
          expect(addColumn, findsNothing);
          expect(find.byTooltip('添加列'), findsNothing);
          expect(find.text('分类筛选'), findsOneWidget);
          await tester.tap(find.text('新建'));
          expect(created, 1);

          await tester.pumpWidget(
            page(const [
              {'status': '甲'},
            ]),
          );
          await tester.pumpAndSettle();
          expect(addColumn, findsOneWidget);

          await tester.pumpWidget(page(const []));
          await tester.pumpAndSettle();
          expect(addColumn, findsNothing);
          expect(find.text('新建'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'loading and failed placeholders never offer add-column; retry remains usable',
    (tester) async {
      await tester.pumpWidget(
        host(filters: const {}, onFilterChanged: (_, _) {}, isLoading: true),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip('添加列'), findsNothing);
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
      expect(find.byTooltip('添加列'), findsNothing);
      await tester.tap(find.text('重试'));
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty table keeps the shared scrolling filters and create action',
    (tester) async {
      await tester.pumpWidget(
        host(
          filters: const {},
          onFilterChanged: (_, _) {},
          embedded: false,
          scrollingHeader: const Text('共用筛选与新建入口'),
          leading: const [Text('表格操作')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('共用筛选与新建入口'), findsOneWidget);
      expect(find.text('表格操作'), findsOneWidget);
      expect(find.text('没有数据'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
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
    // 清除筛选按钮已退役（2026-09-28），空态不再出现。
    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsNothing,
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
    // 全屏中把行数换成 0：退出入口必须还在（清除筛选已退役）。
    await tester.pumpWidget(
      host(
        filters: const {'status': 'x'},
        onFilterChanged: (_, _) {},
        showFullscreenToggle: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);
    expect(find.byTooltip('添加列'), findsNothing);
    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsNothing,
    );
    await tester.tap(find.text('退出全屏'));
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsNothing);
    expect(find.text('全屏'), findsNothing);
  });
}
