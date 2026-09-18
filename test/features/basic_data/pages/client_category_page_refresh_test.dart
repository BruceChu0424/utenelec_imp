// 分类编辑保存后右栏详情面板刷新回归测试（客户资料页）。
//
// 背景：CategoryPageShell 的 shellReload 只重拉分类树；右栏 _DetailPane
// 以 nodeId 为身份，编辑分类（名称/编号前缀）保存后若不重挂，详情卡停在
// 旧名称/旧前缀，且前缀变更后客户编号已变、列表也是旧数据——须手动刷新。
// 修复：页面重写 shellAfterCategorySaved 自增 _detailEpoch，以 ValueKey
// 重挂右栏。本测试锁死该行为，防止其它分类页（模具/供应商/新增页）漏接钩子。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/party_directory_models.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/client_category_repository.dart';
import 'package:uten_imp/features/basic_data/pages/party_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/repositories/party_directory_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('分类编辑保存后右栏详情与内容列表自动重拉(无需手动刷新)', (tester) async {
    final categories = _FakeClientCategoryRepository();
    final clients = _FakeClientRepository();
    await _pumpPage(tester, categories, clients);

    // 选中「成品类」→ 右栏加载详情（第 1 次 detail）+ 客户列表（第 1 次 list）。
    // 树节点渲染为「名称（编码）」。
    await tester.tap(find.text('成品类(C-FIN)'));
    await tester.pumpAndSettle();
    expect(categories.detailCalls('finished'), 1);
    expect(clients.listCalls, greaterThan(0));
    expect(find.text('成品类'), findsWidgets);

    // 打开编辑弹窗：改名 + 改前缀 → 保存。
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '名称',
      ),
      '成品类Pro',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 保存后：详情卡重拉（第 2 次 detail）显示新名称；内容列表也重拉
    // （前缀变更会影响客户编号）；分类树同步显示新名称。
    expect(categories.detailCalls('finished'), 2);
    expect(find.text('成品类Pro'), findsWidgets);
    expect(clients.listCallsAfterSave, isTrue);
  });

  // 2026-09-16 负责人表头筛选：服务端 empId 桶（值=员工 UUID、label=人名）remap 到
  // ownerEmployeeName 列；选桶回传服务端参数名 ownerEmployeeId。
  testWidgets('负责人表头筛选 empId 桶 remap 到列 key 并回传 ownerEmployeeId', (
    tester,
  ) async {
    final categories = _FakeClientCategoryRepository();
    final clients = _FakeClientRepository(
      facetPayload: const ClientFacets(
        fields: {
          'empId': [MasterFacetBucket(value: 'emp-1', count: 2, label: '张三')],
        },
        nullCounts: {'empId': 1},
      ),
    );
    await _pumpPage(tester, categories, clients);

    await tester.tap(find.text('成品类(C-FIN)'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<ClientListItem>>(
      find.byType(MasterDataTableView<ClientListItem>),
    );
    expect(table.facets.keys, contains('ownerEmployeeName'));
    expect(table.facets['ownerEmployeeName']?.single.label, '张三');
    expect(table.nullCounts['ownerEmployeeName'], 1);

    table.onFilterChanged('ownerEmployeeName', 'emp-1');
    await tester.pumpAndSettle();
    expect(clients.lastFilters?['ownerEmployeeId'], 'emp-1');

    // 取消筛选（选「所有」）→ 参数移除。
    final cleared = tester.widget<MasterDataTableView<ClientListItem>>(
      find.byType(MasterDataTableView<ClientListItem>),
    );
    cleared.onFilterChanged('ownerEmployeeName', null);
    await tester.pumpAndSettle();
    expect(clients.lastFilters?.containsKey('ownerEmployeeId'), isFalse);
  });

  testWidgets(
    'legacy client Credit is labeled and disabled while floor stays separate',
    (tester) async {
      final categories = _FakeClientCategoryRepository();
      final clients = _FakeClientRepository(includeLegacy: true);
      await _pumpPage(tester, categories, clients);

      await tester.tap(find.text('成品类(C-FIN)'));
      await tester.pumpAndSettle();
      expect(find.text('信用额度 / 旧库 Credit 快照'), findsOneWidget);

      // 双击行 → 客户详情整页（2026-09-14 起替代 560 宽弹窗）。
      final legacyRow = find.text('旧库客户');
      await tester.tap(legacyRow);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(legacyRow);
      await tester.pumpAndSettle();
      expect(find.text('客户详情'), findsOneWidget);

      final edit = find.widgetWithText(UtenButton, '编辑').hitTestable();
      expect(edit, findsOneWidget);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      // 2026-09-17 详情页改版：编辑态不再有「编辑客户」标题卡——各 Tab 原地变
      // 输入表单，右下悬浮组换「保存/取消」。
      expect(find.byKey(const Key('party-detail-save')), findsOneWidget);

      // 信用额度/铺底额属「财务」分组 → 在「销售条款与财务」Tab 的就地编辑表单。
      await tester.tap(find.text('销售条款与财务'));
      await tester.pumpAndSettle();
      final credit = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == '旧库 Credit 快照（只读）',
      );
      expect(credit, findsOneWidget);
      expect(tester.widget<TextField>(credit).enabled, isFalse);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.enabled != false &&
              widget.controller?.text == '50000.0',
        ),
        findsOneWidget,
      );
    },
  );
}

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeClientCategoryRepository categories,
  _FakeClientRepository clients,
) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // 2026-09-14：客户双击改为路由跳转详情整页——测试须包 GoRouter
  //（/basicinfo/client/:id 指向 PartyDetailPage，假目录仓库返回空子表）。
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const ClientCategoryPage()),
      GoRoute(
        path: '/basicinfo/client/:id',
        builder: (_, state) => PartyDetailPage(
          partyType: 'client',
          id: state.pathParameters['id']!,
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(_ReferenceApi()),
        currentPermissionsProvider.overrideWithValue({
          Perm.clientCategoryEdit,
          Perm.clientView,
          Perm.clientEdit,
        }),
        clientCategoryRepositoryProvider.overrideWithValue(categories),
        clientRepositoryProvider.overrideWithValue(clients),
        clientDirectoryRepositoryProvider.overrideWithValue(
          _FakePartyDirectoryRepository(),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 记录 detail 调用次数的假分类仓储：update 会真实改名，模拟服务端已生效。
class _FakeClientCategoryRepository implements ClientCategoryRepository {
  final _tree = <ProductCategoryNode>[
    ProductCategoryNode(
      id: 'finished',
      code: 'C-FIN',
      name: '成品类',
      level: 0,
      codePrefix: 'CP',
      children: const [],
    ),
  ];
  final _detailCalls = <String, int>{};

  int detailCalls(String id) => _detailCalls[id] ?? 0;

  @override
  Future<List<ProductCategoryNode>> tree() async => _tree;

  @override
  Future<ProductCategoryDetail> detail(String id) async {
    _detailCalls[id] = (_detailCalls[id] ?? 0) + 1;
    final node = _tree.firstWhere((n) => n.id == id);
    return ProductCategoryDetail(
      id: node.id,
      code: node.code,
      name: node.name,
      level: node.level,
      path: node.name,
      childCount: 0,
      codePrefix: node.codePrefix,
      effectivePrefix: node.codePrefix,
    );
  }

  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) async {
    final i = _tree.indexWhere((n) => n.id == id);
    _tree[i] = ProductCategoryNode(
      id: id,
      code: _tree[i].code,
      name: input.name,
      level: _tree[i].level,
      codePrefix: input.codePrefix,
      children: const [],
    );
    // 注意：直接构造返回值，不走 detail() —— 调用计数只反映页面真实的详情重拉。
    final node = _tree[i];
    return ProductCategoryDetail(
      id: node.id,
      code: node.code,
      name: node.name,
      level: node.level,
      path: node.name,
      childCount: 0,
      codePrefix: node.codePrefix,
      effectivePrefix: node.codePrefix,
    );
  }

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) async => CategoryPrefixPreview(
    categoryId: id,
    currentPrefix: 'CP',
    requestedPrefix: prefix,
    resultingEffectivePrefix: prefix,
    affectedRecords: 0,
    customOrLegacyRecords: 0,
    descendantOverrides: 0,
    conflicts: 0,
    conflictSamples: const [],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假客户仓储：记录 list 调用；保存后若列表重拉，调用次数会增加。
class _FakeClientRepository implements ClientRepository {
  _FakeClientRepository({this.includeLegacy = false, this.facetPayload});

  final bool includeLegacy;

  /// 表头 facet 下发内容（默认空 = 下拉无可选项）。
  final ClientFacets? facetPayload;
  var listCalls = 0;

  /// 最近一次 list 收到的表头筛选（服务端参数名口径）。
  Map<String, String?>? lastFilters;

  /// 初始选中加载过一次后，是否又因分类保存重拉过列表。
  bool get listCallsAfterSave => listCalls > 1;

  @override
  Future<PagedResult<ClientListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeLegacyFinanceStub = true,
    bool selectableOnly = false,
  }) async {
    listCalls++;
    lastFilters = Map<String, String?>.of(filters);
    return PagedResult(
      items: includeLegacy
          ? const [
              ClientListItem(
                id: 'legacy-client',
                code: 'OLD-001',
                name: '旧库客户',
                categoryId: 'finished',
                credit: 50000,
                creditFloor: 50000,
                salesPaymentType: ClientSalesPaymentType.monthly,
                status: '使用',
                legacyId: 101,
                writable: true,
              ),
            ]
          : const [],
      page: page,
      size: size,
      total: includeLegacy ? 1 : 0,
      totalPages: 1,
    );
  }

  @override
  Future<PagedResult<ClientListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    bool excludeLegacyFinanceStub = true,
    bool selectableOnly = false,
  }) async => PagedResult(
    items: const [],
    page: page,
    size: size,
    total: 0,
    totalPages: 0,
  );

  @override
  Future<ClientFacets> facets(String categoryId) async =>
      facetPayload ?? const ClientFacets(fields: {}, nullCounts: {});

  @override
  Future<ClientDetail> detail(String id) async => const ClientDetail(
    id: 'legacy-client',
    code: 'OLD-001',
    name: '旧库客户',
    categoryId: 'finished',
    credit: 50000,
    creditFloor: 50000,
    salesPaymentType: ClientSalesPaymentType.monthly,
    defaultSettlementMethodId: 'settlement-1',
    defaultSettlementMethodName: '月结',
    status: '使用',
    legacyId: 101,
    writable: true,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 详情整页子表（联系方式/地址/跟进记录）假仓库：全部为空，专注本测试口径。
class _FakePartyDirectoryRepository implements PartyDirectoryRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  PartyDirectoryType get type => PartyDirectoryType.client;

  @override
  Future<List<PartyContactMethod>> contactMethods(String partyId) async => [];

  @override
  Future<void> addContactMethod(
    String partyId, {
    required String kind,
    required String value,
    bool primary = false,
    String? remark,
  }) async {}

  @override
  Future<void> deleteContactMethod(String partyId, String contactId) async {}

  @override
  Future<List<PartyAddress>> addresses(String partyId) async => [];

  @override
  Future<void> addAddress(
    String partyId, {
    required String kind,
    required String address,
    bool defaultAddress = false,
    String? remark,
  }) async {}

  @override
  Future<void> deleteAddress(String partyId, String addressId) async {}

  @override
  Future<List<PartyActivityRecord>> activityRecords(String partyId) async => [];

  @override
  Future<void> addActivityRecord(
    String partyId, {
    required String kind,
    required String content,
    int scoreDelta = 0,
  }) async {}

  @override
  Future<int?> creditScore(String partyId) async => null;
}

class _ReferenceApi extends ApiClient {
  _ReferenceApi() : super(Dio());

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [
    {'id': 'settlement-1', 'code': 'MONTHLY', 'name': '月结'},
  ];
}
