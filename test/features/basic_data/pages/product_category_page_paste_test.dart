import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/providers/goods_clipboard.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/product_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _source = GoodsDetail(
  id: 'source-goods',
  code: 'SRC001',
  name: '测试插座',
  nameEn: 'SOURCE SOCKET',
  categoryId: 'source-category',
  status: '使用',
  spec: '三极',
  model: 'P10',
  unitId: 'unit-piece',
  colorId: 'color-white',
  owningWarehouseId: 'warehouse-1',
  price: 20,
  discount: 0.9,
  version: 8,
);

const _component = GoodsBomItem(
  id: 'source-bom',
  componentGoodsId: 'component-1',
  qty: 2,
  summary: '原组件说明',
  colorId: 'component-color',
  defaultSupplierId: 'supplier-1',
);

Future<void> _rightClickAt(WidgetTester tester, Offset position) async {
  final gesture = await tester.startGesture(
    position,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Finder get _table => find.byType(MasterDataTableView<GoodsListItem>);

Future<void> _rightClickBlank(WidgetTester tester) async {
  final rect = tester.getRect(_table);
  // Hit the full empty viewport, away from the centered empty-state message.
  await _rightClickAt(tester, rect.bottomLeft + const Offset(45, -60));
}

Future<void> _pumpPage(
  WidgetTester tester,
  _GoodsRepository goods,
  _BomRepository bom, {
  bool canCreate = true,
  bool withClipboard = false,
  Size surfaceSize = const Size(1600, 900),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          if (canCreate) Perm.goodsCreate,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        productCategoryRepositoryProvider.overrideWithValue(_Categories()),
        goodsRepositoryProvider.overrideWithValue(goods),
        goodsBomRepositoryProvider.overrideWithValue(bom),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductCategoryPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (withClipboard) {
    ProviderScope.containerOf(tester.element(find.byType(ProductCategoryPage)))
        .read(goodsClipboardProvider.notifier)
        .copyGoods(
          const GoodsCopyClip(detail: _source, bomItems: [_component]),
        );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('复制源分类货品后在空目标分类空白处粘贴，副本与组件写入目标且立即显示', (tester) async {
    final goods = _GoodsRepository();
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom);
    await tester.tap(find.text('原分类(SRC)'));
    await tester.pumpAndSettle();
    await _rightClickAt(tester, tester.getCenter(find.text(_source.name!)));
    await tester.tap(find.text('复制货品'));
    await tester.pumpAndSettle();
    expect(goods.detailCalls, [_source.id]);
    expect(bom.listCalls, [_source.id]);

    await tester.tap(find.text('新分类(DST)'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).items,
      isEmpty,
    );
    await _rightClickBlank(tester);
    expect(find.text('粘贴货品'), findsOneWidget);
    expect(find.text('复制货品'), findsNothing);
    await tester.tap(find.text('粘贴货品'));
    await tester.pumpAndSettle();

    final body = goods.created.single;
    expect(body['categoryId'], 'target-category');
    expect(body['name'], '测试插座(1)');
    expect(body['spec'], _source.spec);
    expect(body['model'], _source.model);
    expect(body['unitId'], _source.unitId);
    expect(body['colorId'], _source.colorId);
    expect(body['owningWarehouseId'], _source.owningWarehouseId);
    for (final key in [
      'id',
      'code',
      'version',
      'nameEn',
      'price',
      'discount',
    ]) {
      expect(body, isNot(contains(key)), reason: 'Copies must not reuse $key');
    }
    final pasted = bom.pasted.single;
    expect(pasted.mode, BomPasteMode.append);
    expect(pasted.targets.single.goodsId, 'copy-1');
    expect(
      pasted.items.single['componentGoodsId'],
      _component.componentGoodsId,
    );
    expect(pasted.items.single['qty'], 2);
    expect(pasted.items.single['summary'], _component.summary);
    expect(pasted.items.single['colorId'], _component.colorId);
    expect(
      pasted.items.single['defaultSupplierId'],
      _component.defaultSupplierId,
    );
    expect(pasted.items.single, isNot(contains('id')));
    expect(find.text('测试插座(1)'), findsOneWidget);
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).items.single.id,
      'copy-1',
    );
    expect(tester.takeException(), isNull);
  });

  for (final canCreate in [false, true]) {
    testWidgets(canCreate ? '空分类剪贴板为空时粘贴禁用' : '空分类没有新增权限时粘贴禁用', (tester) async {
      final goods = _GoodsRepository();
      final bom = _BomRepository();
      await _pumpPage(
        tester,
        goods,
        bom,
        canCreate: canCreate,
        withClipboard: !canCreate,
      );
      await tester.tap(find.text('新分类(DST)'));
      await tester.pumpAndSettle();
      await _rightClickBlank(tester);
      for (final label in ['粘贴货品', '批量粘贴…']) {
        final item = find.ancestor(
          of: find.text(label),
          matching: find.byType(InkWell),
        );
        expect(tester.widget<InkWell>(item).onTap, isNull);
      }
      expect(goods.created, isEmpty);
      expect(bom.pasted, isEmpty);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('空分类批量粘贴所有副本进入当前分类并显示', (tester) async {
    final goods = _GoodsRepository();
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom, withClipboard: true);
    await tester.tap(find.text('新分类(DST)'));
    await tester.pumpAndSettle();
    await _rightClickBlank(tester);
    await tester.tap(find.text('批量粘贴…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline_rounded));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '粘贴'));
    await tester.pumpAndSettle();
    expect(goods.created, hasLength(2));
    expect(
      goods.created.map((body) => body['categoryId']),
      everyElement('target-category'),
    );
    expect(bom.pasted, hasLength(2));
    expect(bom.pasted.map((call) => call.targets.single.goodsId), [
      'copy-1',
      'copy-2',
    ]);
    expect(find.text('测试插座(1)'), findsOneWidget);
    expect(find.text('测试插座(2)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('粘贴跨过分页边界后自动进入新末页并显示副本', (tester) async {
    final goods = _GoodsRepository(targetCount: 20);
    final bom = _BomRepository();
    await _pumpPage(tester, goods, bom, withClipboard: true);
    await tester.tap(find.text('新分类(DST)'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MasterDataTableView<GoodsListItem>>(_table).currentPage,
      1,
    );
    await _rightClickAt(tester, tester.getCenter(find.text('已有货品 1')));
    await tester.tap(find.text('粘贴货品'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<GoodsListItem>>(_table);
    expect(table.currentPage, 2);
    expect(table.totalPages, 2);
    expect(table.items.single.id, 'copy-1');
    expect(goods.mainPageRequests.last, (
      categoryId: 'target-category',
      page: 2,
      sort: 'code',
      order: 'asc',
    ));
    expect(find.text('测试插座(1)').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量粘贴后进入末页并自动滚动到超出视口的最后副本', (tester) async {
    final goods = _GoodsRepository(targetCount: 35);
    final bom = _BomRepository();
    await _pumpPage(
      tester,
      goods,
      bom,
      withClipboard: true,
      surfaceSize: const Size(1600, 600),
    );
    await tester.tap(find.text('新分类(DST)'));
    await tester.pumpAndSettle();
    await _rightClickAt(tester, tester.getCenter(find.text('已有货品 1')));
    await tester.tap(find.text('批量粘贴…'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.add_circle_outline_rounded));
      await tester.pump();
    }
    await tester.tap(find.widgetWithText(FilledButton, '粘贴'));
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<GoodsListItem>>(_table);
    expect(goods.created, hasLength(5));
    expect(table.currentPage, 2);
    expect(table.items, hasLength(20));
    expect(table.items.last.id, 'copy-5');
    expect(goods.mainPageRequests.last, (
      categoryId: 'target-category',
      page: 2,
      sort: 'code',
      order: 'asc',
    ));
    // No tester drag/ensureVisible: the product must scroll its own viewport.
    expect(find.text('测试插座(5)').hitTestable(), findsOneWidget);
    expect(find.text('已有货品 21').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Categories implements ProductCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    for (final source in [true, false])
      ProductCategoryNode(
        id: source ? 'source-category' : 'target-category',
        code: source ? 'SRC' : 'DST',
        name: source ? '原分类' : '新分类',
        level: 0,
        codePrefix: source ? 'SRC' : 'DST',
        children: const [],
      ),
  ];

  @override
  Future<ProductCategoryDetail> detail(String id) async =>
      ProductCategoryDetail(
        id: id,
        code: id == 'source-category' ? 'SRC' : 'DST',
        name: id == 'source-category' ? '原分类' : '新分类',
        level: 0,
        path: id == 'source-category' ? '原分类' : '新分类',
        childCount: 0,
        codePrefix: id == 'source-category' ? 'SRC' : 'DST',
        effectivePrefix: id == 'source-category' ? 'SRC' : 'DST',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GoodsRepository implements GoodsRepository {
  _GoodsRepository({this.targetCount = 0});

  final int targetCount;
  final detailCalls = <String>[];
  final created = <Map<String, dynamic>>[];
  final mainPageRequests =
      <({String? categoryId, int page, String? sort, String? order})>[];

  String _copyCode(int number) =>
      'DST${(targetCount + number).toString().padLeft(4, '0')}';

  @override
  Future<GoodsDetail> detail(String id) async {
    detailCalls.add(id);
    return _source;
  }

  @override
  Future<GoodsDetail> create(Map<String, dynamic> body) async {
    created.add(Map<String, dynamic>.from(body));
    return GoodsDetail.fromJson({
      ...body,
      'id': 'copy-${created.length}',
      'code': _copyCode(created.length),
    });
  }

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
  }) async {
    if (!disabledOnly && !stubOnly) {
      mainPageRequests.add((
        categoryId: categoryId,
        page: page,
        sort: sort,
        order: order,
      ));
    }
    final items = disabledOnly || stubOnly
        ? <GoodsListItem>[]
        : [
            if (categoryId == _source.categoryId)
              GoodsListItem(
                id: _source.id,
                name: _source.name,
                code: _source.code,
                categoryId: _source.categoryId,
                status: _source.status,
              ),
            if (categoryId == 'target-category')
              for (var i = 0; i < targetCount; i++)
                GoodsListItem(
                  id: 'existing-${i + 1}',
                  name: '已有货品 ${i + 1}',
                  code: 'DST${(i + 1).toString().padLeft(4, '0')}',
                  categoryId: categoryId,
                  status: '使用',
                ),
            for (var i = 0; i < created.length; i++)
              if (created[i]['categoryId'] == categoryId)
                GoodsListItem.fromJson({
                  ...created[i],
                  'id': 'copy-${i + 1}',
                  'code': _copyCode(i + 1),
                }),
          ];
    return PagedResult(
      items: items.skip((page - 1) * size).take(size).toList(),
      page: page,
      size: size,
      total: items.length,
      totalPages: (items.length / size).ceil(),
    );
  }

  @override
  Future<GoodsFacets> facets(String categoryId) async =>
      const GoodsFacets(fields: {}, nullCounts: {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BomRepository implements GoodsBomRepository {
  final listCalls = <String>[];
  final pasted =
      <
        ({
          BomPasteMode mode,
          List<BomPasteTarget> targets,
          List<Map<String, dynamic>> items,
        })
      >[];

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls.add(goodsId);
    return [_component];
  }

  @override
  Future<BomPasteResult> paste({
    required BomPasteMode mode,
    required List<BomPasteTarget> targets,
    required List<Map<String, dynamic>> items,
  }) async {
    pasted.add((mode: mode, targets: targets, items: items));
    return BomPasteResult(
      targets: targets.length,
      added: items.length,
      removed: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
