import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_table_surface.dart';
import 'package:uten_imp/components/layout/uten_adaptive_hierarchy_pane.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/components/layout/uten_scroll_gutter.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_workspace.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/category_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/category_page_shell.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/master_detail_card.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_search_header.dart';

const _category = ProductCategoryDetail(
  id: 'category',
  code: 'CAT',
  name: '测试分类',
  level: 0,
  path: '测试分类',
  childCount: 0,
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _CategoryPage extends ConsumerStatefulWidget {
  const _CategoryPage(this.noun);
  final String noun;
  @override
  ConsumerState<_CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends ConsumerState<_CategoryPage>
    with CategoryPageShell<_CategoryPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => shellReload());
  }

  @override
  String get shellTitle => '${widget.noun}资料';
  @override
  String get shellContentNoun => widget.noun;
  @override
  String get shellSearchHint => '搜索分类/${widget.noun}名称或编号';
  @override
  IconData get shellEmptyIcon => Icons.category_outlined;
  @override
  String get shellPersistenceKey => 'alignment.${widget.noun}';
  @override
  FormDraftDescriptor get shellCategoryDraftDescriptor =>
      FormDraftCatalog.goodsCategory;
  @override
  String get shellCategoryViewPermission => Perm.materialCategoryView;
  @override
  bool get shellCanCreate => true;
  @override
  bool get shellCanEdit => false;
  @override
  bool get shellCanDelete => false;
  @override
  bool get shellCanMove => false;
  @override
  bool get shellCanReorder => false;
  @override
  Future<List<ProductCategoryNode>> shellLoadTree() async => [
    ProductCategoryNode(
      id: _category.id,
      code: _category.code,
      name: _category.name,
      level: 0,
      children: const [],
    ),
  ];
  @override
  Future<ProductCategoryDetail> shellLoadCategoryDetail(String id) async =>
      _category;
  @override
  Future<Set<String>?> shellContentCategoryIds(
    String query,
    bool Function() isCurrent,
  ) async => {_category.id};
  @override
  Future<ProductCategoryDetail> shellCreateCategory(
    CategoryEditResult result,
  ) => throw UnimplementedError();
  @override
  Future<void> shellUpdateCategory(String id, CategoryEditResult result) =>
      throw UnimplementedError();
  @override
  Future<void> shellDeleteCategory(String id) => throw UnimplementedError();
  @override
  Future<CategoryPrefixAvailability> shellPrefixAvailability(
    String prefix, {
    String? categoryId,
  }) => throw UnimplementedError();
  @override
  Future<CategoryPrefixPreview> shellPrefixPreview(
    String id,
    String prefix,
    String? parentId,
  ) => throw UnimplementedError();

  @override
  Widget build(BuildContext context) => buildShell(
    context,
    detailPaneBuilder: (node) => MasterEntityDetailPane<String, String>(
      categoryId: node.id,
      externalKeyword: null,
      config: MasterEntityPaneConfig<String, String>(
        noun: widget.noun,
        icon: Icons.inventory_2_outlined,
        defaultCodePrefix: 'HP',
        columns: [
          MasterColumnDef<String>(
            key: 'name',
            label: '${widget.noun}名称',
            width: 180,
            value: (row) => row,
          ),
        ],
        idOf: (row) => row,
        statusOf: (_) => '使用',
        labelOf: (row) => row,
        loadCategory: (_) async => _category,
        loadPage: (_) async => PagedResult<String>(
          items: List.generate(40, (index) => '资料$index'),
          page: 1,
          size: 40,
          total: 40,
          totalPages: 1,
        ),
        loadFacets: (_) async =>
            const MasterPaneFacets(fields: {}, nullCounts: {}),
        batchEntityPath: '/master/goods',
        statusResourceOf: (id) => '/master/goods/$id',
        canCreate: false,
        canEdit: false,
        canDelete: false,
        canStatus: false,
      ),
    ),
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required Size size,
  required String noun,
  double zoom = 1,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'alignment-reader'),
        ),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        currentPermissionsProvider.overrideWithValue({
          Perm.materialCategoryView,
          Perm.goodsView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          platform: TargetPlatform.windows,
          fontFamily: 'NotoSansSC',
        ),
        scrollBehavior: const UtenScrollBehavior(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: UtenDisplayZoomBox(
            fontFactor: zoom,
            child: UtenPageScrollbarHost(child: child!),
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Row(
              children: [
                if (size.width >= 600)
                  SizedBox(width: UtenPageChromeMetrics.canvas(context, 80)),
                Expanded(
                  child: UtenContentContainer(
                    selectable: false,
                    child: _CategoryPage(noun),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final directory = find.descendant(
    of: find.byType(UtenAdaptiveHierarchyPane),
    matching: find.byType(OutlinedButton),
  );
  if (directory.evaluate().isNotEmpty) {
    await tester.tap(directory.first);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.textContaining(_category.name).first);
  await tester.pumpAndSettle();
}

void _expectSameEdges(Rect expected, Rect actual, String label) {
  expect(actual.left, closeTo(expected.left, .1), reason: '$label left');
  expect(actual.right, closeTo(expected.right, .1), reason: '$label right');
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
  });
  final cases = [
    for (final noun in ['货品', '客户', '供应商', '模具'])
      (noun: noun, size: const Size(791, 1000), zoom: 1.0, textScale: 1.0),
    (noun: '货品', size: const Size(390, 1000), zoom: 1.0, textScale: 1.0),
    (noun: '货品', size: const Size(791, 1100), zoom: 1.5, textScale: 1.0),
    (noun: '货品', size: const Size(1024, 1100), zoom: 1.5, textScale: 1.0),
    (noun: '货品', size: const Size(791, 1100), zoom: 1.0, textScale: 1.6),
  ];
  for (final spec in cases) {
    testWidgets(
      'single-column ${spec.noun} aligns search category toolbar and table at ${spec.size} zoom ${spec.zoom} text ${spec.textScale}',
      (tester) async {
        await _pumpPage(
          tester,
          size: spec.size,
          noun: spec.noun,
          zoom: spec.zoom,
          textScale: spec.textScale,
        );
        final search = tester.getRect(
          find.byType(UtenHierarchySearchHeader).first,
        );
        final directory = tester.getRect(
          find
              .descendant(
                of: find.byType(UtenAdaptiveHierarchyPane),
                matching: find.byType(OutlinedButton),
              )
              .first,
        );
        final card = tester.getRect(find.byType(MasterDetailCard));
        final table = tester.getRect(find.byType(MasterDataTableView<String>));
        final header = tester.getRect(find.byType(UtenTableHeaderSurface));
        _expectSameEdges(search, directory, 'category selector');
        _expectSameEdges(search, card, 'category card');
        _expectSameEdges(search, table, 'table and toolbar');
        _expectSameEdges(search, header, 'table header');
        expect(
          tester
              .getRect(
                find
                    .descendant(
                      of: find.byType(MasterDetailCard),
                      matching: find.textContaining(_category.name),
                    )
                    .first,
              )
              .left,
          greaterThan(card.left + 8),
        );
        expect(find.byKey(UtenPageScrollbarHost.railKey), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'desktop split keeps its separate detail inset and one page scrollbar',
    (tester) async {
      await _pumpPage(tester, size: const Size(1600, 1100), noun: '货品');
      expect(
        find.descendant(
          of: find.byType(UtenAdaptiveHierarchyPane),
          matching: find.byType(OutlinedButton),
        ),
        findsNothing,
      );
      final pane = tester.getRect(
        find.byType(MasterEntityDetailPane<String, String>),
      );
      final card = tester.getRect(find.byType(MasterDetailCard));
      final table = tester.getRect(find.byType(UtenTableHeaderSurface));
      expect(card.left - pane.left, closeTo(16, .1));
      _expectSameEdges(card, table, 'desktop detail');
      expect(find.byKey(UtenPageScrollbarHost.railKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final popup in [false, true]) {
    testWidgets(
      '${popup ? 'popup' : 'standalone page'} keeps the correct hierarchy edge owner',
      (tester) async {
        tester.view.physicalSize = const Size(791, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        const searchKey = Key('pane-edge-search');
        const bodyKey = Key('pane-edge-body');
        const selectorKey = Key('pane-edge-selector');
        Widget pane() => const UtenSplitView(
          minTwoPaneWidth: 840,
          openLeadingButtonKey: selectorKey,
          compactHeader: SizedBox(key: searchKey, height: 40),
          leading: Text('目录内容'),
          trailing: UtenPageEdgePadding.pane(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(key: bodyKey, height: 100),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => popup
                    ? TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => Dialog(
                            child: SizedBox(
                              width: 440,
                              height: 700,
                              child: UtenContentInsetsScope(child: pane()),
                            ),
                          ),
                        ),
                        child: const Text('打开局部选择器'),
                      )
                    : pane(),
              ),
            ),
          ),
        );
        if (popup) await tester.tap(find.text('打开局部选择器'));
        await tester.pumpAndSettle();
        final search = tester.getRect(find.byKey(searchKey));
        final body = tester.getRect(find.byKey(bodyKey));
        final selector = tester.getRect(find.byKey(selectorKey));
        if (popup) {
          expect(selector.left - search.left, closeTo(8, .1));
          expect(search.right - selector.right, closeTo(8, .1));
          expect(body.left - search.left, closeTo(16, .1));
          expect(search.right - body.right, closeTo(16, .1));
        } else {
          expect(search.left, closeTo(16, .1));
          expect(search.right, closeTo(791 - 24, .1));
          _expectSameEdges(search, selector, 'standalone selector');
          _expectSameEdges(search, body, 'standalone content');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'compact permission workspace shares navigation and detail edges',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const navigationKey = Key('permission-workspace-navigation-edge');
      const detailKey = Key('permission-workspace-detail-edge');
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenContentContainer(
              selectable: false,
              child: AdminPermissionWorkspace(
                navigation: SizedBox(key: navigationKey, height: 40),
                leading: Text('权限目录'),
                trailing: Text('桌面详情'),
                compact: UtenPageEdgePadding(
                  preserveStart: true,
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(key: detailKey, height: 100),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectSameEdges(
        tester.getRect(find.byKey(navigationKey)),
        tester.getRect(find.byKey(detailKey)),
        'permission detail',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
