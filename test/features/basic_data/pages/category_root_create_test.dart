import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_field_placeholder.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/inputs/uten_field_placeholder.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/payment_style_page.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/features/basic_data/widgets/category_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/uten_location_field.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_node_actions.dart';
import '../../../support/filter_segment_tap.dart';
import '../../../support/audit_screenshot_support.dart';

const _rootId = '00000000-0000-0000-0000-000000000001';
const _childId = '00000000-0000-0000-0000-000000000002';
const _createdId = '00000000-0000-0000-0000-000000000003';

void main() {
  for (final scenario in [
    (width: 390.0, scale: 1.0, dark: false),
    (width: 900.0, scale: 1.3, dark: true),
    (width: 1440.0, scale: 1.8, dark: false),
  ]) {
    testWidgets('category search header aligns at ${scenario.width}', (
      tester,
    ) async {
      const capture = bool.fromEnvironment('UTEN_AUDIT_SCREENSHOTS');
      if (capture) await loadAuditScreenshotFonts(tester);
      final captureKey = GlobalKey();
      final oldShadows = debugDisableShadows;
      if (capture) debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = oldShadows);
      await _pump(
        tester,
        _CategoryApi('goods'),
        size: Size(scenario.width, 900),
        textScale: scenario.scale,
        captureKey: captureKey,
        theme: auditScreenshotTheme(
          scenario.dark ? buildDarkTheme() : buildLightTheme(),
        ),
      );
      final field = find.byType(UtenSearchBar).first;
      final add = find.byKey(const ValueKey('category-add-root')).first;
      expect(tester.getRect(add).top, closeTo(tester.getRect(field).top, 0.1));
      expect(
        tester.getRect(add).bottom,
        closeTo(tester.getRect(field).bottom, 0.1),
      );
      expect(add.hitTestable(), findsOneWidget);
      final reads = _searchText(tester);
      await tester.tap(
        find.descendant(of: field, matching: find.byType(TextField)),
      );
      await tester.pumpAndSettle();
      expect(_searchText(tester), reads);
      expect(tester.takeException(), isNull);
      if (capture) {
        await saveAuditScreenshot(
          tester,
          captureKey,
          'hierarchy-search-${scenario.width.toInt()}',
        );
      }
      debugDisableShadows = oldShadows;
    });
  }
  for (final kind in ['goods', 'mould', 'client', 'supplier']) {
    testWidgets('$kind 根入口独立于选中子类和查询，创建真实根后清查询并定位UUID', (tester) async {
      final fixture = _CategoryApi(kind);
      await _pump(tester, fixture);
      final search = tester.getRect(find.byType(UtenSearchBar).first);
      final action = find.byKey(const ValueKey('category-add-root'));
      final actionRect = tester.getRect(action);
      expect(actionRect.top, closeTo(search.top, 0.1));
      expect(actionRect.bottom, closeTo(search.bottom, 0.1));
      expect(actionRect.width, closeTo(search.height, 0.1));
      expect(
        find.descendant(
          of: action,
          matching: find.byIcon(Icons.create_new_folder_outlined),
        ),
        findsOneWidget,
      );
      final tree = tester.getRect(
        find.byWidgetPredicate((widget) => widget is UtenCategoryTreeView),
      );
      expect(search.left, closeTo(tree.left, 0.1));
      expect(find.text('真实业务根'), findsOneWidget);
      final beforeChild = tester.getTopLeft(find.text('既有子分类'));
      await tester.tap(find.text('既有子分类'));
      await tester.pumpAndSettle();
      await _query(tester, '不匹配查询');
      await tester.tap(find.byTooltip('新增最外层分类'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CategoryEditDialog>(find.byType(CategoryEditDialog))
            .initialParent,
        isNull,
      );
      expect(
        tester
            .widget<UtenLocationField>(find.byType(UtenLocationField))
            .pathLabel,
        isNull,
      );
      expect(
        tester
            .widget<UtenLocationField>(find.byType(UtenLocationField))
            .resultLevelLabel,
        'L0',
      );
      await tester.enterText(_nameField(), '新最外层分类');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(fixture.creates, hasLength(1));
      expect(fixture.creates.single['parentId'], isNull);
      expect(_searchText(tester), isEmpty);
      expect(fixture.reads, contains('${fixture.categories}/$_createdId'));
      expect(find.text('新最外层分类'), findsWidgets);
      expect(find.text('真实业务根'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('既有子分类')).dx,
        closeTo(beforeChild.dx, 0.1),
      );
      expect(tester.takeException(), isNull);

      // 树行「新增子分类」图标继续用选中分类的真实 UUID（2026-10-19 起分类
      // CRUD 在左树行内图标 + 右键菜单，详情卡不再有分类按钮）。
      await tester.tap(find.byTooltip('新增新最外层分类的子分类'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CategoryEditDialog>(find.byType(CategoryEditDialog))
            .initialParent
            ?.id,
        _createdId,
      );
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
    });

    testWidgets('$kind 无新增权限不显示根入口且不发创建请求', (tester) async {
      final fixture = _CategoryApi(kind);
      await _pump(tester, fixture, canCreate: false);
      expect(find.byTooltip('新增最外层分类'), findsNothing);
      expect(fixture.creates, isEmpty);
      expect(find.text('真实业务根'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('分类行图标与右键菜单复用同一权限和创建回调', (tester) async {
    await _pump(tester, _CategoryApi('client'));
    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byWidgetPredicate((widget) => widget is UtenCategoryTreeView),
    );
    final node = tree.nodes.first;
    final actions = tree.trailingBuilder!(node) as UtenHierarchyNodeActions;
    final operation = actions.operations.add!;
    final menu = tree.rowMenuBuilder!(node).whereType<UtenMenuItem>().toList();
    expect(menu.single.label, operation.label);
    expect(identical(menu.single.onTap, operation.onInvoke), isTrue);
    expect(actions.operations.edit, isNull);
    expect(actions.operations.delete, isNull);

    await _pump(tester, _CategoryApi('client'), canCreate: false);
    final readonlyTree = tester
        .widget<UtenCategoryTreeView<ProductCategoryNode>>(
          find.byWidgetPredicate((widget) => widget is UtenCategoryTreeView),
        );
    final readonlyNode = readonlyTree.nodes.first;
    final readonlyActions =
        readonlyTree.trailingBuilder!(readonlyNode) as UtenHierarchyNodeActions;
    expect(readonlyActions.operations.add, isNull);
    expect(readonlyTree.rowMenuBuilder!(readonlyNode), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空树窄屏大字号仍可从搜索右侧创建第一个根', (tester) async {
    final fixture = _CategoryApi('client', empty: true);
    await _pump(tester, fixture, size: const Size(390, 900), textScale: 1.8);
    final action = find.byTooltip('新增最外层分类');
    final search = find.byType(UtenSearchBar).first;
    expect(
      tester.getRect(action).height,
      closeTo(tester.getRect(search).height, 0.1),
    );
    expect(
      tester.getTopLeft(action).dx,
      greaterThanOrEqualTo(tester.getTopRight(search).dx),
    );
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CategoryEditDialog>(find.byType(CategoryEditDialog))
          .initialParent,
      isNull,
    );
    await tester.enterText(_nameField(), '新最外层分类');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(fixture.creates.single['parentId'], isNull);
    expect(find.text('新最外层分类'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('根创建取消和失败保留查询，成功才清除', (tester) async {
    final fixture = _CategoryApi('client');
    await _pump(tester, fixture);
    await _query(tester, '保留此查询');
    await tester.tap(find.byTooltip('新增最外层分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(_searchText(tester), '保留此查询');
    expect(fixture.creates, isEmpty);

    fixture.failCreate = true;
    await tester.tap(find.byTooltip('新增最外层分类'));
    await tester.pumpAndSettle();
    await tester.enterText(_nameField(), '新最外层分类');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.byType(CategoryEditDialog), findsOneWidget);
    expect(_searchText(tester), '保留此查询');
    fixture.failCreate = false;
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(_searchText(tester), isEmpty);
    expect(fixture.reads, contains('${fixture.categories}/$_createdId'));
  });

  testWidgets('根创建成功后旧搜索响应不能再次隐藏新UUID', (tester) async {
    final fixture = _CategoryApi('client')..holdSearch = true;
    await _pump(tester, fixture);
    await tester.enterText(find.byType(TextField).first, '旧搜索');
    await tester.pump(const Duration(milliseconds: 350));
    expect(fixture.heldSearch, isNotEmpty);
    await tester.tap(find.byTooltip('新增最外层分类'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(_nameField(), '新最外层分类');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    fixture.releaseSearch();
    await tester.pumpAndSettle();
    expect(_searchText(tester), isEmpty);
    expect(find.text('新最外层分类'), findsWidgets);
    expect(
      fixture.reads.lastWhere(
        (path) => path.startsWith('${fixture.categories}/'),
      ),
      '${fixture.categories}/$_createdId',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('新增根后仍按基础资料原有返回路径离开', (tester) async {
    final fixture = _CategoryApi('client');
    final router = GoRouter(
      initialLocation: '/basicinfo/client',
      routes: [
        GoRoute(
          path: '/basicinfo',
          builder: (_, _) => const Scaffold(body: Text('基础资料入口')),
        ),
        GoRoute(
          path: '/basicinfo/client',
          builder: (_, _) => const ClientCategoryPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await _pump(tester, fixture, router: router);
    await tester.tap(find.byTooltip('新增最外层分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('基础资料入口'), findsOneWidget);
  });

  for (final category in PaymentStyleCategory.values) {
    testWidgets('收付款${category.label}搜索右侧根入口保留大类并发送null父UUID', (tester) async {
      final fixture = _CategoryApi('payment-style');
      await _pump(tester, fixture);
      await selectFilterSegment(tester, category.label);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(UtenCategoryTreeView<PaymentStyleNode>),
          matching: find.text('既有子分类'),
        ),
      );
      await tester.pumpAndSettle();
      await _query(tester, '不匹配类别');
      await tester.tap(find.byTooltip('新增最外层类别'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenLocationField>(find.byType(UtenLocationField))
            .pathLabel,
        isNull,
      );
      expect(
        tester
            .widget<UtenLocationField>(find.byType(UtenLocationField))
            .resultLevelLabel,
        'L0',
      );
      await tester.enterText(_nameField(payment: true), '新最外层分类');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(fixture.creates.single['parentId'], isNull);
      expect(fixture.creates.single['category'], category.value);
      expect(_searchText(tester), isEmpty);
      expect(fixture.reads, contains('${fixture.categories}/$_createdId'));
      expect(find.text('新最外层分类'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('收付款类别无新增权限时搜索栏没有新增动作', (tester) async {
    final fixture = _CategoryApi('payment-style', empty: true);
    await _pump(tester, fixture, canCreate: false);
    expect(find.byTooltip('新增最外层类别'), findsNothing);
    expect(find.text('添加顶级类别'), findsNothing);
    expect(fixture.creates, isEmpty);
  });

  testWidgets('收付款根创建取消和失败保留查询，成功后才清除并定位', (tester) async {
    final fixture = _CategoryApi('payment-style');
    await _pump(tester, fixture);
    await _query(tester, '保留收付款查询');
    await tester.tap(find.byTooltip('新增最外层类别'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(_searchText(tester), '保留收付款查询');
    expect(fixture.creates, isEmpty);

    fixture.failCreate = true;
    await tester.tap(find.byTooltip('新增最外层类别'));
    await tester.pumpAndSettle();
    await tester.enterText(_nameField(payment: true), '新最外层分类');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(_nameField(payment: true), findsOneWidget);
    expect(_searchText(tester), '保留收付款查询');
    fixture.failCreate = false;
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(_searchText(tester), isEmpty);
    expect(fixture.reads, contains('${fixture.categories}/$_createdId'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('收付款空树窄屏大字号可创建首根并返回内容', (tester) async {
    final fixture = _CategoryApi('payment-style', empty: true);
    await _pump(tester, fixture, size: const Size(390, 900), textScale: 1.8);
    await tester.tap(find.text('选择类别'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新增最外层类别'));
    await tester.pumpAndSettle();
    await tester.enterText(_nameField(payment: true), '新最外层分类');
    await tester.ensureVisible(find.text('创建'));
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(fixture.creates.single['parentId'], isNull);
    expect(_searchText(tester), isEmpty);
    expect(find.text('新最外层分类'), findsWidgets);
    await tester.tap(find.byTooltip('返回内容'));
    await tester.pumpAndSettle();
    expect(find.text('新最外层分类'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

Finder _nameField({bool payment = false}) => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.decoration != null &&
      utenDecorationFieldName(widget.decoration!) == (payment ? '类别名称' : '名称'),
);

String _searchText(WidgetTester tester) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byType(UtenSearchBar).first,
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

Future<void> _query(WidgetTester tester, String text) async {
  await tester.enterText(
    find.descendant(
      of: find.byType(UtenSearchBar).first,
      matching: find.byType(TextField),
    ),
    text,
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _CategoryApi fixture, {
  bool canCreate = true,
  Size size = const Size(1600, 1000),
  double textScale = 1,
  GoRouter? router,
  GlobalKey? captureKey,
  ThemeData? theme,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final kind = fixture.kind;
  final permissions = kind == 'payment-style'
      ? {Perm.paymentStyleView, if (canCreate) Perm.paymentStyleCreate}
      : {
          '$kind:view',
          '${fixture.categoryKind}_category:view',
          if (canCreate) '${fixture.categoryKind}_category:create',
        };
  Widget builder(BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  );
  final app = router == null
      ? MaterialApp(
          theme: theme,
          home: switch (kind) {
            'goods' => const ProductCategoryPage(),
            'mould' => const MouldCategoryPage(),
            'client' => const ClientCategoryPage(),
            'supplier' => const SupplierCategoryPage(),
            _ => const PaymentStylePage(),
          },
          builder: builder,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        )
      : MaterialApp.router(
          theme: theme,
          routerConfig: router,
          builder: builder,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(ApiClient(fixture.dio)),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: captureKey == null
          ? app
          : RepaintBoundary(key: captureKey, child: app),
    ),
  );
  await tester.pumpAndSettle();
}

class _CategoryApi {
  _CategoryApi(this.kind, {this.empty = false}) {
    dio.interceptors.add(InterceptorsWrapper(onRequest: _request));
  }
  final String kind;
  final bool empty;
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  final creates = <Map<String, dynamic>>[];
  final reads = <String>[];
  final heldSearch = <(RequestOptions, RequestInterceptorHandler)>[];
  bool failCreate = false, holdSearch = false, created = false;
  String activeCategory = 'EXPENSE';
  String get categoryKind => kind == 'goods' ? 'material' : kind;
  String get categories => kind == 'payment-style'
      ? '/master/payment-styles'
      : '/master/$categoryKind-categories';
  String get content => '/master/${kind == 'goods' ? 'goods' : '${kind}s'}';

  Map<String, dynamic> node(String id, String name, {String? parent}) => {
    'id': id,
    'name': name,
    'code': id == _rootId
        ? 'ROOT'
        : id == _childId
        ? 'CHILD'
        : 'NEW',
    'parentId': parent,
    'level': parent == null ? 0 : 1,
    'path': '/${parent == null ? '' : '$parent/'}$id/',
    'childCount': 0,
    'children': <Object>[],
    'sortOrder': 0,
    'version': 0,
    'category': activeCategory,
    'status': '使用',
    'receipt': false,
    'payment': false,
    'departmental': false,
  };

  void _request(RequestOptions request, RequestInterceptorHandler handler) {
    final path = request.path;
    if (request.method == 'POST' && path == categories) {
      creates.add(Map<String, dynamic>.from(request.data as Map));
      if (failCreate) {
        handler.reject(
          DioException(
            requestOptions: request,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: request,
              statusCode: 409,
              data: {'message': '分类保存失败'},
            ),
          ),
        );
        return;
      }
      created = true;
      handler.resolve(
        Response(
          requestOptions: request,
          statusCode: 200,
          data: node(_createdId, '新最外层分类'),
        ),
      );
      return;
    }
    reads.add(path);
    Object data = <String, dynamic>{};
    if (path == '$categories/tree') {
      activeCategory =
          request.queryParameters['category'] as String? ?? activeCategory;
      data = [
        if (!empty)
          {
            ...node(_rootId, '真实业务根'),
            'childCount': 1,
            'children': [node(_childId, '既有子分类', parent: _rootId)],
          },
        if (created) node(_createdId, '新最外层分类'),
      ];
    } else if (path.startsWith('$categories/')) {
      final id = path.split('/').last;
      data = node(
        id,
        id == _rootId
            ? '真实业务根'
            : id == _childId
            ? '既有子分类'
            : '新最外层分类',
        parent: id == _childId ? _rootId : null,
      );
    } else if (path.contains('category-ids')) {
      data = <String>[];
    } else if (path.contains('/facets')) {
      data = <String, dynamic>{};
    } else if (path == content || path == '$content/search') {
      final query = request.data is Map
          ? (request.data as Map)['keyword']
          : request.queryParameters['keyword'];
      if (holdSearch && query != null && query.toString().isNotEmpty) {
        heldSearch.add((request, handler));
        return;
      }
      data = _emptyPage;
    }
    handler.resolve(
      Response(requestOptions: request, statusCode: 200, data: data),
    );
  }

  void releaseSearch() {
    for (final (request, handler) in heldSearch) {
      handler.resolve(
        Response(requestOptions: request, statusCode: 200, data: _emptyPage),
      );
    }
    heldSearch.clear();
  }
}

const _emptyPage = {
  'items': <Object>[],
  'total': 0,
  'page': 1,
  'size': 20,
  'totalPages': 0,
};
