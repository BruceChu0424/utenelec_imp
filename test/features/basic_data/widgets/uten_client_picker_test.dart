import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/client_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_client_picker.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('宽屏只保留左侧统一搜索且客户结果可跨分类回填', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);

    final sheet = _widePickerSheet();
    expect(sheet, findsOneWidget);
    final searchFields = find.descendant(
      of: sheet,
      matching: find.byType(TextField),
    );
    expect(searchFields, findsOneWidget);
    expect(
      tester.widget<TextField>(searchFields).decoration?.hintText,
      '搜索分类/客户',
    );

    await tester.enterText(
      find.byKey(const Key('uten-client-picker-search')),
      '远洋',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(clientRepository.searchQueries, ['远洋']);
    expect(find.text('远洋电器（C-002）'), findsOneWidget);
    expect(find.text('本地客户（C-001）'), findsNothing);

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.showSearch, isFalse);
    expect(tree.visibleFilterIds, {'overseas', 'southeast-asia'});
    expect(tree.selectedIds, {'southeast-asia'});

    // 点击包含客户命中的父分类仍保留左侧查询，并用「分类 + 查询词」刷新右侧。
    await tester.tap(find.text('海外客户（OVERSEAS）'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('uten-client-picker-search')))
          .controller
          ?.text,
      '远洋',
    );
    expect(clientRepository.listKeywords.last, '远洋');

    await tester.tap(find.text('远洋电器（C-002）'));
    await tester.pumpAndSettle();
    // 二次操作契约：点行仅高亮（底栏显示已选择），还需点「确定」才选中返回。
    expect(find.text('已选择：远洋电器（C-002）'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('selected-client-name')), findsOneWidget);
    expect(find.text('已选择：远洋电器'), findsOneWidget);
  });

  testWidgets('搜索分类名称时定位分类并在右侧展示该分类客户', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);
    await tester.enterText(
      find.byKey(const Key('uten-client-picker-search')),
      '海外客户',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(clientRepository.searchQueries, ['海外客户']);
    expect(clientRepository.listCategoryIds.last, 'overseas');
    expect(find.text('远洋电器（C-002）'), findsOneWidget);

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.visibleFilterIds, {'overseas', 'southeast-asia'});
    expect(tree.selectedIds, {'overseas'});

    // 纯分类命中不退出左树搜索，也不得把分类词当作客户过滤词。
    await tester.tap(find.text('海外客户（OVERSEAS）'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('uten-client-picker-search')))
          .controller
          ?.text,
      '海外客户',
    );
    expect(clientRepository.listKeywords.last, isNull);
    expect(clientRepository.excludeLegacyFlags.last, isTrue);
  });

  testWidgets('客户搜索会汇总全部分页的分类用于完整展开', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);
    await tester.enterText(
      find.byKey(const Key('uten-client-picker-search')),
      '集团',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(clientRepository.searchPages, [1, 2]);
    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.visibleFilterIds, {'domestic', 'overseas', 'southeast-asia'});
  });

  testWidgets('服务端可选客户口径决定结果数量和页数', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);
    await tester.enterText(
      find.byKey(const Key('uten-client-picker-search')),
      '含占位',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(clientRepository.searchPages, [1]);
    expect(find.text('历史财务占位（LEGACY-FIN-CL-001）'), findsNothing);
    expect(find.text('远洋电器（C-002）'), findsOneWidget);
    // 服务端过滤在分页前完成；有效结果仅一页时分页条应隐藏。
    expect(find.text('1 / 2'), findsNothing);
    expect(clientRepository.excludeLegacyFlags, everyElement(isTrue));
    expect(clientRepository.selectableOnlyFlags, everyElement(isTrue));
  });

  testWidgets('紧凑端底部滑窗使用同一统一搜索且无布局异常', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(375, 812),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);

    expect(_compactPickerSheet(const Size(375, 812)), findsOneWidget);
    expect(find.byKey(const Key('uten-client-picker-search')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(
      find.byKey(const Key('uten-client-picker-search')),
      '远洋',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(find.text('远洋电器（C-002）').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('远洋电器（C-002）'));
    await tester.pumpAndSettle();
    // 二次操作契约：点行仅高亮，还需点「确定」才选中返回。
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：远洋电器'), findsOneWidget);
  });
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  required Size size,
  required ClientRepository clientRepository,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clientCategoryRepositoryProvider.overrideWithValue(
          _FakeClientCategoryRepository(),
        ),
        clientRepositoryProvider.overrideWithValue(clientRepository),
      ],
      child: const MaterialApp(home: _PickerHarness()),
    ),
  );
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-client-picker')));
  await tester.pumpAndSettle();
  expect(find.text('选择客户'), findsOneWidget);
}

Finder _widePickerSheet() => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == 720 &&
      widget.height == double.infinity,
);

Finder _compactPickerSheet(Size surfaceSize) => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == null &&
      widget.height != null &&
      (widget.height! - surfaceSize.height * 0.85).abs() < 0.01,
);

class _PickerHarness extends ConsumerStatefulWidget {
  const _PickerHarness();

  @override
  ConsumerState<_PickerHarness> createState() => _PickerHarnessState();
}

class _PickerHarnessState extends ConsumerState<_PickerHarness> {
  String? _selectedName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ElevatedButton(
            key: const Key('open-client-picker'),
            onPressed: () async {
              final selected = await showUtenClientPicker(context, ref);
              if (!mounted || selected == null) return;
              setState(
                () => _selectedName = selected.name ?? selected.fullName,
              );
            },
            child: const Text('打开客户选择'),
          ),
          Text(
            _selectedName == null ? '未选择' : '已选择：$_selectedName',
            key: const Key('selected-client-name'),
          ),
        ],
      ),
    );
  }
}

class _FakeClientCategoryRepository implements ClientCategoryRepository {
  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> tree() async => _clientTree();

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) =>
      throw UnsupportedError('not used');

  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDetail> detail(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> subtree(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) => throw UnsupportedError('not used');
}

class _FakeClientRepository implements ClientRepository {
  final listCategoryIds = <String>[];
  final listKeywords = <String?>[];
  final searchQueries = <String>[];
  final searchPages = <int>[];
  final excludeLegacyFlags = <bool>[];
  final selectableOnlyFlags = <bool>[];

  static const localClient = ClientListItem(
    id: 'client-local',
    code: 'C-001',
    name: '本地客户',
    categoryId: 'domestic',
    status: '使用',
  );
  static const overseasClient = ClientListItem(
    id: 'client-overseas',
    code: 'C-002',
    name: '远洋电器',
    categoryId: 'southeast-asia',
    status: '使用',
  );
  static const legacyFinanceStub = ClientListItem(
    id: 'client-legacy-finance-stub',
    code: 'LEGACY-FIN-CL-001',
    name: '历史财务占位',
    categoryId: 'domestic',
  );

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
    excludeLegacyFlags.add(excludeLegacyFinanceStub);
    selectableOnlyFlags.add(selectableOnly);
    listCategoryIds.add(categoryId);
    listKeywords.add(keyword);
    final items = switch (categoryId) {
      'domestic' => const [localClient],
      'overseas' || 'southeast-asia' => const [overseasClient],
      _ => const <ClientListItem>[],
    };
    return _page(items, page: page, size: size);
  }

  @override
  Future<PagedResult<ClientListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    bool excludeLegacyFinanceStub = true,
    bool selectableOnly = false,
  }) async {
    excludeLegacyFlags.add(excludeLegacyFinanceStub);
    selectableOnlyFlags.add(selectableOnly);
    searchQueries.add(keyword);
    searchPages.add(page);
    if (keyword == '集团') {
      return PagedResult(
        items: page == 1 ? const [localClient] : const [overseasClient],
        page: page,
        size: size,
        total: 2,
        totalPages: 2,
      );
    }
    if (keyword == '含占位') {
      if (selectableOnly && excludeLegacyFinanceStub) {
        return PagedResult(
          items: const [overseasClient],
          page: 1,
          size: size,
          total: 1,
          totalPages: 1,
        );
      }
      return PagedResult(
        items: page == 1 ? const [legacyFinanceStub] : const [overseasClient],
        page: page,
        size: size,
        total: 2,
        totalPages: 2,
      );
    }
    final items = keyword == '远洋'
        ? const [overseasClient]
        : const <ClientListItem>[];
    return _page(items, page: page, size: size);
  }

  @override
  Future<void> create(Map<String, dynamic> body) =>
      throw UnsupportedError('not used');

  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');

  @override
  Future<ClientDetail> detail(String id) => throw UnsupportedError('not used');

  @override
  Future<ClientFacets> facets(String categoryId) =>
      throw UnsupportedError('not used');

  @override
  Future<void> update(String id, Map<String, dynamic> body) =>
      throw UnsupportedError('not used');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PagedResult<ClientListItem> _page(
  List<ClientListItem> items, {
  required int page,
  required int size,
}) => PagedResult(
  items: items,
  page: page,
  size: size,
  total: items.length,
  totalPages: 1,
);

List<ProductCategoryNode> _clientTree() => [
  ProductCategoryNode(
    id: 'domestic',
    code: 'DOMESTIC',
    name: '国内客户',
    level: 0,
    children: const [],
  ),
  ProductCategoryNode(
    id: 'overseas',
    code: 'OVERSEAS',
    name: '海外客户',
    level: 0,
    children: [
      ProductCategoryNode(
        id: 'southeast-asia',
        code: 'SEA',
        name: '东南亚客户',
        level: 1,
        parentId: 'overseas',
        children: const [],
      ),
    ],
  ),
];
