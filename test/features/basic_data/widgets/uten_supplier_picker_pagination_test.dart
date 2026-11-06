import 'package:uten_imp/features/basic_data/repositories/business_reference_repository.dart';
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_supplier_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import '../../../support/table_read_status.dart';

class _Categories implements SupplierCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'A',
      code: 'A',
      name: '甲类',
      level: 0,
      children: const [],
    ),
    ProductCategoryNode(
      id: 'B',
      code: 'B',
      name: '乙类',
      level: 0,
      children: const [],
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Suppliers implements SupplierRepository {
  final requests = <(String, int)>[];
  final selectableOnlyFlags = <bool>[];
  final deferred = <(String, int), Completer<PagedResult<SupplierListItem>>>{};

  Completer<PagedResult<SupplierListItem>> hold(String category, int page) {
    final response = Completer<PagedResult<SupplierListItem>>();
    deferred[(category, page)] = response;
    return response;
  }

  @override
  Future<PagedResult<SupplierListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool selectableOnly = false,
  }) async {
    requests.add((categoryId, page));
    selectableOnlyFlags.add(selectableOnly);
    final response = deferred.remove((categoryId, page));
    return response == null ? _page(categoryId, page) : response.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PagedResult<SupplierListItem> _page(String category, int page) => PagedResult(
  items: [
    for (var index = 0; index < 20; index++)
      SupplierListItem(
        id: '$category-$page-$index',
        name: '$category-委外商$page-$index',
        categoryId: category,
        status: '使用',
        linkman: '联系人 $index',
        mobile: '  ',
        phone: '0755-8000$index',
        place: '广东',
        bankAccount: '不应显示的银行账号',
      ),
  ],
  page: page,
  size: 20,
  total: 80,
  totalPages: 4,
  readScopeVersion: 'business-suppliers-access-v1',
);

class _Harness extends ConsumerStatefulWidget {
  const _Harness();

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  String? pickedId;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        ElevatedButton(
          onPressed: () async {
            final picked = await showUtenSupplierPicker(
              context,
              ref,
              title: '选择委外商',
            );
            if (mounted) setState(() => pickedId = picked?.id);
          },
          child: const Text('打开委外商选择'),
        ),
        Text(pickedId ?? '未选择', key: const Key('supplier-result')),
      ],
    ),
  );
}

Future<void> _open(
  WidgetTester tester,
  _Suppliers suppliers, {
  Size size = const Size(1200, 900),
  bool settle = true,
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
        currentPermissionsProvider.overrideWithValue(const {}),
        businessSupplierCategoryRepositoryProvider.overrideWithValue(
          _Categories(),
        ),
        businessSupplierReferenceRepositoryProvider.overrideWithValue(
          suppliers,
        ),
      ],
      child: const MaterialApp(home: _Harness()),
    ),
  );
  await tester.tap(find.text('打开委外商选择'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  expect(find.text('选择委外商'), findsOneWidget);
}

Future<void> _pumpToRequests(
  WidgetTester tester,
  _Suppliers suppliers,
  int count,
) async {
  for (
    var frame = 0;
    frame < 30 &&
        (suppliers.requests.length < count || _picker.evaluate().isEmpty);
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(suppliers.requests, hasLength(count));
  expect(
    _picker,
    findsOneWidget,
    reason:
        'The deferred panel body must be admitted before interacting with its controls.',
  );
}

Finder get _picker => find.byType(MasterDataTableView<SupplierListItem>);

ScrollableState _scrollable(WidgetTester tester) {
  final row = find
      .descendant(of: _picker, matching: find.textContaining('委外商'))
      .first;
  return Scrollable.of(tester.element(row), axis: Axis.vertical);
}

Future<void> _edge(
  WidgetTester tester, {
  required bool top,
  bool settle = true,
}) async {
  final position = _scrollable(tester).position;
  position.jumpTo(top ? position.minScrollExtent : position.maxScrollExtent);
  // Bounded tables admit offscreen business rows over successive frames.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // An intentionally held page keeps loading feedback animating. Admit
    // bounded row frames without waiting for that network gate to complete.
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
}

Future<void> _wheel(WidgetTester tester, double dy) async {
  final position = _scrollable(tester);
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(
      tester.getCenter(
        find.byElementPredicate(
          (element) => identical(element, position.context),
        ),
      ),
    ),
  );
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('供应商业务表格只显示编号名称状态，不显示联系方式', (tester) async {
    await _open(tester, _Suppliers());
    final table = tester.widget<MasterDataTableView<SupplierListItem>>(_picker);
    expect(table.columns.map((column) => column.label), ['编号', '供应商名称', '状态']);
    expect(table.tableKey, isNull);
    expect(find.text('0755-80000'), findsNothing);
    expect(find.text('不应显示的银行账号'), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'supplier complete refresh retains the original choice until confirmation',
    (tester) async {
      final suppliers = _Suppliers();
      await _open(tester, suppliers);
      await tester.tap(find.text('A-委外商1-0'));
      await tester.pumpAndSettle();
      expect(find.text('已选择：A-委外商1-0'), findsOneWidget);

      MasterDataTableView<SupplierListItem> table() => tester.widget(_picker);
      final originalRows = table().items;
      expect(originalRows, hasLength(80));
      final before = suppliers.requests.length;
      final response = suppliers.hold('A', 2);
      table().onRetry!();
      await _pumpToRequests(tester, suppliers, before + 2);
      expect(suppliers.requests.skip(before), [('A', 1), ('A', 2)]);
      expect(table().items, same(originalRows));
      expect(find.text('已选择：A-委外商1-0'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
            .onPressed,
        isNull,
      );
      response.complete(_page('A', 2));
      await tester.pumpAndSettle();
      expect(table().items, hasLength(80));
      expect(table().items.map((item) => item.id).toSet(), hasLength(80));
      expect(suppliers.requests.skip(before), [
        ('A', 1),
        ('A', 2),
        ('A', 3),
        ('A', 4),
      ]);
      final completeReads = suppliers.requests.length;
      await _edge(tester, top: false);
      await tester.pumpAndSettle();
      expect(find.text('A-委外商4-19'), findsOneWidget);
      await _edge(tester, top: true);
      await tester.pumpAndSettle();
      expect(suppliers.requests, hasLength(completeReads));
      expect(table().currentPage, 1);
      expect(table().totalPages, 1);
      expect(find.widgetWithText(TextField, '1'), findsNothing);
      expect(find.text('A-委外商1-0'), findsOneWidget);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('A-1-0'), findsOneWidget);
      expect(suppliers.selectableOnlyFlags, everyElement(isTrue));
      expect(find.text('添加供应商'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'supplier local scrolling preserves the complete rows and original choice',
    (tester) async {
      final suppliers = _Suppliers();
      await _open(tester, suppliers);
      MasterDataTableView<SupplierListItem> table() => tester.widget(_picker);
      final originalRows = table().items;
      final originalColumns = table().columns;
      expect(originalRows, hasLength(80));
      final before = suppliers.requests.length;
      await _edge(tester, top: false);
      await _wheel(tester, -150);
      await tester.pumpAndSettle();
      expect(suppliers.requests, [('A', 1), ('A', 2), ('A', 3), ('A', 4)]);
      expect(table().items, same(originalRows));
      expect(table().columns, same(originalColumns));

      await _edge(tester, top: false);
      await _wheel(tester, 150);
      await tester.pumpAndSettle();
      expect(suppliers.requests.last, ('A', 4));
      await _edge(tester, top: true);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('A-委外商2-0'),
        200,
        scrollable: find.byWidget(_scrollable(tester).widget),
      );
      await tester.pumpAndSettle();
      expect(suppliers.requests, hasLength(before));
      expect(find.text('A-委外商2-0').hitTestable(), findsOneWidget);
      await tester.tap(find.text('A-委外商2-0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('A-2-0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'supplier incomplete read publishes no prefix and retries the complete scope',
    (tester) async {
      final suppliers = _Suppliers();
      final failed = suppliers.hold('A', 2);
      await _open(tester, suppliers, settle: false);
      await _pumpToRequests(tester, suppliers, 2);
      expect(
        tester.widget<MasterDataTableView<SupplierListItem>>(_picker).items,
        isEmpty,
      );
      failed.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<SupplierListItem>>(
        _picker,
      );
      expect(table.items, isEmpty);
      expect(table.error, isNotNull);
      expect(suppliers.requests, [('A', 1), ('A', 2)]);
      await expectTableReadFailureDetails(tester, '加载供应商失败，请稍后重试');
      final retried = suppliers.hold('A', 2);
      await tester.tap(find.text('重试'));
      await _pumpToRequests(tester, suppliers, 4);
      expect(suppliers.requests, [('A', 1), ('A', 2), ('A', 1), ('A', 2)]);
      retried.complete(_page('A', 2));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MasterDataTableView<SupplierListItem>>(_picker).items,
        hasLength(80),
      );
      expect(suppliers.requests.skip(2), [
        ('A', 1),
        ('A', 2),
        ('A', 3),
        ('A', 4),
      ]);
      await _edge(tester, top: true);
      expect(find.text('A-委外商1-0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact supplier category switch ignores a pending old page', (
    tester,
  ) async {
    final suppliers = _Suppliers();
    final oldResponse = suppliers.hold('A', 2);
    await _open(tester, suppliers, size: const Size(375, 812), settle: false);
    await _pumpToRequests(tester, suppliers, 2);
    expect(suppliers.requests, [('A', 1), ('A', 2)]);
    expect(
      find.byIcon(Icons.account_tree_rounded).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.account_tree_rounded));
    await tester.pump();
    await tester.tap(find.text('乙类'));
    await tester.pumpAndSettle();
    expect(suppliers.requests.skip(2), [
      ('B', 1),
      ('B', 2),
      ('B', 3),
      ('B', 4),
    ]);
    oldResponse.complete(_page('A', 2));
    await tester.pumpAndSettle();
    expect(find.text('B-委外商1-0'), findsOneWidget);
    expect(find.text('A-委外商2-0'), findsNothing);
    final pageWindow = tester.widget<MasterDataTableView<SupplierListItem>>(
      find.byType(MasterDataTableView<SupplierListItem>),
    );
    expect(pageWindow.currentPage, 1);
    expect(pageWindow.totalPages, 1);
    expect(pageWindow.items, hasLength(80));
    expect(pageWindow.items.every((item) => item.categoryId == 'B'), isTrue);
    expect(suppliers.requests.where((query) => query.$1 == 'A'), [
      ('A', 1),
      ('A', 2),
    ]);
    await tester.tap(find.text('B-委外商1-0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('B-1-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
