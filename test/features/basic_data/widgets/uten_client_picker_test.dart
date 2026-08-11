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

    await tester.tap(find.text('远洋电器（C-002）'));
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
  final searchQueries = <String>[];

  static const localClient = ClientListItem(
    id: 'client-local',
    code: 'C-001',
    name: '本地客户',
    categoryId: 'domestic',
  );
  static const overseasClient = ClientListItem(
    id: 'client-overseas',
    code: 'C-002',
    name: '远洋电器',
    categoryId: 'southeast-asia',
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
  }) async {
    listCategoryIds.add(categoryId);
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
  }) async {
    searchQueries.add(keyword);
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
