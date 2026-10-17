import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/drafts/form_draft_category_table.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _tableKey = 'column-search-review';
typedef _Row = (String, String, String);
const _rows = <_Row>[
  ('A1', '三联单控开关', '白色'),
  ('B1', '电视插座', '白色'),
  ('B2', '电视插座', '灰色'),
];

class _Layout extends PlatformTableLayoutNotifier {
  _Layout([this.seed = const PlatformTableLayout()]) : super(_tableKey);
  _Layout.forTable(super.tableKey, [this.seed = const PlatformTableLayout()]);
  final PlatformTableLayout seed;
  @override
  PlatformTableLayout build() {
    super.build();
    return seed;
  }

  @override
  void persist() {}

  void replaceQuery(PlatformTableLayout value) => state = value;
}

Widget _tableHost(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    home: Scaffold(
      body: MasterDataTableView<_Row>(
        tableKey: _tableKey,
        columns: [
          MasterColumnDef(
            key: 'code',
            label: '编号',
            width: 110,
            value: (r) => r.$1,
          ),
          MasterColumnDef(
            key: 'name',
            label: '货品名称',
            width: 240,
            filterFromRows: true,
            value: (r) => r.$2,
          ),
          MasterColumnDef(
            key: 'color',
            label: '颜色',
            width: 140,
            filterFromRows: true,
            value: (r) => r.$3,
          ),
        ],
        items: _rows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
      ),
    ),
  ),
);

class _Drafts extends FormDraftsNotifier {
  @override
  List<FormDraft> build() => [
    for (final id in ['keep', 'other'])
      FormDraft(
        id: id,
        title: '本机草稿',
        module: BadgeModule.sales,
        route: '/sales/orders/new',
        permission: 'sales_order:create',
        draftKind: 'salesOrder',
        updatedAt: DateTime(2026, 10, 17),
        data: {
          'text': {'remark': id == 'keep' ? '保留资料' : '别的内容'},
        },
      ),
  ];
}

void main() {
  testWidgets(
    'a new table without preferences drops old local filters and sort only',
    (tester) async {
      const firstKey = 'local-query-owner-a';
      const secondKey = 'local-query-owner-b';
      var activeKey = firstKey;
      late StateSetter updateHost;
      final changes = <(String, String?)>[];
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
          platformTableLayoutProvider(firstKey).overrideWith(
            () => _Layout.forTable(
              firstKey,
              const PlatformTableLayout(
                hasQueryPreferences: true,
                filters: {'search.name': '电视', 'color': '白色'},
                sortColumn: 'code',
                sortAscending: false,
              ),
            ),
          ),
          platformTableLayoutProvider(
            secondKey,
          ).overrideWith(() => _Layout.forTable(secondKey)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) {
                  updateHost = update;
                  return MasterDataTableView<_Row>(
                    tableKey: activeKey,
                    columns: [
                      MasterColumnDef(
                        key: 'code',
                        label: '编号',
                        width: 110,
                        sortable: true,
                        value: (r) => r.$1,
                      ),
                      MasterColumnDef(
                        key: 'name',
                        label: '货品名称',
                        width: 240,
                        filterFromRows: true,
                        value: (r) => r.$2,
                      ),
                      MasterColumnDef(
                        key: 'color',
                        label: '颜色',
                        width: 140,
                        filterFromRows: true,
                        value: (r) => r.$3,
                      ),
                    ],
                    items: _rows,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (key, value) => changes.add((key, value)),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('B1'), findsOneWidget);
      expect(find.text('A1'), findsNothing);
      expect(find.text('B2'), findsNothing);
      updateHost(() => activeKey = secondKey);
      await tester.pumpAndSettle();
      for (final id in ['A1', 'B1', 'B2']) {
        expect(find.text(id), findsOneWidget);
      }
      expect(
        tester.getTopLeft(find.text('A1')).dy,
        lessThan(tester.getTopLeft(find.text('B1')).dy),
      );
      expect(
        tester.getTopLeft(find.text('B1')).dy,
        lessThan(tester.getTopLeft(find.text('B2')).dy),
      );
      expect(changes, isEmpty);
      updateHost(() => activeKey = firstKey);
      await tester.pumpAndSettle();
      expect(find.text('B1'), findsOneWidget);
      expect(find.text('A1'), findsNothing);
      expect(find.text('B2'), findsNothing);
      expect(changes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'query presence belongs to its table across ABA and inactive responses',
    (tester) async {
      const firstKey = 'query-owner-a';
      const secondKey = 'query-owner-b';
      var activeKey = firstKey;
      String? kind = 'A-default';
      late StateSetter updateHost;
      final changes = <(String, String, String?)>[];
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
          platformTableLayoutProvider(firstKey).overrideWith(
            () => _Layout.forTable(
              firstKey,
              const PlatformTableLayout(
                hasQueryPreferences: true,
                filters: {'kind': 'A-stored'},
              ),
            ),
          ),
          platformTableLayoutProvider(
            secondKey,
          ).overrideWith(() => _Layout.forTable(secondKey)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) {
                  updateHost = update;
                  return MasterDataTableView<String>(
                    tableKey: activeKey,
                    columns: [
                      MasterColumnDef(
                        key: 'kind',
                        label: '类别',
                        width: 140,
                        value: (_) => kind,
                      ),
                    ],
                    items: const ['row'],
                    facets: const {
                      'kind': [
                        MasterFacetBucket(value: 'A-stored', count: 1),
                        MasterFacetBucket(value: 'A-late', count: 1),
                        MasterFacetBucket(value: 'B-default', count: 1),
                      ],
                    },
                    nullCounts: const {},
                    filters: {'kind': kind},
                    onPageChange: (_) {},
                    onFilterChanged: (key, value) {
                      changes.add((activeKey, key, value));
                      update(() => kind = value);
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(kind, 'A-stored');
      expect(changes, [(firstKey, 'kind', 'A-stored')]);
      changes.clear();
      final oldResponse = Completer<PlatformTableLayout>();
      final firstLayout =
          container.read(platformTableLayoutProvider(firstKey).notifier)
              as _Layout;
      unawaited(oldResponse.future.then(firstLayout.replaceQuery));
      updateHost(() {
        activeKey = secondKey;
        kind = 'B-default';
      });
      await tester.pumpAndSettle();
      expect(kind, 'B-default');
      expect(changes, isEmpty);
      oldResponse.complete(
        const PlatformTableLayout(
          hasQueryPreferences: true,
          filters: {'kind': 'A-late'},
        ),
      );
      await tester.pumpAndSettle();
      expect(kind, 'B-default');
      expect(changes, isEmpty);
      updateHost(() {
        activeKey = firstKey;
        kind = 'A-default';
      });
      await tester.pumpAndSettle();
      expect(kind, 'A-late');
      expect(changes, [(firstKey, 'kind', 'A-late')]);
      firstLayout.replaceQuery(const PlatformTableLayout());
      await tester.pumpAndSettle();
      expect(kind, isNull);
      expect(changes.last, (firstKey, 'kind', null));
      expect(changes.where((change) => change.$1 == secondKey), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dynamic columns without stored query preferences retain controlled filters',
    (tester) async {
      final changes = <(String, String?)>[];
      var direction = 'AR';
      String? settled = 'false';
      late StateSetter updateHost;
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
          platformTableLayoutProvider(_tableKey).overrideWith(() => _Layout()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) {
                  updateHost = update;
                  return MasterDataTableView<String>(
                    tableKey: _tableKey,
                    columns: [
                      MasterColumnDef(
                        key: 'direction',
                        label: '方向',
                        width: 100,
                        value: (_) => direction,
                      ),
                      MasterColumnDef(
                        key: 'settled',
                        label: '状态',
                        width: 100,
                        value: (_) => settled,
                      ),
                      if (direction != 'AP')
                        MasterColumnDef(
                          key: 'salesOrderNos',
                          label: '销售订单号',
                          width: 160,
                          value: (_) => 'SO-1',
                        ),
                    ],
                    items: const ['row'],
                    facets: const {
                      'direction': [
                        MasterFacetBucket(value: 'AR', count: 1),
                        MasterFacetBucket(value: 'AP', count: 1),
                      ],
                      'settled': [MasterFacetBucket(value: 'false', count: 1)],
                    },
                    nullCounts: const {},
                    filters: {'direction': direction, 'settled': settled},
                    onPageChange: (_) {},
                    onFilterChanged: (key, value) {
                      changes.add((key, value));
                      update(() {
                        if (key == 'direction') direction = value ?? 'ALL';
                        if (key == 'settled') settled = value;
                      });
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final next in ['AP', 'AR', 'AP']) {
        updateHost(() => direction = next);
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<String>>(
          find.byType(MasterDataTableView<String>),
        );
        expect(table.filters, {'direction': next, 'settled': 'false'});
        expect(
          table.columns.any((column) => column.key == 'salesOrderNos'),
          next != 'AP',
        );
        expect(changes, isEmpty);
        expect(
          container
              .read(platformTableLayoutProvider(_tableKey))
              .hasQueryPreferences,
          isFalse,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final server in [false, true]) {
    testWidgets(
      'old status/date keywords are discarded in ${server ? 'server' : 'local'} tables',
      (tester) async {
        final changes = <(String, String?)>[];
        final container = ProviderContainer(
          overrides: [
            authenticatedScopeProvider.overrideWithValue(null),
            apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
            platformTableLayoutProvider(_tableKey).overrideWith(
              () => _Layout(
                const PlatformTableLayout(
                  hasQueryPreferences: true,
                  filters: {'search.status': '不应恢复', 'search.date': '2099'},
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
                body: MasterDataTableView<_Row>(
                  tableKey: _tableKey,
                  columns: [
                    MasterColumnDef(
                      key: 'code',
                      label: '编号',
                      width: 100,
                      value: (r) => r.$1,
                    ),
                    MasterColumnDef(
                      key: 'name',
                      label: '货品名称',
                      width: 200,
                      value: (r) => r.$2,
                    ),
                    MasterColumnDef(
                      key: 'status',
                      label: '状态',
                      width: 100,
                      value: (_) => '已完成',
                    ),
                    MasterColumnDef(
                      key: 'date',
                      label: '日期',
                      type: 'date',
                      width: 140,
                      value: (_) => '2026-10-17',
                    ),
                  ],
                  items: _rows,
                  facets: const {},
                  nullCounts: const {},
                  filters: server
                      ? const {'search.status': '不应恢复', 'search.date': '2099'}
                      : const {},
                  serverColumnSearch: server,
                  onPageChange: server ? (_) async {} : null,
                  onFilterChanged: (key, value) => changes.add((key, value)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('A1'), findsOneWidget);
        expect(find.text('B1'), findsOneWidget);
        expect(find.text('B2'), findsOneWidget);
        expect(changes.where((change) => change.$2 != null), isEmpty);
        if (server) {
          expect(
            changes,
            containsAll([('search.status', null), ('search.date', null)]),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'keyword search stays reachable in a narrow dark window with enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(375, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: MasterDataTableView<_Row>(
              columns: [
                MasterColumnDef(
                  key: 'name',
                  label: '货品名称',
                  width: 290,
                  value: (r) => r.$2,
                ),
              ],
              items: _rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('货品名称'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '电视',
      );
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('uten-column-keyword-input')), findsNothing);
      expect(find.text('货品名称：电视'), findsOneWidget);
      expect(find.text('三联单控开关'), findsNothing);
      expect(find.text('电视插座'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-column keyword replaces exact choice, keeps other choices and survives remount',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
          platformTableLayoutProvider(_tableKey).overrideWith(_Layout.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_tableHost(container));
      await tester.pumpAndSettle();
      await tester.tap(find.text('颜色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('白色 (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('货品名称'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('三联单控开关 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('A1'), findsOneWidget);
      expect(find.text('B1'), findsNothing);
      await tester.tap(find.text('三联单控开关').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '电视',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('A1'), findsNothing);
      expect(find.text('B1'), findsOneWidget);
      expect(find.text('B2'), findsNothing);
      expect(container.read(platformTableLayoutProvider(_tableKey)).filters, {
        'search.name': '电视',
        'color': '白色',
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SizedBox(),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(_tableHost(container));
      await tester.pumpAndSettle();
      expect(find.text('B1'), findsOneWidget);
      expect(find.text('A1'), findsNothing);
      expect(find.text('B2'), findsNothing);
      expect(find.text('货品名称：电视'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'draft wrapper forwards server keyword mode and column overrides, matching local draft display values',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [formDraftsProvider.overrideWith(_Drafts.new)],
          child: MaterialApp(
            home: Scaffold(
              body: FormDraftCategoryTable<String>(
                scope: const FormDraftCategoryScope(kind: 'salesOrder'),
                table: MasterDataTableView<String>(
                  columns: [
                    MasterColumnDef(
                      key: 'remark',
                      label: '备注',
                      width: 240,
                      columnSearchEnabled: true,
                      value: (r) => r,
                    ),
                    MasterColumnDef(
                      key: 'status',
                      label: '状态',
                      width: 160,
                      columnSearchEnabled: false,
                      value: (_) => '草稿',
                    ),
                  ],
                  items: const ['server-row'],
                  idOf: (r) => r,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {'search.remark': '保留'},
                  serverColumnSearch: true,
                  onFilterChanged: (_, _) {},
                  onPageChange: (_) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final wrapped = tester
          .widget<MasterDataTableView<FormDraftCategoryRow<String>>>(
            find.byType(MasterDataTableView<FormDraftCategoryRow<String>>),
          );
      expect(wrapped.serverColumnSearch, isTrue);
      expect(wrapped.columns[0].columnSearchEnabled, isTrue);
      expect(wrapped.columns[1].columnSearchEnabled, isFalse);
      expect(wrapped.items.single.record, 'server-row');
      expect(wrapped.unpagedItems.map((row) => row.draft?.id), ['keep']);
      expect(tester.takeException(), isNull);
    },
  );
}
