import 'package:dio/dio.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_facet_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/platform_tables_host.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_widgets.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _permissionsProvider = StateProvider<Set<String>>((ref) => {});
const _addColumnKey = Key('platform-table-add-column');
const _newColumnKey = Key('platform-column-new');
const _createColumnKey = Key('platform-column-create');
const _columnNameKey = Key('platform-column-name');

// Exercise the goods table's authority, never the first global match or the
// frozen/flowing copies before their scroll-driven visibility has settled.
Finder _goodsColumns() => find
    .descendant(
      of: find.byType(MasterDataTableView<GoodsListItem>),
      matching: find.byKey(_addColumnKey),
    )
    .hitTestable();

Finder _goodsColumnTooltip(String message) => find.descendant(
  of: find.byType(MasterDataTableView<GoodsListItem>),
  matching: find.byTooltip(message),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('只有货品查看权限时远程候选和导出与含禁用品列表同范围', (tester) async {
    final facets = _ScopeFacetRepository();
    await _pumpPage(
      tester,
      _FakePlatformTableRepository(),
      {Perm.goodsView},
      categoryBrowsing: false,
      facetRepository: facets,
    );
    final pane = tester
        .widget<MasterEntityDetailPane<GoodsListItem, GoodsDetail>>(
          find.byType(MasterEntityDetailPane<GoodsListItem, GoodsDetail>),
        );
    const query = MasterPaneQuery(categoryId: null);
    await pane.config.loadFacetPage!(query, 'unitRef', '', 1);
    expect(
      facets.excludeDisabled,
      false,
      reason: '无分类浏览权限时全局列表纳入禁用品，候选必须保持同范围',
    );
    expect(pane.config.export!.queryParamsOf!(query)['excludeDisabled'], false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有查看权限也能添加本人关联列，不能新建共享文字数字或计算列', (tester) async {
    final repository = _FakePlatformTableRepository()..personalAllowed = true;
    await _pumpPage(tester, repository, {Perm.goodsView, Perm.mouldView});
    expect(tester.widget<IconButton>(_goodsColumns()).tooltip, '添加列');
    await _tap(tester, _goodsColumns());
    await _tap(tester, find.byKey(_newColumnKey));
    await tester.enterText(find.byKey(_columnNameKey), '个人模具厂家');
    await tester.pumpAndSettle();
    final type = tester.widget<UtenDropdownField>(
      find.byKey(const Key('platform-column-type')),
    );
    expect(type.items.map((item) => item.value), ['RELATED']);
    await _tap(tester, find.byKey(const Key('platform-column-relation')));
    await _tap(tester, find.text('模具 · 制造商').last);
    await _tap(tester, find.byKey(_createColumnKey));
    expect(repository.created.single.type, 'RELATED');
    expect(find.text('厂家甲'), findsWidgets);
    final cell = tester.widget<PlatformColumnValue<GoodsListItem>>(
      find.byType(PlatformColumnValue<GoodsListItem>).first,
    );
    expect(cell.controller.columnEditingEnabled, isFalse);
    expect(
      cell.controller.canEdit(cell.row, repository.created.single),
      isFalse,
    );
    repository.targetVisible = false;
    await cell.controller.reload();
    await tester.pumpAndSettle();
    expect(find.text('厂家甲'), findsNothing);
    expect(tester.widget<IconButton>(_goodsColumns()).tooltip, '显示列');
    expect(tester.takeException(), isNull);
  });

  testWidgets('货品页面创建个人模具关联列，刷新同步且撤回权限立即清除展示值', (tester) async {
    final repository = _FakePlatformTableRepository();
    await _pumpPage(tester, repository, {
      Perm.goodsView,
      Perm.goodsEdit,
      Perm.mouldView,
    });
    await _tap(tester, _goodsColumns());
    await _tap(tester, find.byKey(_newColumnKey));
    await tester.enterText(find.byKey(_columnNameKey), '我的模具厂家');
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('platform-column-type')));
    await _tap(tester, find.text('关联资料').last);
    await _tap(tester, find.byKey(const Key('platform-column-relation')));
    await _tap(tester, find.text('模具 · 制造商').last);
    await _tap(tester, find.byKey(_createColumnKey));
    expect(repository.created.single.relationKey, 'mouldManufacturer');
    expect(find.text('厂家甲'), findsWidgets);
    final cell = tester.widget<PlatformColumnValue<GoodsListItem>>(
      find.byType(PlatformColumnValue<GoodsListItem>).first,
    );
    expect(
      cell.controller.canEdit(cell.row, repository.created.single),
      isFalse,
    );
    repository.relatedValue = '厂家乙';
    await cell.controller.reload();
    await tester.pumpAndSettle();
    expect(find.text('厂家乙'), findsWidgets);
    expect(find.text('厂家甲'), findsNothing);
    final oldRows = Completer<void>();
    repository.rowGate = oldRows;
    repository.relatedValue = '旧权限在途响应';
    final pending = cell.controller.reload();
    await tester.pump();
    repository.rowGate = null;
    repository.targetVisible = false;
    await cell.controller.reload();
    await tester.pumpAndSettle();
    expect(find.text('厂家乙'), findsNothing);
    repository.targetVisible = true;
    repository.relatedValue = '重新授权后的厂家';
    await cell.controller.reload();
    await tester.pumpAndSettle();
    oldRows.complete();
    await pending;
    await tester.pumpAndSettle();
    expect(find.text('重新授权后的厂家'), findsWidgets);
    expect(find.text('旧权限在途响应'), findsNothing);
    repository.denyRows = true;
    await cell.controller.reload();
    await tester.pumpAndSettle();
    expect(
      find.text('重新授权后的厂家'),
      findsNothing,
      reason: '服务器403先于本地权限刷新时，旧投影立即失效',
    );
    expect(cell.controller.capabilities, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'goods edit permission enables adding a real master_goods column',
    (tester) async {
      final repository = _FakePlatformTableRepository();
      final container = await _pumpPage(tester, repository, {
        Perm.goodsView,
        Perm.goodsEdit,
      });

      final button = tester.widget<IconButton>(_goodsColumns());
      final table = tester.widget<MasterDataTableView<GoodsListItem>>(
        find.byType(MasterDataTableView<GoodsListItem>),
      );
      final mouldName = table.columns.singleWhere(
        (column) => column.key == 'mouldName',
      );
      expect(mouldName.value(table.items.single), '已关联模具名称');
      expect(
        table.columns
            .singleWhere((column) => column.key == 'mouldCode')
            .value(table.items.single),
        'MJ-001',
      );
      expect(button.tooltip, '添加列');
      expect((button.icon as Icon).icon, Icons.add_rounded);
      expect(_goodsColumnTooltip('显示列'), findsNothing);

      await _tap(tester, _goodsColumns());
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

      final button = tester.widget<IconButton>(_goodsColumns());
      expect(button.tooltip, '显示列');
      expect((button.icon as Icon).icon, Icons.view_column_outlined);
      expect(_goodsColumnTooltip('添加列'), findsNothing);
      await _tap(tester, _goodsColumns());

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
      await _tap(tester, _goodsColumns());
      await _tap(tester, find.byKey(_newColumnKey));
      await tester.enterText(find.byKey(_columnNameKey), '待创建说明');
      await tester.pumpAndSettle();
      final create = tester
          .widget<UtenButton>(find.byKey(_createColumnKey))
          .onPressed;
      expect(create, isNotNull);

      container.read(_permissionsProvider.notifier).state = {
        Perm.goodsView,
        Perm.materialCategoryView,
      };
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
      expect(_goodsColumnTooltip('显示列').hitTestable(), findsOneWidget);
      expect(_goodsColumnTooltip('添加列'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<ProviderContainer> _pumpPage(
  WidgetTester tester,
  _FakePlatformTableRepository platformRepository,
  Set<String> permissions, {
  bool categoryBrowsing = true,
  GoodsFacetRepository? facetRepository,
}) async {
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
        _permissionsProvider.overrideWith(
          (ref) => {
            ...permissions,
            if (categoryBrowsing) Perm.materialCategoryView,
          },
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissionsProvider),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(null),
        productCategoryRepositoryProvider.overrideWithValue(
          _FakeCategoryRepository(),
        ),
        goodsRepositoryProvider.overrideWithValue(_FakeGoodsRepository()),
        if (facetRepository != null)
          goodsFacetRepositoryProvider.overrideWithValue(facetRepository),
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
  if (categoryBrowsing) await _tap(tester, find.text('成品类'));
  return ProviderScope.containerOf(
    tester.element(find.byType(ProductCategoryPage)),
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  // Revealing a frozen column action can move its horizontal viewport. Render
  // that jump so the frozen copy retires before resolving the action again.
  await tester.pumpAndSettle();
  expect(finder, findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _FakePlatformTableRepository implements PlatformTableRepository {
  final created = <PlatformColumnDefinition>[];
  final searchScopes = <String>[];
  final used = <(String, String)>[];
  String relatedValue = '厂家甲';
  bool targetVisible = true;
  bool personalAllowed = false;
  Completer<void>? rowGate;
  bool denyRows = false;

  @override
  Future<List<PlatformTableCapabilities>> scopes() async => [
    // Keep server capabilities permissive to verify the page's own edit gate.
    PlatformTableCapabilities(
      scope: 'master_goods',
      canWrite: true,
      canDefine: true,
      canCreate: true,
      canDefineRelated: personalAllowed,
      relations: targetVisible
          ? const [
              PlatformTableRelation(key: 'mouldManufacturer', name: '模具 · 制造商'),
            ]
          : const [],
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
  Future<PlatformColumnDefinition> createRelated(
    String scope, {
    required String name,
    required String relationKey,
  }) async {
    final column = PlatformColumnDefinition(
      id: 'goods-related-${created.length + 1}',
      scope: scope,
      name: name,
      type: 'RELATED',
      relationKey: relationKey,
    );
    created.add(column);
    return column;
  }

  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    final value = relatedValue;
    await rowGate?.future;
    if (denyRows) throw ApiException('FORBIDDEN', '目标权限已撤回', httpStatus: 403);
    return [
      for (final id in ids)
        PlatformRowValues(
          recordId: id,
          canWrite: true,
          cells: [
            for (final column in created.where(
              (column) => column.related && columnIds.contains(column.id),
            ))
              PlatformColumnCell(
                columnId: column.id,
                value: value,
                definition: column,
                persisted: false,
              ),
          ],
        ),
    ];
  }

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

class _ScopeFacetRepository extends GoodsFacetRepository {
  _ScopeFacetRepository() : super(ApiClient(Dio()));
  bool? excludeDisabled;
  @override
  Future<MasterFacetPage> values({
    required String field,
    required String search,
    int page = 1,
    String? categoryId,
    Set<String> categoryRootIds = const {},
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async {
    this.excludeDisabled = excludeDisabled;
    return const MasterFacetPage(items: [], hasMore: false);
  }
}

class _FakeGoodsRepository implements GoodsRepository {
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
    final items = disabledOnly || stubOnly
        ? const <GoodsListItem>[]
        : const [
            GoodsListItem(
              id: 'goods-1',
              code: '280235165',
              name: '两开多功能三极插座',
              categoryId: 'finished',
              status: '使用',
              mouldCode: 'MJ-001',
              mouldName: '已关联模具名称',
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
  Future<GoodsFacets> facets(
    String categoryId, {
    String? keyword,
    bool includeRelated = false,
    Map<String, String?> filters = const {},
    bool excludeDisabled = false,
    bool excludeStub = false,
  }) async => const GoodsFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
