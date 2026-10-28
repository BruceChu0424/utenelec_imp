import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  for (final (kind, reducedMotion, lite) in [
    ('client', false, false),
    ('supplier', false, false),
    ('mould', false, false),
    ('client', true, false),
    ('supplier', false, true),
  ]) {
    final title =
        '$kind ${reducedMotion
            ? "减少动画 "
            : lite
            ? "省电 "
            : ""}搜索跨分类直接显示全局结果，翻页不截分类，清空回原分类';
    testWidgets(title, (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({
        if (lite) 'performancePreference': 'lite',
      });
      final preferences = await SharedPreferences.getInstance();
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            final path = request.path;
            Object data = <String, dynamic>{};
            if (path == '/master/$kind-categories/tree') {
              data = [_category('cat-a', '分类A'), _category('cat-b', '分类B')];
            } else if (path == '/master/${kind}s/facets') {
              data = {
                'name': [
                  {
                    'value': request.queryParameters['categoryId'] == null
                        ? '跨分类选项'
                        : '分类内选项',
                    'count': 1,
                  },
                ],
              };
            } else if (path.startsWith('/master/$kind-categories/')) {
              final id = path.split('/').last;
              data = {
                ..._category(id, id == 'cat-a' ? '分类A' : '分类B'),
                'path': '/$id/',
                'childCount': 0,
              };
            } else if (path == '/master/${kind}s' ||
                path == '/master/${kind}s/search') {
              final body = request.data;
              final keyword = body is Map
                  ? body['keyword']
                  : request.queryParameters['keyword'];
              final page =
                  (request.queryParameters['page'] as num?)?.toInt() ?? 1;
              final global =
                  request.queryParameters['categoryId'] == null &&
                  keyword != null;
              final items = global
                  ? (page == 1
                        ? [
                            _row('exact-b', '共同名称', 'cat-b'),
                            _row('near-a', '共同名称扩展', 'cat-a'),
                          ]
                        : [_row('last-b', '其他共同名称', 'cat-b')])
                  : [
                      _row(
                        request.queryParameters['categoryId'] == 'cat-b'
                            ? 'category-b'
                            : 'category-a',
                        '分类内资料',
                        request.queryParameters['categoryId'] as String? ??
                            'cat-a',
                      ),
                    ];
              data = {
                'items': items,
                'page': page,
                'size': request.queryParameters['size'] ?? 20,
                'total': global ? 21 : 1,
                'totalPages': global ? 2 : 1,
              };
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
      final page = switch (kind) {
        'client' => const ClientCategoryPage(),
        'supplier' => const SupplierCategoryPage(),
        _ => const MouldCategoryPage(),
      };
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            apiClientProvider.overrideWithValue(ApiClient(dio)),
            currentPermissionsProvider.overrideWithValue({
              '$kind:view',
              '$kind:create',
              '$kind:edit',
              '$kind:delete',
              '${kind}_category:view',
              '${kind}_category:create',
              '${kind}_category:edit',
              '${kind}_category:delete',
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: child!,
            ),
            home: page,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (kind == 'mould') {
        expect(find.text('分类A'), findsNothing);
        await tester.tap(find.byTooltip('展开全部模具'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('分类A'));
      await tester.pumpAndSettle();
      expect(_rowIds(tester), ['category-a']);
      final categoryReads = requests
          .where((r) => r.path == '/master/$kind-categories/cat-a')
          .length;
      final search = find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is UtenSearchBar && w.hint.startsWith('搜索分类/'),
        ),
        matching: find.byType(TextField),
      );
      final searchElement = tester.element(search);
      await tester.enterText(search, '共同名称');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(_rowIds(tester), ['exact-b', 'near-a']);
      expect(tester.element(search), same(searchElement));
      final globalTable = tester.widget<MasterDataTableView<dynamic>>(_table);
      expect(globalTable.facets['name']?.single.value, '跨分类选项');
      final facetRead = requests.lastWhere(
        (r) => r.path == '/master/${kind}s/facets',
      );
      expect(facetRead.queryParameters.containsKey('categoryId'), isFalse);
      expect(facetRead.queryParameters.containsKey('keyword'), isFalse);
      globalTable.onFilterChanged('name', '跨分类选项');
      await tester.pumpAndSettle();
      expect(find.text('新增子分类'), findsNothing);
      expect(
        requests
            .where((r) => r.path == '/master/$kind-categories/cat-a')
            .length,
        categoryReads,
      );
      _nextPage(tester);
      await tester.pumpAndSettle();
      expect(_rowIds(tester), ['last-b']);
      final query = requests.lastWhere(
        (r) =>
            (r.path == '/master/${kind}s' ||
                r.path == '/master/${kind}s/search') &&
            r.queryParameters['size'] == 20 &&
            r.queryParameters['page'] == 2,
      );
      expect(query.queryParameters.containsKey('categoryId'), isFalse);
      expect(query.queryParameters['name'], '跨分类选项');
      expect(
        query.data is Map
            ? (query.data as Map)['keyword']
            : query.queryParameters['keyword'],
        '共同名称',
      );
      await tester.tap(find.text('分类B'));
      await tester.pumpAndSettle();
      expect(_rowIds(tester), ['category-b']);
      final scoped = requests.lastWhere(
        (r) =>
            (r.path == '/master/${kind}s' ||
                r.path == '/master/${kind}s/search') &&
            r.queryParameters['size'] == 20,
      );
      expect(scoped.queryParameters['categoryId'], 'cat-b');
      expect(scoped.queryParameters['page'], 1);
      expect(
        scoped.data is Map
            ? (scoped.data as Map)['keyword']
            : scoped.queryParameters['keyword'],
        '共同名称',
      );
      await tester.tap(find.byTooltip('清除分类范围，搜索全部分类'));
      await tester.pumpAndSettle();
      expect(_rowIds(tester), ['exact-b', 'near-a']);
      expect(find.text('搜索范围：全部分类'), findsOneWidget);
      await tester.enterText(search, '');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(_rowIds(tester), ['category-a']);
      expect(tester.element(search), same(searchElement));
      expect(tester.takeException(), isNull);
    });
  }
}

Map<String, dynamic> _category(String id, String name) => {
  'id': id,
  'code': id,
  'name': name,
  'level': 0,
  'children': <Object>[],
  'version': 1,
};
Map<String, dynamic> _row(String id, String name, String category) => {
  'id': id,
  'name': name,
  'code': id,
  'categoryId': category,
  'status': '使用',
  'version': 1,
  'writable': true,
};
Finder get _table => find.byWidgetPredicate(
  (w) =>
      w is MasterDataTableView<ClientListItem> ||
      w is MasterDataTableView<SupplierListItem> ||
      w is MasterDataTableView<MouldListItem>,
);
List<String> _rowIds(WidgetTester tester) {
  final widget = tester.widget(_table);
  if (widget is MasterDataTableView<ClientListItem>) {
    return widget.items.map((r) => r.id).toList();
  }
  if (widget is MasterDataTableView<SupplierListItem>) {
    return widget.items.map((r) => r.id).toList();
  }
  if (widget is MasterDataTableView<MouldListItem>) {
    return widget.items.map((r) => r.id).toList();
  }
  throw StateError('Missing master table');
}

void _nextPage(WidgetTester tester) {
  final widget = tester.widget(_table);
  if (widget is MasterDataTableView<ClientListItem>) {
    widget.onPageChange!(2);
    return;
  }
  if (widget is MasterDataTableView<SupplierListItem>) {
    widget.onPageChange!(2);
    return;
  }
  if (widget is MasterDataTableView<MouldListItem>) {
    widget.onPageChange!(2);
    return;
  }
  throw StateError('Missing master table');
}
