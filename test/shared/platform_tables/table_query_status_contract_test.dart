import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/data_display/uten_doc_status_pill.dart';
import 'package:uten_imp/components/data_display/uten_status_cell_color.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import '../../support/audit_screenshot_support.dart';

class _MemoryLayout extends PlatformTableLayoutNotifier {
  _MemoryLayout(super.tableKey, this.seed);
  final PlatformTableLayout seed;
  @override
  PlatformTableLayout build() {
    super.build();
    return seed;
  }

  @override
  void persist() {}
}

class _Row extends EditableGridRow {
  _Row(this.kind);
  final String kind;
}

void main() {
  test(
    'negative and partial status text takes precedence over successful substrings',
    () {
      expect(utenStatusLabelType('未完成'), UtenStatusBadgeType.warning);
      expect(utenStatusLabelType('未通过'), UtenStatusBadgeType.danger);
      expect(utenStatusLabelType('部分已付款'), UtenStatusBadgeType.warning);
      expect(utenStatusLabelType('待验收（已确认）'), UtenStatusBadgeType.warning);
      expect(utenStatusLabelType('已通过'), UtenStatusBadgeType.success);
      expect(utenStatusLabelType('已完成'), UtenStatusBadgeType.success);
    },
  );
  test(
    'layout keeps filters and sort with the original order/visibility and no session credentials',
    () {
      const original = PlatformTableLayout(
        order: ['billNo', 'status'],
        hidden: {'remark'},
        pinned: {'billNo'},
        filters: {'billNo': 'SJ2025', 'status': 'PENDING'},
        sortColumn: 'billNo',
        sortAscending: false,
        hasQueryPreferences: true,
      );
      final value = PlatformTableLayout.fromJson(original.toJson());
      expect(value.filters, original.filters);
      expect(value.sortColumn, 'billNo');
      expect(value.sortAscending, isFalse);
      expect(value.order, original.order);
      expect(value.hidden, original.hidden);
      expect(value.pinned, original.pinned);
      expect(value.toJson().keys, isNot(contains('token')));
      expect(
        PlatformTableLayout.fromJson({
          'filters': {'field': 123, 'safe': '0'},
        }).filters,
        {'safe': '0'},
      );
    },
  );
  testWidgets(
    'persisted server filter and sort use host requests and preserve the entire matching grain',
    (tester) async {
      final requests = <Map<String, Object?>>[];
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
          platformTableLayoutProvider('r2-server-query').overrideWith(
            () => _MemoryLayout(
              'r2-server-query',
              const PlatformTableLayout(
                filters: {'kind': 'beta'},
                sortColumn: 'name',
                sortAscending: false,
                hasQueryPreferences: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: _ServerTable(requests: requests)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        requests.where(
          (request) =>
              request['kind'] == 'beta' &&
              request['sort'] == 'name' &&
              request['ascending'] == false,
        ),
        isNotEmpty,
      );
      expect(find.text('beta-4'), findsOneWidget);
      expect(find.text('beta-3'), findsOneWidget);
      expect(find.text('alpha-1'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'paged field without a server facet cannot filter the current page as if it were complete',
    (tester) async {
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<String>(
              items: const ['alpha', 'beta'],
              columns: [
                MasterColumnDef(
                  key: 'kind',
                  label: '类型',
                  width: 160,
                  value: (row) => row,
                  filterFromRows: true,
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, value) => changes++,
              totalPages: 10,
              onPageChange: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('类型'));
      await tester.pumpAndSettle();
      expect(find.text('alpha（1）'), findsNothing);
      expect(find.text('beta（1）'), findsNothing);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(changes, 0);
    },
  );
  testWidgets(
    'editable grid restores whole-row view filter while retaining all writable rows',
    (tester) async {
      final rows = UtenEditableGridController<_Row>(
        initial: [_Row('alpha'), _Row('beta')],
      );
      addTearDown(rows.dispose);
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
          platformTableLayoutProvider('r2-grid-query').overrideWith(
            () => _MemoryLayout(
              'r2-grid-query',
              const PlatformTableLayout(
                filters: {'kind': 'beta'},
                hasQueryPreferences: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  UtenEditableGrid<_Row>(
                    tableKey: 'r2-grid-query',
                    controller: rows,
                    showAddRow: false,
                    showRowDelete: false,
                    columns: [
                      EditableGridColumn(
                        key: 'kind',
                        label: '类型',
                        width: 180,
                        filterValueOf: (row) => row.kind,
                        cellBuilder: (_, row) => Text('明细-${row.kind}'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('明细-beta'), findsOneWidget);
      expect(find.text('明细-alpha'), findsNothing);
      expect(rows.rows.map((row) => row.kind), ['alpha', 'beta']);
      await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      expect(find.text('明细-alpha'), findsOneWidget);
      expect(
        container
            .read(platformTableLayoutProvider('r2-grid-query'))
            .filters
            .values
            .where((value) => value != null),
        isEmpty,
      );
    },
  );
  for (final dark in [false, true]) {
    testWidgets(
      'status cells use shared full backgrounds and readable text ${dark ? 'dark' : 'light'}',
      (tester) async {
        await loadAuditScreenshotFonts(tester);
        final boundary = GlobalKey();
        await tester.binding.setSurfaceSize(
          dark ? const Size(390, 844) : const Size(1440, 900),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: auditScreenshotTheme(
              dark ? buildDarkTheme() : buildLightTheme(),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(dark ? 1.5 : 1)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: MasterDataTableView<String>(
                  items: const ['A', 'B', 'C', 'D'],
                  columns: [
                    MasterColumnDef(
                      key: 'name',
                      label: '单据',
                      width: 160,
                      value: (row) => '单据 $row',
                    ),
                    MasterColumnDef(
                      key: 'status',
                      label: '原业务状态',
                      width: 180,
                      value: (row) => row == 'B' ? '已审' : '草稿',
                      cellBuilder: (_, row) => UtenStatusBadge(
                        label: row == 'B' ? '已审' : '草稿',
                        type: utenStatusLabelType(row == 'B' ? '已审' : '草稿'),
                      ),
                    ),
                    MasterColumnDef(
                      key: 'workflowState',
                      label: '处理状态',
                      width: 180,
                      value: (row) => _workflowStates[row],
                      cellBuilder: (_, row) => UtenDocStatusPill(
                        label: _workflowStates[row]!,
                        color: Colors.green,
                      ),
                    ),
                  ],
                  compactCards: true,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, value) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (dark) {
          for (final element in find.text('草稿').evaluate()) {
            final text = element.widget as Text;
            expect(
              text.style?.color ?? DefaultTextStyle.of(element).style.color,
              Colors.white,
              reason: '半透明暗色状态格必须按实际主题合成后选字色',
            );
          }
          for (final label in ['已审', '待核对', '已删除']) {
            final element = find.text(label).evaluate().first;
            final text = element.widget as Text;
            expect(
              text.style?.color ?? DefaultTextStyle.of(element).style.color,
              Colors.white,
            );
          }
        }
        if (!dark) {
          final badge = find.byType(UtenStatusBadge).first;
          expect(
            find.descendant(of: badge, matching: find.byType(Container)),
            findsNothing,
          );
          final context = tester.element(badge);
          final colors = find
              .ancestor(of: badge, matching: find.byType(Container))
              .evaluate()
              .map((element) => element.widget)
              .whereType<Container>()
              .map((container) => container.decoration)
              .whereType<BoxDecoration>()
              .map((decoration) => decoration.color);
          expect(
            colors,
            contains(
              udenStatusBadgeCellColor(context, UtenStatusBadgeType.neutral),
            ),
          );
        }
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(
          tester,
          boundary,
          'r2-status-${dark ? 'narrow-dark-large' : 'desktop-light'}',
        );
      },
    );
  }
}

const _workflowStates = {'A': '未提交', 'B': '已完成', 'C': '待核对', 'D': '已删除'};

class _ServerTable extends StatefulWidget {
  const _ServerTable({required this.requests});
  final List<Map<String, Object?>> requests;
  @override
  State<_ServerTable> createState() => _ServerTableState();
}

class _ServerTableState extends State<_ServerTable> {
  String? _kind, _sort;
  bool _ascending = true;
  List<String> _items = const ['alpha-1', 'alpha-2'];
  void _request() {
    widget.requests.add({
      'kind': _kind,
      'sort': _sort,
      'ascending': _ascending,
    });
    final all = [
      for (final kind in ['alpha', 'beta'])
        for (var index = 1; index <= 4; index++) '$kind-$index',
    ];
    final result =
        all.where((row) => _kind == null || row.startsWith(_kind!)).toList()
          ..sort();
    setState(
      () => _items = (_ascending ? result : result.reversed).take(2).toList(),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: MasterDataTableView<String>(
      tableKey: 'r2-server-query',
      items: _items,
      columns: [
        MasterColumnDef(
          key: 'name',
          label: '单据',
          width: 180,
          value: (row) => row,
          sortable: true,
        ),
        MasterColumnDef(
          key: 'kind',
          label: '类型',
          width: 160,
          value: (row) => row.split('-').first,
        ),
      ],
      facets: const {
        'kind': [
          MasterFacetBucket(value: 'alpha', count: 4),
          MasterFacetBucket(value: 'beta', count: 4),
        ],
      },
      nullCounts: const {},
      filters: {'kind': _kind},
      totalPages: 2,
      onPageChange: (_) {},
      onFilterChanged: (_, value) {
        _kind = value;
        _request();
      },
      sortColumn: _sort,
      sortAscending: _ascending,
      onSortChange: (column, ascending) {
        _sort = column;
        _ascending = ascending;
        _request();
      },
    ),
  );
}
