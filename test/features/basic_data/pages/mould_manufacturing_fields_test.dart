import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_month_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/providers/mould_workshop_tree.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('全部模具历史不携带虚拟分类，真实分类历史保留 UUID', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const categoryId = '01a16499-490e-7e30-979a-9c1828900b55';
    final opened = <Uri>[];
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const MouldCategoryPage()),
        GoRoute(
          path: '/basicinfo/history',
          builder: (_, state) {
            opened.add(state.uri);
            return const Scaffold(body: Text('模具历史页面'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({
            Perm.mouldView,
            Perm.mouldCategoryView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          mouldCategoryRepositoryProvider.overrideWithValue(
            _Categories(id: categoryId),
          ),
          mouldRepositoryProvider.overrideWithValue(_Moulds()),
          mouldWorkshopTreeProvider.overrideWith(
            (ref) async => const MouldWorkshopTree(tree: [], prodDeptId: null),
          ),
        ],
        child: MaterialApp.router(
          locale: const Locale('zh'),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部模具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改历史'));
    await tester.pumpAndSettle();
    expect(opened.last.queryParameters, {'entityType': 'moulds'});
    router.pop();
    await tester.pumpAndSettle();
    if (find.text('历史模具').evaluate().isEmpty) {
      await tester.tap(find.text('全部模具'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('历史模具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改历史'));
    await tester.pumpAndSettle();
    expect(opened.last.queryParameters, {
      'entityType': 'moulds',
      'categoryId': categoryId,
    });
    expect(tester.takeException(), isNull);
  });

  for (final boundDepartment in [false, true]) {
    testWidgets('模具详情独立展示车间关系与存放位置 $boundDepartment', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _Moulds(
        detailOverride: MouldDetail(
          id: 'mould',
          categoryId: 'cat',
          categoryName: '历史模具',
          code: 'MJ001',
          name: '旧模具名称',
          status: '使用',
          place: 'UAT Shelf A-07',
          remark: '[原始主档编号] {"code":"Q9-M04-B【E3-02】","mnumber":""}',
          departmentId: boundDepartment
              ? 'e71a67b8-cc50-4111-a19f-f5c01a328402'
              : null,
          departmentName: 'UAT注塑车间',
        ),
      );
      await _pumpPage(
        tester,
        repository,
        await SharedPreferences.getInstance(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史模具'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旧模具名称'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('旧模具名称'));
      await tester.pumpAndSettle();
      final dialog = find.byWidgetPredicate((widget) => widget is Dialog);
      final readableRemark = find.descendant(
        of: dialog,
        matching: find.text('Original code: Q9-M04-B【E3-02】'),
      );
      expect(readableRemark, findsOneWidget);
      expect(tester.widget<Text>(readableRemark).maxLines, 1);
      expect(repository.record.remark, contains('"code"'));
      final workshop = find
          .descendant(of: dialog, matching: find.text('车间'))
          .last;
      final workshopCell = find
          .ancestor(of: workshop, matching: find.byType(Column))
          .first;
      expect(
        find.descendant(
          of: workshopCell,
          matching: find.text(boundDepartment ? 'UAT注塑车间' : '—'),
        ),
        findsOneWidget,
      );
      final location = find
          .descendant(of: dialog, matching: find.text('存放位置'))
          .last;
      final locationCell = find
          .ancestor(of: location, matching: find.byType(Column))
          .first;
      expect(
        find.descendant(
          of: locationCell,
          matching: find.text('UAT Shelf A-07'),
        ),
        findsOneWidget,
      );
      if (!boundDepartment) {
        expect(
          find.descendant(of: dialog, matching: find.text('UAT注塑车间')),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('模具旧年月回显，按月份选择后提交 mstatus 和制造商，重开保留', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Moulds();
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({
            Perm.mouldView,
            Perm.mouldCategoryView,
            Perm.mouldEdit,
            Perm.mouldCreate,
          }),
          mouldCategoryRepositoryProvider.overrideWithValue(_Categories()),
          mouldRepositoryProvider.overrideWithValue(repository),
          mouldWorkshopTreeProvider.overrideWith(
            (ref) async => const MouldWorkshopTree(tree: [], prodDeptId: null),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MouldCategoryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史模具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧模具名称'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('旧模具名称'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(UtenMonthField),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '2008年7月',
    );
    await tester.ensureVisible(find.byType(UtenMonthField));
    await tester.tap(find.byTooltip('选择制造年月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9月'));
    await tester.pumpAndSettle();
    final monthInput = find.descendant(
      of: find.byType(UtenMonthField),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(monthInput).controller!.text, '2008-09');
    final manufacturer = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == '模具制造商',
    );
    await tester.enterText(manufacturer, '测试制造商');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repository.saved?['mstatus'], '2008-09');
    expect(repository.saved?['manufacturer'], '测试制造商');
    expect(repository.saved?['place'], '历史存放位置');
    expect(repository.saved?['keeper'], '历史保管人');
    expect(repository.saved, isNot(contains('mfgMonth')));
    await tester.tap(find.text('旧模具名称'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('旧模具名称'));
    await tester.pumpAndSettle();
    expect(find.text('测试制造商').last, findsOneWidget);
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(monthInput).controller!.text, '2008-09');
    expect(tester.widget<TextField>(manufacturer).controller!.text, '测试制造商');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加模具'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(MasterEditForm),
            matching: find.byType(TextField),
          )
          .first,
      '新增模具名称',
    );
    await tester.ensureVisible(find.byType(UtenMonthField));
    await tester.enterText(monthInput, '1999年12月');
    await tester.enterText(manufacturer, '新增制造商');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repository.created?['name'], '新增模具名称');
    expect(repository.created?['mstatus'], '1999-12');
    expect(repository.created?['manufacturer'], '新增制造商');
    expect(repository.created, isNot(contains('mfgMonth')));
    expect(tester.takeException(), isNull);
  });

  test('旧版 mfgMonth 草稿恢复到正式 mstatus 字段', () {
    final controller = MasterEditFormController(
      fields: [
        MasterFieldDef(
          key: 'mstatus',
          label: '制造年月',
          type: MasterFieldType.custom,
          legacyDraftKeys: const ['mfgMonth'],
          customBuilder: (_) => const SizedBox(),
        ),
      ],
    );
    addTearDown(controller.dispose);
    controller.restoreDraft({
      'custom': {'mfgMonth': '2008-09'},
    });
    expect(controller.buildBody(), {'mstatus': '2008-09'});
    controller.setCustom('mstatus', '2009-03');
    expect(controller.recoveredCustomInitialValue('mstatus'), '2009-03');
  });

  testWidgets('左树顶部「全部模具」总节点：走全局列表与全局 facets，不出分类维护操作', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Moulds();
    final preferences = await SharedPreferences.getInstance();
    await _pumpPage(tester, repository, preferences);
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部模具'));
    await tester.pumpAndSettle();
    expect(repository.globalListCalls, 1);
    expect(repository.globalFacetsCalls, 1);
    expect(find.text('旧模具名称'), findsOneWidget);
    expect(find.text('添加模具'), findsNothing, reason: '全部视图无所属分类，新增回具体分类做');
    expect(find.text('添加子分类'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表格模数/套数列显示老库 QTY/TQTY 口径的值', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Moulds();
    final preferences = await SharedPreferences.getInstance();
    await _pumpPage(tester, repository, preferences);
    await tester.pumpAndSettle();

    await tester.tap(find.text('历史模具'));
    await tester.pumpAndSettle();
    expect(find.text('1+1'), findsOneWidget, reason: '模数列取 qty');
    expect(find.text('12'), findsOneWidget, reason: '套数列取 tqty（整数不带小数位）');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  MouldRepository repository,
  SharedPreferences preferences,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.mouldView,
          Perm.mouldCategoryView,
          Perm.mouldEdit,
          Perm.mouldCreate,
        }),
        mouldCategoryRepositoryProvider.overrideWithValue(_Categories()),
        mouldRepositoryProvider.overrideWithValue(repository),
        mouldWorkshopTreeProvider.overrideWith(
          (ref) async => const MouldWorkshopTree(tree: [], prodDeptId: null),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MouldCategoryPage(),
      ),
    ),
  );
}

class _Categories implements MouldCategoryRepository {
  _Categories({this.id = 'cat'});
  final String id;
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: id,
      code: 'MF1',
      name: '历史模具',
      level: 0,
      children: const [],
    ),
  ];
  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      ProductCategoryDetail(
        id: id,
        code: 'MF1',
        name: '历史模具',
        level: 0,
        path: '/MF1/',
        childCount: 0,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Moulds implements MouldRepository {
  _Moulds({this.detailOverride});
  final MouldDetail? detailOverride;
  Map<String, dynamic>? saved;
  Map<String, dynamic>? created;
  int globalListCalls = 0;
  int globalFacetsCalls = 0;
  MouldDetail get record =>
      detailOverride ??
      MouldDetail(
        id: 'mould',
        categoryId: 'cat',
        categoryName: '历史模具',
        code: 'MJ001',
        name: '旧模具名称',
        status: '使用',
        mstatus: saved?['mstatus'] as String? ?? '2008年7月',
        manufacturer: saved?['manufacturer'] as String?,
        place: saved?['place'] as String? ?? '历史存放位置',
        keeper: saved?['keeper'] as String? ?? '历史保管人',
      );
  @override
  Future<PagedResult<MouldListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async => PagedResult(
    items: [
      MouldListItem(
        id: record.id,
        name: record.name,
        code: record.code,
        qty: '1+1',
        tqty: 12,
        status: record.status,
        mstatus: record.mstatus,
        manufacturer: record.manufacturer,
      ),
    ],
    page: 1,
    size: 20,
    total: 1,
    totalPages: 1,
  );
  @override
  Future<PagedResult<MouldListItem>> listGlobal({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async {
    globalListCalls++;
    return list('__all__');
  }

  @override
  Future<MouldFacets> facets(String categoryId) async =>
      const MouldFacets(fields: {}, nullCounts: {});
  @override
  Future<MouldFacets> globalFacets() async {
    globalFacetsCalls++;
    return const MouldFacets(fields: {}, nullCounts: {});
  }

  @override
  Future<MouldDetail> detail(String id) async => record;
  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    saved = Map.of(body);
  }

  @override
  Future<void> create(Map<String, dynamic> body) async {
    created = Map.of(body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
