import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _MemoryLayout extends PlatformTableLayoutNotifier {
  _MemoryLayout(super.tableKey);

  @override
  PlatformTableLayout build() {
    super.build();
    return const PlatformTableLayout(
      order: ['color', 'name'],
      widths: {'name': 280},
      pinned: {'color'},
      filters: {'search.name': '旧搜索'},
      sortColumn: 'name',
      sortAscending: false,
      hasQueryPreferences: true,
    );
  }

  @override
  void persist() {}

  void arrive(PlatformTableLayout value) => state = value;
}

void main() {
  test('keywords survive canonical aliases and discard unknown columns', () {
    final controller = PlatformTableController<String>();
    addTearDown(controller.dispose);
    controller.binding = PlatformTableBinding<String>(
      tableKey: 'test',
      scope: 'test',
      recordIdOf: (r) => r,
      columnAliases: const {'goodsName': 'name'},
    );
    controller.saveQuery(
      filters: {
        'search.goodsName': '开关',
        'goodsName': '单联开关',
        'search.removed': 'old',
      },
    );
    expect(controller.layout.filters['search.name'], '开关');
    final restored = controller.localLayout(['goodsName'], defaultHidden: {});
    expect(restored.filters, {'search.goodsName': '开关', 'goodsName': '单联开关'});
  });

  testWidgets(
    'query belongs to one table instance while shared and late layout preferences survive',
    (tester) async {
      const key = 'page-local-table-query';
      final first = PlatformTableController<String>();
      final second = PlatformTableController<String>();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
          platformTableLayoutProvider(
            key,
          ).overrideWith(() => _MemoryLayout(key)),
        ],
      );
      addTearDown(container.dispose);
      late BuildContext host;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                host = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      void configure(PlatformTableController<String> controller) =>
          controller.configure(
            host,
            descriptor: const PlatformTableDescriptor<String>(
              kind: 'master',
              tableKey: key,
              columnKeys: ['name', 'color'],
              rows: ['row'],
            ),
          );
      configure(first);
      expect(first.layout.filters, isEmpty);
      first.saveQuery(
        filters: const {'search.name': '开关', 'color': '白色'},
        sortColumn: 'name',
        sortAscending: false,
      );
      configure(first);
      expect(first.layout.filters, {'search.name': '开关', 'color': '白色'});
      expect(container.read(platformTableLayoutProvider(key)).filters, isEmpty);
      configure(second);
      expect(second.layout.filters, isEmpty);
      second.saveQuery(
        filters: const {'search.name': '插座'},
        sortColumn: 'color',
      );
      expect(first.layout.filters['search.name'], '开关');
      expect(first.layout.sortColumn, 'color');
      (container.read(platformTableLayoutProvider(key).notifier)
              as _MemoryLayout)
          .arrive(
            const PlatformTableLayout(
              order: ['name', 'color'],
              widths: {'name': 310},
              filters: {'search.name': '迟到搜索'},
              sortColumn: 'name',
              sortAscending: false,
              hasQueryPreferences: true,
            ),
          );
      expect(first.layout.filters['search.name'], '开关');
      expect(first.layout.widths['name'], 310);
      final lifecycle = first.queryLifecycle;
      first.clearSessionQuery();
      expect(first.queryLifecycle, greaterThan(lifecycle));
      expect(first.hasSessionQueryPreferences, isFalse);
      expect(first.layout.filters, isEmpty);
      expect(first.layout.sortColumn, 'name');
      expect(first.layout.sortAscending, isFalse);
      expect(first.layout.widths['name'], 310);
      expect(second.layout.filters['search.name'], '插座');
      expect(first.layout.toJson().containsKey('filters'), isFalse);
    },
  );
}
