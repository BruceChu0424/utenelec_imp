import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/goods_detail_page.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/party_detail_page.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _grants = StateProvider<Set<String>>((ref) => {});
const _cases =
    <
      ({
        String kind,
        String permission,
        String categoryPermission,
        String label,
      })
    >[
      (
        kind: 'goods',
        permission: Perm.goodsView,
        categoryPermission: Perm.materialCategoryView,
        label: '许可货品',
      ),
      (
        kind: 'clients',
        permission: Perm.clientView,
        categoryPermission: Perm.clientCategoryView,
        label: '许可客户',
      ),
      (
        kind: 'suppliers',
        permission: Perm.supplierView,
        categoryPermission: Perm.supplierCategoryView,
        label: '许可供应商',
      ),
      (
        kind: 'moulds',
        permission: Perm.mouldView,
        categoryPermission: Perm.mouldCategoryView,
        label: '许可模具',
      ),
    ];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final scenario in _cases) {
    for (final size in [const Size(1500, 1000), const Size(375, 1000)]) {
      testWidgets(
        '${scenario.kind} only view supports list, search and detail at $size without category reads',
        (tester) async {
          final api = _ReadApi();
          await _pump(tester, scenario.kind, {scenario.permission}, api, size);
          expect(find.text(scenario.label), findsWidgets);
          if (scenario.kind == 'goods') {
            final goodsReads = api.reads.where(
              (read) => read.path == '/master/goods',
            );
            expect(goodsReads, isNotEmpty);
            expect(
              goodsReads.every((read) => read.query['excludeDisabled'] != true),
              isTrue,
            );
          }
          expect(find.byType(UtenCategoryTreeView), findsNothing);
          expect(find.byKey(const ValueKey('category-add-root')), findsNothing);
          final search = find.byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.hintText == '搜索名称或编号',
          );
          expect(search, findsOneWidget);
          await tester.enterText(search, '许可');
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          final queries = api.reads.where(
            (read) =>
                read.path == '/master/${scenario.kind}' ||
                read.path == '/master/${scenario.kind}/search',
          );
          expect(queries, isNotEmpty);
          expect(
            queries.last.query['keyword'] ?? queries.last.body['keyword'],
            '许可',
          );
          expect(
            queries.every((read) => !read.query.containsKey('categoryId')),
            isTrue,
          );
          _openFirst(tester, scenario.kind);
          await tester.pumpAndSettle();
          expect(
            api.reads.any(
              (read) =>
                  read.path == '/master/${scenario.kind}/${scenario.kind}-1',
            ),
            isTrue,
          );
          expect(find.text(scenario.label), findsWidgets);
          expect(api.categoryReads, isEmpty);
          expect(api.writes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'category authority A-B-A ignores an old tree response and returns to the global entity list on revoke',
    (tester) async {
      final api = _ReadApi();
      await _pump(
        tester,
        'goods',
        {Perm.goodsView},
        api,
        const Size(1500, 1000),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductCategoryPage)),
      );
      final oldTree = Completer<List<Map<String, dynamic>>>();
      api.pendingTree = oldTree;
      container.read(_grants.notifier).state = {
        Perm.goodsView,
        Perm.materialCategoryView,
      };
      await tester.pump();
      await tester.pump();
      expect(api.categoryReads, hasLength(1));
      container.read(_grants.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      expect(find.text('许可货品'), findsWidgets);
      container.read(_grants.notifier).state = {
        Perm.goodsView,
        Perm.materialCategoryView,
      };
      await tester.pumpAndSettle();
      expect(find.text('当前分类'), findsWidgets);
      oldTree.complete([
        {
          'id': 'old-category',
          'name': '过期分类',
          'code': 'OLD',
          'children': <Object>[],
        },
      ]);
      await tester.pumpAndSettle();
      expect(find.text('过期分类'), findsNothing);
      expect(find.text('当前分类'), findsWidgets);
      container.read(_grants.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      expect(find.byType(UtenCategoryTreeView), findsNothing);
      expect(find.text('许可货品'), findsWidgets);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  String kind,
  Set<String> grants,
  _ReadApi api,
  Size size,
) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final preferences = await SharedPreferences.getInstance();
  final baseRoute = switch (kind) {
    'clients' => '/basicinfo/client',
    'suppliers' => '/basicinfo/supplier',
    'moulds' => '/basicinfo/mould',
    _ => '/basicinfo/goods',
  };
  final router = GoRouter(
    initialLocation: baseRoute,
    routes: [
      GoRoute(
        path: baseRoute,
        builder: (_, _) => switch (kind) {
          'goods' => const ProductCategoryPage(),
          'clients' => const ClientCategoryPage(),
          'suppliers' => const SupplierCategoryPage(),
          _ => const MouldCategoryPage(),
        },
      ),
      GoRoute(
        path: '/basicinfo/goods/:id',
        builder: (_, state) =>
            GoodsDetailPage(goodsId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/basicinfo/client/:id',
        builder: (_, state) => PartyDetailPage(
          partyType: 'client',
          id: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/basicinfo/supplier/:id',
        builder: (_, state) => PartyDetailPage(
          partyType: 'supplier',
          id: state.pathParameters['id']!,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(api),
        _grants.overrideWith((ref) => grants),
        currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _openFirst(WidgetTester tester, String kind) {
  switch (kind) {
    case 'goods':
      final table = tester.widget<MasterDataTableView<GoodsListItem>>(
        find.byType(MasterDataTableView<GoodsListItem>),
      );
      table.onRowTap!(table.items.first);
    case 'clients':
      final table = tester.widget<MasterDataTableView<ClientListItem>>(
        find.byType(MasterDataTableView<ClientListItem>),
      );
      table.onRowTap!(table.items.first);
    case 'suppliers':
      final table = tester.widget<MasterDataTableView<SupplierListItem>>(
        find.byType(MasterDataTableView<SupplierListItem>),
      );
      table.onRowTap!(table.items.first);
    default:
      final table = tester.widget<MasterDataTableView<MouldListItem>>(
        find.byType(MasterDataTableView<MouldListItem>),
      );
      table.onRowTap!(table.items.first);
  }
}

class _ReadApi extends ApiClient {
  _ReadApi() : super(Dio());
  final reads =
      <
        ({String path, Map<String, dynamic> query, Map<String, dynamic> body})
      >[];
  final categoryReads = <String>[];
  final writes = <String>[];
  Completer<List<Map<String, dynamic>>>? pendingTree;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add((path: path, query: Map.of(query ?? {}), body: {}));
    if (path.contains('categories')) categoryReads.add(path);
    if (path.endsWith('/facets')) {
      return {'fields': <String, dynamic>{}, 'nullCounts': <String, dynamic>{}};
    }
    for (final scenario in _cases) {
      final base = '/master/${scenario.kind}';
      final row = <String, dynamic>{
        'id': '${scenario.kind}-1',
        'code': 'READ-001',
        'name': scenario.label,
        'status': '使用',
        'categoryId': 'visible-row-category',
        'categoryName': '本行分类',
        'sourceType': '自制',
        'version': 1,
        'writable': false,
      };
      if (path == base) {
        return {
          'items': [row],
          'page': 1,
          'size': 20,
          'total': 1,
          'totalPages': 1,
        };
      }
      if (path == '$base/${scenario.kind}-1') return row;
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add((path: path, query: Map.of(query ?? {}), body: {}));
    if (path.contains('categories')) {
      categoryReads.add(path);
      final pending = pendingTree;
      pendingTree = null;
      if (pending != null) return pending.future;
      return [
        {
          'id': 'current-category',
          'name': '当前分类',
          'code': 'CURRENT',
          'children': <Object>[],
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/search')) {
      reads.add((
        path: path,
        query: Map.of(query ?? {}),
        body: Map<String, dynamic>.from(body! as Map),
      ));
      final scenario = _cases.firstWhere(
        (item) => path == '/master/${item.kind}/search',
      );
      return {
        'items': [
          {
            'id': '${scenario.kind}-1',
            'code': 'READ-001',
            'name': scenario.label,
            'status': '使用',
            'categoryId': 'visible-row-category',
            'version': 1,
            'writable': false,
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    writes.add(path);
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes.add(path);
    return {};
  }
}
