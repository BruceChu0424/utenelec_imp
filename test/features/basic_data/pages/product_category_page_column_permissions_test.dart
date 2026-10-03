import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/platform_tables_host.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _permissionsProvider = StateProvider<Set<String>>((ref) => {});
const _addColumnKey = Key('platform-table-add-column');
const _newColumnKey = Key('platform-column-new');
const _createColumnKey = Key('platform-column-create');
const _columnNameKey = Key('platform-column-name');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'goods edit permission enables adding a real master_goods column',
    (tester) async {
      final repository = _FakePlatformTableRepository();
      final container = await _pumpPage(tester, repository, {
        Perm.goodsView,
        Perm.goodsEdit,
      });

      final button = tester.widget<IconButton>(
        find.byKey(_addColumnKey).hitTestable(),
      );
      expect(button.tooltip, '添加列');
      expect((button.icon as Icon).icon, Icons.add_rounded);
      expect(find.byTooltip('显示列'), findsNothing);

      await _tap(tester, find.byKey(_addColumnKey).hitTestable());
      expect(find.text('添加列'), findsOneWidget);
      expect(repository.searchScopes, contains('master_goods'));
      await _tap(tester, find.byKey(_newColumnKey));
      expect(find.text('新建列'), findsOneWidget);
      await tester.enterText(find.byKey(_columnNameKey), '包装说明');
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(_createColumnKey));

      expect(repository.created, hasLength(1));
      expect(repository.created.single.scope, 'master_goods');
      expect(repository.created.single.name, '包装说明');
      expect(repository.created.single.type, 'TEXT');
      expect(repository.used, [('master_goods', 'goods-column-1')]);
      final layout = container.read(
        platformTableLayoutProvider('master.goods'),
      );
      expect(layout.added.map((column) => column.id), ['goods-column-1']);
      expect(find.byKey(_createColumnKey), findsNothing);
      expect(find.text('包装说明'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  for (final permissionCase in [
    ('view only', {Perm.goodsView}),
    ('view and create only', {Perm.goodsView, Perm.goodsCreate}),
  ]) {
    testWidgets('${permissionCase.$1} cannot add or create table columns', (
      tester,
    ) async {
      final repository = _FakePlatformTableRepository();
      await _pumpPage(tester, repository, permissionCase.$2);

      final button = tester.widget<IconButton>(
        find.byKey(_addColumnKey).hitTestable(),
      );
      expect(button.tooltip, '显示列');
      expect((button.icon as Icon).icon, Icons.view_column_outlined);
      expect(find.byTooltip('添加列'), findsNothing);
      await _tap(tester, find.byKey(_addColumnKey).hitTestable());

      expect(find.text('显示列'), findsOneWidget);
      expect(find.byKey(_newColumnKey), findsNothing);
      expect(find.byKey(_createColumnKey), findsNothing);
      expect(find.byKey(_columnNameKey), findsNothing);
      expect(repository.searchScopes, isEmpty);
      expect(repository.created, isEmpty);
      expect(repository.used, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'revoking goods edit closes creation and fences the open action',
    (tester) async {
      final repository = _FakePlatformTableRepository();
      final container = await _pumpPage(tester, repository, {
        Perm.goodsView,
        Perm.goodsEdit,
      });
      await _tap(tester, find.byKey(_addColumnKey).hitTestable());
      await _tap(tester, find.byKey(_newColumnKey));
      await tester.enterText(find.byKey(_columnNameKey), '待创建说明');
      await tester.pumpAndSettle();
      final create = tester
          .widget<UtenButton>(find.byKey(_createColumnKey))
          .onPressed;
      expect(create, isNotNull);

      container.read(_permissionsProvider.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();

      expect(find.text('显示列'), findsOneWidget);
      expect(find.byKey(_newColumnKey), findsNothing);
      expect(find.byKey(_createColumnKey), findsNothing);
      expect(find.byKey(_columnNameKey), findsNothing);
      // Even a callback captured before the permission update must not write.
      create!();
      await tester.pumpAndSettle();
      expect(repository.created, isEmpty);
      expect(repository.used, isEmpty);

      await _tap(tester, find.text('取消'));
      expect(find.byTooltip('显示列').hitTestable(), findsOneWidget);
      expect(find.byTooltip('添加列'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  _FakePlatformTableRepository platformRepository,
  Set<String> permissions,
) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.reject(
          DioException(
            requestOptions: options,
            error: StateError('Unexpected network request: ${options.path}'),
          ),
        ),
      ),
    );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        apiClientProvider.overrideWithValue(ApiClient(dio)),
        _permissionsProvider.overrideWith((ref) => permissions),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissionsProvider),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(null),
        productCategoryRepositoryProvider.overrideWithValue(
          _FakeCategoryRepository(),
        ),
        goodsRepositoryProvider.overrideWithValue(_FakeGoodsRepository()),
        platformTableRepositoryProvider.overrideWithValue(platformRepository),
      ],
      child: const PlatformTablesHost(
        child: MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ProductCategoryPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, find.text('成品类(C-FIN)'));
  return ProviderScope.containerOf(
    tester.element(find.byType(ProductCategoryPage)),
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _FakePlatformTableRepository implements PlatformTableRepository {
  final created = <PlatformColumnDefinition>[];
  final searchScopes = <String>[];
  final used = <(String, String)>[];

  @override
  Future<List<PlatformTableCapabilities>> scopes() async => const [
    // Keep server capabilities permissive to verify the page's own edit gate.
    PlatformTableCapabilities(
      scope: 'master_goods',
      canWrite: true,
      canDefine: true,
      canCreate: true,
    ),
  ];

  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async {
    searchScopes.add(scope);
    return created
        .where(
          (column) =>
              column.scope == scope &&
              column.name.contains(query) &&
              (ids == null || ids.contains(column.id)),
        )
        .toList();
  }

  @override
  Future<PlatformColumnDefinition> create(
    String scope, {
    required String name,
    required String type,
    bool priceProtected = false,
    PlatformFormula? formula,
  }) async {
    final column = PlatformColumnDefinition(
      id: 'goods-column-${created.length + 1}',
      scope: scope,
      name: name,
      type: type,
      priceProtected: priceProtected,
      formula: formula,
    );
    created.add(column);
    return column;
  }

  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async => [
    for (final id in ids) PlatformRowValues(recordId: id, canWrite: true),
  ];

  @override
  Future<void> recordUse(String scope, String id) async =>
      used.add((scope, id));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCategoryRepository implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'finished',
      code: 'C-FIN',
      name: '成品类',
      level: 0,
      codePrefix: 'CP',
      children: const [],
    ),
  ];

  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      const ProductCategoryDetail(
        id: 'finished',
        code: 'C-FIN',
        name: '成品类',
        level: 0,
        path: '成品类',
        childCount: 0,
        codePrefix: 'CP',
        effectivePrefix: 'CP',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeGoodsRepository implements GoodsRepository {
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
  }) async {
    final items = disabledOnly || stubOnly
        ? const <GoodsListItem>[]
        : const [
            GoodsListItem(
              id: 'goods-1',
              code: '280235165',
              name: '两开多功能三极插座',
              categoryId: 'finished',
              status: '使用',
            ),
          ];
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: items.isEmpty ? 0 : 1,
    );
  }

  @override
  Future<GoodsFacets> facets(String categoryId) async =>
      const GoodsFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
