import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_goods_picker.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

const _goods = [
  GoodsListItem(
    id: 'g1',
    code: 'G1',
    name: '颗粒甲',
    colorId: 'black',
    unitId: 'kg',
    stockPlace: 'A-1',
    price: 999,
  ),
  GoodsListItem(
    id: 'g2',
    code: 'G2',
    name: '颗粒乙',
    colorId: 'white',
    unitId: 'g',
    stockPlace: 'A-2',
    price: 888,
  ),
];

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final termsQueries = <Set<String>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/last-terms')) {
      final ids = (query!['goodsIds'] as String).split(',').toSet();
      termsQueries.add(ids);
      return {
        for (final g in _goods)
          if (ids.contains(g.id))
            g.id: {
              'supplierId': 'supplier',
              'settlementMethodId': 'settlement',
              'currencyId': 'cny',
              'exchangeRate': 1,
              'taxRate': 0,
              'purchasePrice': g.id == 'g1' ? 2.5 : 3.5,
              'priceContext': {
                'supplierId': 'supplier',
                'colorId': g.colorId,
                'unitId': g.unitId,
                'currencyId': 'cny',
                'taxRate': 0,
              },
            },
      };
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.suppliersDict) {
      return const [
        {'id': 'supplier', 'name': '供应商', 'status': '使用'},
      ];
    }
    if (path == ApiEndpoints.currenciesDict) {
      return const [
        {'id': 'cny', 'name': '人民币'},
      ];
    }
    if (path == ApiEndpoints.settlementMethods) {
      return const [
        {'id': 'settlement', 'name': '月结', 'status': '使用'},
      ];
    }
    if (path == ApiEndpoints.unitsDict) {
      return const [
        {'id': 'kg', 'name': '公斤'},
        {'id': 'g', 'name': '克'},
      ];
    }
    if (path == ApiEndpoints.colorsDict) {
      return const [
        {'id': 'black', 'name': '黑'},
        {'id': 'white', 'name': '白'},
      ];
    }
    return const [];
  }
}

Future<_Api> _pump(
  WidgetTester tester,
  Widget page,
  PurchaseGridGoodsPicker picker,
) async {
  await tester.binding.setSurfaceSize(const Size(1700, 1050));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _Api();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_Session.new),
        purchaseGridGoodsPickerProvider.overrideWithValue(picker),
      ],
      child: MaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

UtenEditableGrid<PurchaseGridRow> _grid(WidgetTester tester) =>
    tester.widget(find.byType(UtenEditableGrid<PurchaseGridRow>));
Future<void> _pick(WidgetTester tester) async {
  await tester.tap(
    find
        .descendant(
          of: find.byType(UtenEditableGrid<PurchaseGridRow>),
          matching: find.text('点击选择'),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('订货一次多选逐行带单位库位、采购价与条款，新增各行自动勾选', (tester) async {
    int opened = 0;
    final api = await _pump(tester, const PurchaseOrderEditPage(), (
      _,
      _,
    ) async {
      opened++;
      return _goods;
    });
    final current = _grid(tester).controller.rows.single;
    current.qty.text = '12';
    current.price.text = '7';
    await _pick(tester);
    final rows = _grid(tester).controller.rows;
    expect(opened, 1);
    expect(rows, hasLength(2));
    expect(identical(rows.first, current), isTrue);
    expect(rows.map((r) => r.goods!.id), ['g1', 'g2']);
    expect(rows.map((r) => r.unitId), ['kg', 'g']);
    expect(rows.map((r) => r.colorId), ['black', 'white']);
    expect(rows.map((r) => r.stockPlaceNotifier.value), ['A-1', 'A-2']);
    expect(rows.first.qty.text, '12');
    expect(rows.first.price.text, '7', reason: '不覆盖已填价格');
    expect(rows.last.price.text, '3.5', reason: '带采购默认价，不能拿销售标价888');
    expect(rows.last.supplierId, 'supplier');
    expect(rows.last.currencyId, 'cny');
    expect(rows.last.supportsTotalInput, isTrue);
    expect(_grid(tester).controller.selectedRows, containsAll(rows));
    expect(api.termsQueries.single, {'g1', 'g2'});
  });

  for (final type in [
    PurchaseDocType.request,
    PurchaseDocType.receipt,
    PurchaseDocType.returnDoc,
  ]) {
    testWidgets('${type.name}手工行多选保留原数量价格，额外行不复制上游身份', (tester) async {
      await _pump(
        tester,
        PurchaseDocEditPage(docType: type),
        (_, _) async => _goods,
      );
      final current = _grid(tester).controller.rows.single;
      current.qty.text = '6';
      current.price.text = '4.25';
      current.remark.text = '仅原行备注';
      await _pick(tester);
      final rows = _grid(tester).controller.rows;
      expect(rows, hasLength(2));
      expect(rows.first.qty.text, '6');
      expect(rows.first.price.text, '4.25');
      expect(rows.last.goods!.id, 'g2');
      expect(rows.last.unitId, 'g');
      expect(rows.last.unitRate, 1);
      expect(rows.last.qty.text, isEmpty);
      expect(rows.last.price.text, isEmpty);
      expect(rows.last.upstreamItemId, isNull);
      expect(rows.last.sourceLocked, isFalse);
      expect(rows.last.remark.text, isEmpty);
    });
  }

  testWidgets('取消多选不改原行，重复货品保持独立交给既有保存复核', (tester) async {
    List<GoodsListItem> selection = const [];
    await _pump(
      tester,
      const PurchaseOrderEditPage(),
      (_, _) async => selection,
    );
    final controller = _grid(tester).controller;
    await _pick(tester);
    expect(controller.rows.single.goods, isNull);
    selection = _goods;
    await _pick(tester);
    final existing = controller.rows.first;
    existing.qty.text = '9';
    controller.addRow(PurchaseGridRow(supportsTotalInput: true));
    await tester.pumpAndSettle();
    selection = [_goods.first];
    final grid = _grid(tester);
    final target = grid.controller.rows.last;
    final cell =
        grid.columns
                .firstWhere((column) => column.key == 'goods')
                .cellBuilder(
                  tester.element(
                    find.byType(UtenEditableGrid<PurchaseGridRow>),
                  ),
                  target,
                )
            as RequiredCellFrame;
    (cell.child as InkWell).onTap!();
    await tester.pumpAndSettle();
    expect(controller.rows.where((r) => r.goods?.id == 'g1'), hasLength(2));
    expect(existing.qty.text, '9');
  });

  testWidgets('多选等待期间当前行被删除，返回后不写入已释放行', (tester) async {
    final selected = Completer<List<GoodsListItem>>();
    await _pump(
      tester,
      const PurchaseOrderEditPage(),
      (_, _) => selected.future,
    );
    final controller = _grid(tester).controller;
    await tester.tap(
      find
          .descendant(
            of: find.byType(UtenEditableGrid<PurchaseGridRow>),
            matching: find.text('点击选择'),
          )
          .first,
    );
    controller.removeAt(0);
    await tester.pump();
    selected.complete(_goods);
    await tester.pumpAndSettle();
    expect(controller.rows, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('上游来源锁定行仍不能换货或打开多选', (tester) async {
    int opened = 0;
    await _pump(tester, const PurchaseOrderEditPage(), (_, _) async {
      opened++;
      return _goods;
    });
    final grid = _grid(tester);
    final locked = PurchaseGridRow(sourceLocked: true, supportsTotalInput: true)
      ..upstreamItemId = 'source-item';
    grid.controller.replaceAll([locked]);
    await tester.pumpAndSettle();
    final cell =
        _grid(tester).columns
                .firstWhere((column) => column.key == 'goods')
                .cellBuilder(
                  tester.element(
                    find.byType(UtenEditableGrid<PurchaseGridRow>),
                  ),
                  locked,
                )
            as RequiredCellFrame;
    expect((cell.child as InkWell).onTap, isNull);
    expect(opened, 0);
    expect(locked.upstreamItemId, 'source-item');
  });
}
