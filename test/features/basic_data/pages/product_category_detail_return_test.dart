import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/goods_detail_page.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Categories extends Fake implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'cat',
      code: 'CAT',
      name: '测试分类',
      level: 0,
      children: const [],
    ),
  ];

  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      const ProductCategoryDetail(
        id: 'cat',
        code: 'CAT',
        name: '测试分类',
        level: 0,
        path: '/cat/',
        childCount: 0,
      );
}

class _Goods extends Fake implements GoodsRepository {
  String name = '双击测试货品';
  int listReads = 0;
  int detailReads = 0;
  final queries = <({String? categoryId, String? keyword})>[];

  @override
  Future<PagedResult<GoodsListItem>> list(
    String? categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeDisabled = false,
    bool excludeStub = false,
    bool disabledOnly = false,
    bool stubOnly = false,
    bool includeRelated = false,
  }) async {
    if (!disabledOnly && !stubOnly) {
      listReads++;
      queries.add((categoryId: categoryId, keyword: keyword));
    }
    final items = disabledOnly || stubOnly
        ? <GoodsListItem>[]
        : [
            GoodsListItem(
              id: 'goods-1',
              code: 'HP001',
              name: name,
              categoryId: 'cat',
              status: '使用',
            ),
          ];
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  Future<GoodsFacets> facets(
    String categoryId, {
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async => const GoodsFacets(fields: {}, nullCounts: {});

  @override
  Future<GoodsFacets> globalFacets({
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
    Set<String> categoryRootIds = const {},
  }) async => const GoodsFacets(fields: {}, nullCounts: {});

  @override
  Future<Set<String>> searchCategoryIds(
    String keyword, {
    required Set<String> categoryRootIds,
    String? categoryId,
    bool includeRelated = false,
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async => {'cat'};

  @override
  Future<GoodsDetail> detail(String id) async {
    detailReads++;
    return GoodsDetail(
      id: id,
      code: 'HP001',
      name: name,
      categoryId: 'cat',
      status: '使用',
      sourceType: '采购',
    );
  }
}

Future<void> _doubleClickRow(WidgetTester tester, String label) async {
  final cell = find.text(label).hitTestable().first;
  await tester.tap(cell, kind: PointerDeviceKind.mouse);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tap(cell, kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
}

Future<void> _openRowMenu(WidgetTester tester, String label) async {
  final press = await tester.startGesture(
    tester.getCenter(find.text(label).hitTestable().first),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await press.up();
  await tester.pumpAndSettle();
  expect(find.text('查看详情'), findsOneWidget);
  await tester.tap(find.text('查看详情'), kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
}

void main() {
  for (final scenario in [
    (navigation: 'header', search: false),
    (navigation: 'go', search: false),
    (navigation: 'platform', search: false),
    (navigation: 'platform', search: true),
  ]) {
    final navigation = scenario.navigation;
    testWidgets(
      '$navigation return search=${scenario.search} restores mouse double-click and row menu',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final goods = _Goods();
        final router = GoRouter(
          initialLocation: RouteName.basicinfoGoods,
          routes: [
            DraftAwareGoRoute(
              path: RouteName.basicinfoGoods,
              builder: (_, _) => const ProductCategoryPage(),
            ),
            DraftAwareGoRoute(
              path: RouteName.basicinfoGoodsDetail,
              builder: (_, state) =>
                  GoodsDetailPage(goodsId: state.pathParameters['id']),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(
                await SharedPreferences.getInstance(),
              ),
              sessionProvider.overrideWith(_Session.new),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'goods-reader'),
              ),
              apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
              apiClientProvider.overrideWithValue(
                ApiClient(
                  Dio(BaseOptions(baseUrl: 'https://test.example/api')),
                ),
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.goodsView,
                Perm.materialCategoryView,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              productCategoryRepositoryProvider.overrideWithValue(
                _Categories(),
              ),
              goodsRepositoryProvider.overrideWithValue(goods),
              colorDictProvider.overrideWith((ref) async => const []),
              unitDictProvider.overrideWith((ref) async => const []),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              builder: (_, child) => UtenContextMenuPolicy(child: child!),
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('测试分类'));
        await tester.pumpAndSettle();
        final listState = tester.state(find.byType(ProductCategoryPage));
        expect(goods.listReads, 1);

        Finder searchInput() => find.descendant(
          of: find.byType(UtenSearchBar).hitTestable().first,
          matching: find.byType(EditableText),
        );
        if (scenario.search) {
          await tester.enterText(searchInput(), '测试');
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(goods.queries.last.keyword, '测试');
        }
        final initialListReads = goods.listReads;
        await _doubleClickRow(tester, goods.name);
        expect(find.byType(GoodsDetailPage), findsOneWidget);
        expect(goods.detailReads, 1);
        final firstDetailMatch =
            router.routerDelegate.currentConfiguration.last
                as ImperativeRouteMatch;
        goods.name = '详情返回更新后的货品';

        Future<void> returnToList() async {
          switch (navigation) {
            case 'header':
              await tester.tap(find.byKey(const Key('goods-detail-back')));
            case 'go':
              router.go(RouteName.basicinfoGoods);
            case 'platform':
              // Browser history changes arrive through route information, not pop.
              await router.routeInformationProvider.didPushRouteInformation(
                RouteInformation(uri: Uri.parse(RouteName.basicinfoGoods)),
              );
          }
          await tester.pumpAndSettle();
        }

        await returnToList();
        expect(find.byType(GoodsDetailPage), findsNothing);
        expect(tester.state(find.byType(ProductCategoryPage)), same(listState));
        if (scenario.search) {
          // Search clearing starts an independent query when this visit returns.
          expect(goods.listReads, greaterThan(initialListReads));
          expect(
            tester.widget<EditableText>(searchInput()).controller.text,
            '',
          );
          expect(goods.queries.last, (categoryId: 'cat', keyword: null));
          expect(
            find.byKey(const ValueKey('master-query-pending')),
            findsNothing,
          );
        } else {
          expect(
            goods.listReads,
            initialListReads + 1,
            reason: 'Each detail visit refreshes once.',
          );
        }
        final afterFirstReturnReads = goods.listReads;
        expect(find.text(goods.name).hitTestable(), findsOneWidget);

        await _openRowMenu(tester, goods.name);
        expect(find.byType(GoodsDetailPage), findsOneWidget);
        expect(goods.detailReads, 2);
        if (navigation != 'header') {
          // A removed visit's push Future may complete after the next visit.
          // It must not release the new lock or refresh a hidden old list.
          firstDetailMatch.complete();
          await tester.pumpAndSettle();
          expect(goods.listReads, afterFirstReturnReads);
          expect(find.byType(GoodsDetailPage), findsOneWidget);
          expect(router.canPop(), isTrue);
        }
        await returnToList();
        expect(goods.listReads, afterFirstReturnReads + 1);
        // The menu action's Future must finish after a browser/go return too,
        // so its temporary selection can be cleared by the shared table.
        final table = tester.widget<MasterDataTableView<GoodsListItem>>(
          find.byType(MasterDataTableView<GoodsListItem>),
        );
        expect(table.selectedIds, isEmpty);

        await _doubleClickRow(tester, goods.name);
        expect(find.byType(GoodsDetailPage), findsOneWidget);
        expect(goods.detailReads, 3);
        // The app-bar pop still works after visits recovered via browser/go.
        await tester.tap(find.byKey(const Key('goods-detail-back')));
        await tester.pumpAndSettle();
        expect(goods.listReads, afterFirstReturnReads + 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
