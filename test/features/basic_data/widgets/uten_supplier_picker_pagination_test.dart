import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
        supplierCategoryRepositoryProvider.overrideWithValue(_Categories()),
        supplierRepositoryProvider.overrideWithValue(suppliers),
      ],
      child: const MaterialApp(home: _Harness()),
    ),
  );
  await tester.tap(find.text('打开委外商选择'));
  await tester.pumpAndSettle();
  expect(find.text('选择委外商'), findsOneWidget);
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
  testWidgets('供应商表格只展示重点字段并保留固定电话回退', (tester) async {
    await _open(tester, _Suppliers());
    final table = tester.widget<MasterDataTableView<SupplierListItem>>(_picker);
    expect(table.columns.map((column) => column.label), [
      '供应商名称',
      '联系人',
      '联系电话',
      '地区',
    ]);
    expect(table.tableKey, isNull);
    expect(find.text('0755-80000'), findsOneWidget);
    expect(find.text('不应显示的银行账号'), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('supplier append keeps an earlier selection until confirmation', (
    tester,
  ) async {
    final suppliers = _Suppliers();
    final response = suppliers.hold('A', 2);
    await _open(tester, suppliers);
    await tester.tap(find.text('A-委外商1-0'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：A-委外商1-0'), findsOneWidget);

    await _edge(tester, top: false, settle: false);
    await _wheel(tester, 150);
    await _wheel(tester, 150);
    expect(suppliers.requests, [('A', 1), ('A', 2)]);
    expect(_picker, findsOneWidget, reason: 'loading retains the same list');
    expect(find.text('已选择：A-委外商1-0'), findsOneWidget);
    response.complete(_page('A', 2));
    await tester.pumpAndSettle();
    // The first page remains under the viewport's top until we scroll farther.
    expect(find.widgetWithText(TextField, '1'), findsOneWidget);
    await _edge(tester, top: false);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '2'), findsOneWidget);
    expect(suppliers.requests, [('A', 1), ('A', 2), ('A', 3), ('A', 4)]);
    await _edge(tester, top: true);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '1'), findsOneWidget);
    expect(find.text('A-委外商1-0'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('A-1-0'), findsOneWidget);
    expect(suppliers.selectableOnlyFlags, everyElement(isTrue));
    expect(find.text('添加供应商'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'supplier prepend preserves rows and next load skips cached pages',
    (tester) async {
      final suppliers = _Suppliers();
      await _open(tester, suppliers);
      await tester
          .widget<MasterDataTableView<SupplierListItem>>(_picker)
          .onPageChange!(3);
      await tester.pumpAndSettle();
      expect(find.text('A-委外商3-0'), findsOneWidget);
      final oldRowTop = tester.getTopLeft(find.text('A-委外商3-0')).dy;
      await _wheel(tester, -150);
      await tester.pumpAndSettle();
      expect(suppliers.requests, [('A', 1), ('A', 2), ('A', 3), ('A', 4)]);
      expect(
        tester.getTopLeft(find.text('A-委外商3-0')).dy,
        closeTo(oldRowTop, 1),
      );
      expect(find.widgetWithText(TextField, '3'), findsOneWidget);

      await _edge(tester, top: false);
      await _wheel(tester, 150);
      await tester.pumpAndSettle();
      expect(suppliers.requests.last, ('A', 4));
      await _edge(tester, top: true);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '2'), findsOneWidget);
      await tester.tap(find.text('A-委外商2-0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('A-2-0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'supplier failed next page retains page and retries the same page',
    (tester) async {
      final suppliers = _Suppliers();
      final failed = suppliers.hold('A', 2);
      await _open(tester, suppliers);
      await _edge(tester, top: false, settle: false);
      await _wheel(tester, 150);
      failed.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '1'), findsOneWidget);
      await _edge(tester, top: false);
      await _wheel(tester, 150);
      expect(suppliers.requests, [('A', 1), ('A', 2)]);
      await expectTableReadFailureDetails(
        tester,
        '加载供应商失败，请稍后重试',
        keyPrefix: 'master-table-page-read',
      );
      final retried = suppliers.hold('A', 2);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(suppliers.requests, [('A', 1), ('A', 2), ('A', 2)]);
      retried.complete(_page('A', 2));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '1'), findsOneWidget);
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
    await _open(tester, suppliers, size: const Size(375, 812));
    await _edge(tester, top: false, settle: false);
    await _wheel(tester, 150);
    expect(suppliers.requests, [('A', 1), ('A', 2)]);
    await tester.tap(find.byIcon(Icons.account_tree_rounded));
    await tester.pump();
    await tester.tap(find.text('乙类'));
    await tester.pumpAndSettle();
    expect(suppliers.requests.last, ('B', 1));
    oldResponse.complete(_page('A', 2));
    await tester.pumpAndSettle();
    expect(find.text('B-委外商1-0'), findsOneWidget);
    expect(find.text('A-委外商2-0'), findsNothing);
    final pageWindow = tester.widget<MasterDataTableView<SupplierListItem>>(
      find.byType(MasterDataTableView<SupplierListItem>),
    );
    expect(pageWindow.currentPage, 1);
    expect(pageWindow.totalPages, 4);
    await tester.tap(find.text('B-委外商1-0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('B-1-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
