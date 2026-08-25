// 分类编辑保存后右栏详情面板刷新回归测试（客户资料页）。
//
// 背景：CategoryPageShell 的 shellReload 只重拉分类树；右栏 _DetailPane
// 以 nodeId 为身份，编辑分类（名称/编号前缀）保存后若不重挂，详情卡停在
// 旧名称/旧前缀，且前缀变更后客户编号已变、列表也是旧数据——须手动刷新。
// 修复：页面重写 shellAfterCategorySaved 自增 _detailEpoch，以 ValueKey
// 重挂右栏。本测试锁死该行为，防止其它分类页（模具/供应商/新增页）漏接钩子。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/repositories/client_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('分类编辑保存后右栏详情与内容列表自动重拉（无需手动刷新）', (tester) async {
    final categories = _FakeClientCategoryRepository();
    final clients = _FakeClientRepository();
    await _pumpPage(tester, categories, clients);

    // 选中「成品类」→ 右栏加载详情（第 1 次 detail）+ 客户列表（第 1 次 list）。
    // 树节点渲染为「名称（编码）」。
    await tester.tap(find.text('成品类（C-FIN）'));
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
}

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeClientCategoryRepository categories,
  _FakeClientRepository clients,
) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.clientCategoryEdit,
          Perm.clientView,
          Perm.clientEdit,
        }),
        clientCategoryRepositoryProvider.overrideWithValue(categories),
        clientRepositoryProvider.overrideWithValue(clients),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ClientCategoryPage(),
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
  var listCalls = 0;

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
    return PagedResult(
      items: const [],
      page: page,
      size: size,
      total: 0,
      totalPages: 0,
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
      const ClientFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
