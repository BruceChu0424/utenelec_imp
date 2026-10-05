// ADR-144 采购允许超收%（订货明细）：
//  - 解析 / 允许超收量 T = ROUND(q × p / 100, 4) / 百分比显示；
//  - /last-terms 与订货明细 JSON 读出比例；
//  - 行模型：草稿恢复保留比例、黄标与「已预填过」，改值清黄标，克隆拷值不拷黄标；
//  - 新建：选货品按货品主档记忆预填(黄标)，其它条款已齐的行也补比例；
//    每行每个货品只预填一次：清空(= 不允许超收)后加行不回填；换货品清掉旧货品
//    带入的比例并按新货品重新预填；
//  - 编辑既有单：回显比例，保存按两位小数提交；空不提交(加行也不回填)；不合法拦住不提交。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_goods_picker.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/models/procurement_commercial_terms.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

const _goods = [
  GoodsListItem(
    id: 'g1',
    code: 'G1',
    name: '颗粒甲',
    colorId: 'black',
    unitId: 'kg',
  ),
  GoodsListItem(
    id: 'g2',
    code: 'G2',
    name: '颗粒乙',
    colorId: 'white',
    unitId: 'g',
  ),
];

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

/// 新建页用：/last-terms 给 g1 带货品主档允许超收 5%，g2 没有记忆。
class _CreateApi extends ApiClient {
  _CreateApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/last-terms')) {
      final ids = (query!['goodsIds'] as String).split(',').toSet();
      return {
        for (final g in _goods)
          if (ids.contains(g.id))
            g.id: {
              'supplierId': 'supplier',
              'settlementMethodId': 'settlement',
              'currencyId': 'cny',
              'exchangeRate': 1,
              'taxRate': 0,
              if (g.id == 'g1') ...{
                'allowedOverReceiptPct': 5,
                'allowedOverReceiptPctSource': 'GOODS_MASTER',
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
    return const [];
  }
}

/// 编辑既有单用：详情回显 + 记录 PUT 请求体。
class _EditApi extends ApiClient {
  _EditApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;
  Map<String, dynamic>? lastPutBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/${detail['id']}')) return detail;
    if (path.endsWith('/last-terms')) {
      final ids = (query!['goodsIds'] as String).split(',').toSet();
      return {
        for (final id in ids)
          id: {
            'supplierId': 'sup-1',
            'settlementMethodId': 'sm-1',
            'currencyId': 'cny',
            'exchangeRate': 1,
            'taxRate': 0,
            if (id == 'goods-1') ...{
              'allowedOverReceiptPct': 5,
              'allowedOverReceiptPctSource': 'GOODS_MASTER',
            },
          },
      };
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('reference-methods/settlement')) {
      return const [
        {'id': 'sm-1', 'code': 'M30', 'name': '月结30天'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail;
  }
}

Map<String, dynamic> _orderDetail(Object? pct) => {
  'id': 'order-1',
  'makerId': 'maker-1',
  'billNo': 'PO-2026-100-001',
  'billDate': '2026-10-04',
  'status': 0,
  'canEdit': true,
  'supplierId': 'sup-1',
  'settlementMethodId': 'sm-1',
  'currencyId': 'cny',
  'exchangeRate': 1,
  'taxRate': 0,
  'items': [
    {
      'id': 'pi-1',
      'goodsId': 'goods-1',
      'qty': 100,
      'price': 2,
      'allowedOverReceiptPct': ?pct,
    },
  ],
};

UtenEditableGrid<PurchaseGridRow> _grid(WidgetTester tester) =>
    tester.widget(find.byType(UtenEditableGrid<PurchaseGridRow>));

/// 货品选择器每次弹出时返回的货品(测试里随时换)。
final _picks = <GoodsListItem>[];

Future<void> _pumpCreate(
  WidgetTester tester, {
  List<GoodsListItem> picks = _goods,
}) async {
  await tester.binding.setSurfaceSize(const Size(1700, 1050));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  _picks
    ..clear()
    ..addAll(picks);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_CreateApi()),
        sessionProvider.overrideWith(_Session.new),
        purchaseGridGoodsPickerProvider.overrideWithValue(
          (_, _) async => List.of(_picks),
        ),
      ],
      child: const MaterialApp(home: PurchaseOrderEditPage()),
    ),
  );
  await tester.pumpAndSettle();
}

/// 点货品格(未选 = 「点击选择」，已选 = 货品名称)弹选择器。只在货品格里找：
/// 供应商 / 结账方式等条款格空着时也显示「点击选择」。
Future<void> _pickOn(WidgetTester tester, String cellText) async {
  await tester.tap(
    find
        .descendant(
          of: find.byType(ValueListenableBuilder<GoodsOption?>),
          matching: find.text(cellText),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<_EditApi> _pumpEdit(WidgetTester tester, Object? pct) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _EditApi(_orderDetail(pct));
  _picks
    ..clear()
    ..add(_goods.last);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        purchaseRepositoryProvider(
          PurchaseDocType.order,
        ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.order)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        writeAllDocumentScope(DocumentDataScope.purchase),
        sessionProvider.overrideWith(_Session.new),
        purchaseGridGoodsPickerProvider.overrideWithValue(
          (_, _) async => List.of(_picks),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => const PurchaseOrderEditPage(id: 'order-1'),
            ),
            GoRoute(
              path: '/:rest(.*)',
              builder: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
        builder: (context, child) => Stack(
          children: [
            Positioned.fill(child: child!),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
  await tester.pumpAndSettle();
}

void main() {
  group('口径', () {
    test('允许超收量 T = ROUND(q × p / 100, 4)，空比例为 0', () {
      expect(purchaseOverReceiptTolerance(100, 5), 5);
      expect(purchaseOverReceiptTolerance(1.2345, 5.5), 0.0679);
      expect(purchaseOverReceiptTolerance(100, null), 0);
      expect(purchaseOverReceiptTolerance(100, 0), 0);
    });

    test('输入解析：空有效(不提交)，0..100 两位小数，越界或非数字无效', () {
      expect(parsePurchaseOverReceiptPct('  '), (value: null, valid: true));
      expect(parsePurchaseOverReceiptPct('5'), (value: 5.0, valid: true));
      expect(parsePurchaseOverReceiptPct('3.456'), (value: 3.46, valid: true));
      expect(parsePurchaseOverReceiptPct('100'), (value: 100.0, valid: true));
      expect(parsePurchaseOverReceiptPct('100.01').valid, isFalse);
      expect(parsePurchaseOverReceiptPct('-1').valid, isFalse);
      expect(parsePurchaseOverReceiptPct('abc').valid, isFalse);
    });

    test('百分比显示去掉尾零', () {
      expect(purchasePercentText(5), '5');
      expect(purchasePercentText(2.5), '2.5');
      expect(purchasePercentText(12.25), '12.25');
    });

    test('/last-terms 与订货明细读出允许超收', () {
      final terms = ProcurementLastTerms.fromJson({
        'allowedOverReceiptPct': 5,
        'allowedOverReceiptPctSource': 'GOODS_MASTER',
      });
      expect(terms.allowedOverReceiptPct, 5);
      expect(terms.allowedOverReceiptPctSource, 'GOODS_MASTER');
      final item = PurchaseDocItem.fromJson({
        'id': 'i',
        'qty': 100,
        'allowedOverReceiptPct': '5.00',
      });
      expect(item.allowedOverReceiptPct, 5);
      expect(item.allowedOverReceiptQty, 5);
      expect(
        PurchaseDocItem.fromJson({'id': 'i'}).allowedOverReceiptPct,
        isNull,
      );
    });
  });

  group('行模型', () {
    test('草稿恢复保留比例与黄标，改值即清黄标', () {
      final source = PurchaseGridRow(supportsTotalInput: true)
        ..allowedOverReceiptPct.text = '5';
      source.markAllowedOverReceiptAutofilled('5');
      final restored = PurchaseGridRow.fromDraft(
        source.exportDraft(),
        supportsTotalInput: true,
      );
      expect(restored.allowedOverReceiptPct.text, '5');
      expect(restored.termsAutofilled, contains('allowedOverReceipt'));
      restored.allowedOverReceiptPct.text = '6';
      expect(restored.termsAutofilled, isNot(contains('allowedOverReceipt')));
      source.dispose();
      restored.dispose();
    });

    test('「已预填过」随草稿保存恢复，克隆沿用；只有换货品才重置', () {
      final source = PurchaseGridRow(supportsTotalInput: true)
        ..goods = const GoodsOption(id: 'g1', code: 'G1', name: '颗粒甲');
      expect(source.overReceiptPrefillConsumed, isFalse);
      source.overReceiptPrefillConsumed = true;
      final restored = PurchaseGridRow.fromDraft(
        source.exportDraft(),
        supportsTotalInput: true,
      );
      expect(restored.overReceiptPrefillConsumed, isTrue);
      final copy = source.clone();
      expect(copy.overReceiptPrefillConsumed, isTrue);
      source.resetAllowedOverReceiptForGoods('g1');
      expect(source.overReceiptPrefillConsumed, isTrue, reason: '同一货品不重置');
      source.resetAllowedOverReceiptForGoods('g2');
      expect(source.overReceiptPrefillConsumed, isFalse);
      source.dispose();
      restored.dispose();
      copy.dispose();
    });

    test('换货品清掉旧货品带入(黄标)的比例，用户自己填的保留', () {
      final row = PurchaseGridRow()
        ..goods = const GoodsOption(id: 'g1', code: 'G1', name: '颗粒甲')
        ..allowedOverReceiptPct.text = '5';
      row.markAllowedOverReceiptAutofilled('5');
      row.resetAllowedOverReceiptForGoods('g2');
      expect(row.allowedOverReceiptPct.text, isEmpty);
      expect(row.termsAutofilled, isNot(contains('allowedOverReceipt')));
      row.allowedOverReceiptPct.text = '3';
      row.resetAllowedOverReceiptForGoods('g3');
      expect(row.allowedOverReceiptPct.text, '3');
      row.dispose();
    });

    test('克隆拷比例不拷黄标', () {
      final source = PurchaseGridRow()..allowedOverReceiptPct.text = '5';
      source.markAllowedOverReceiptAutofilled('5');
      final copy = source.clone();
      expect(copy.allowedOverReceiptPct.text, '5');
      expect(copy.termsAutofilled, isNot(contains('allowedOverReceipt')));
      source.dispose();
      copy.dispose();
    });
  });

  testWidgets('新建：选货品按主档记忆预填允许超收(黄标)，条款已齐的行也补比例', (tester) async {
    await _pumpCreate(tester);
    expect(
      _grid(tester).columns.where((c) => c.key == 'allowedOverReceiptPct'),
      hasLength(1),
    );
    final current = _grid(tester).controller.rows.single;
    // 其它商业条款已齐：只差允许超收，也必须去取主档记忆。
    current
      ..supplierId = 'supplier'
      ..settlementMethodId = 'settlement'
      ..currencyId = 'cny';
    current.exchangeRate.text = '1';
    current.taxRate.text = '0';
    current.price.text = '7';
    await tester.tap(
      find
          .descendant(
            of: find.byType(UtenEditableGrid<PurchaseGridRow>),
            matching: find.text('点击选择'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    final rows = _grid(tester).controller.rows;
    expect(rows.map((r) => r.goods!.id), ['g1', 'g2']);
    expect(rows.first.allowedOverReceiptPct.text, '5');
    expect(rows.first.termsAutofilled, contains('allowedOverReceipt'));
    expect(rows.first.price.text, '7', reason: '不覆盖已填价格');
    expect(rows.last.allowedOverReceiptPct.text, isEmpty, reason: '没有记忆不预填');
    rows.first.allowedOverReceiptPct.text = '8';
    expect(rows.first.termsAutofilled, isNot(contains('allowedOverReceipt')));
  });

  testWidgets('新建：清空预填的比例(不允许超收)后再加行，不会被主档记忆填回去', (tester) async {
    await _pumpCreate(tester, picks: [_goods.first]);
    await _pickOn(tester, '点击选择');
    final first = _grid(tester).controller.rows.single;
    expect(first.allowedOverReceiptPct.text, '5');
    expect(first.termsAutofilled, contains('allowedOverReceipt'));
    // 用户清空 = 不允许超收(按 0%)。
    first.allowedOverReceiptPct.text = '';
    // 再加一行选别的货品：预填会对全表再跑一遍。
    _grid(tester).controller.addRow(PurchaseGridRow(supportsTotalInput: true));
    await tester.pumpAndSettle();
    _picks
      ..clear()
      ..add(_goods.last);
    await _pickOn(tester, '点击选择');
    final rows = _grid(tester).controller.rows;
    expect(rows.map((r) => r.goods?.id), ['g1', 'g2']);
    expect(rows.first.allowedOverReceiptPct.text, isEmpty);
    expect(rows.first.termsAutofilled, isNot(contains('allowedOverReceipt')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建：换货品清掉旧货品带入的比例，换回去重新预填', (tester) async {
    await _pumpCreate(tester, picks: [_goods.first]);
    await _pickOn(tester, '点击选择');
    final row = _grid(tester).controller.rows.single;
    expect(row.allowedOverReceiptPct.text, '5');
    // 选错了货品：换成没有记忆的颗粒乙 → 比例清空、黄标去掉(按 0%)。
    _picks
      ..clear()
      ..add(_goods.last);
    await _pickOn(tester, '颗粒甲');
    expect(row.goods?.id, 'g2');
    expect(row.allowedOverReceiptPct.text, isEmpty);
    expect(row.termsAutofilled, isNot(contains('allowedOverReceipt')));
    // 再换回颗粒甲：按它的记忆重新预填一次。
    _picks
      ..clear()
      ..add(_goods.first);
    await _pickOn(tester, '颗粒乙');
    expect(row.goods?.id, 'g1');
    expect(row.allowedOverReceiptPct.text, '5');
    expect(row.termsAutofilled, contains('allowedOverReceipt'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑既有单：比例为空的行加行后仍为空，保存不提交比例', (tester) async {
    final api = await _pumpEdit(tester, null);
    _grid(tester).controller.addRow(PurchaseGridRow(supportsTotalInput: true));
    await tester.pumpAndSettle();
    await _pickOn(tester, '点击选择');
    final rows = _grid(tester).controller.rows;
    expect(rows.first.goods?.id, 'goods-1');
    expect(
      rows.first.allowedOverReceiptPct.text,
      isEmpty,
      reason: '已存单据留空 = 不允许超收，不按主档 5% 回填',
    );
    expect(rows.last.goods?.id, 'g2');
    // 新加的行不在本测试关心范围，删掉后只保存原行。
    _grid(tester).controller.removeAt(1);
    await tester.pumpAndSettle();
    await _save(tester);
    final line = (api.lastPutBody!['items'] as List).single as Map;
    expect(line.containsKey('allowedOverReceiptPct'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑既有单：回显比例，改成三位小数按两位提交', (tester) async {
    final api = await _pumpEdit(tester, 5);
    final row = _grid(tester).controller.rows.single;
    expect(row.allowedOverReceiptPct.text, '5');
    expect(row.termsAutofilled, isNot(contains('allowedOverReceipt')));
    row.allowedOverReceiptPct.text = '3.456';
    await _save(tester);
    final line = (api.lastPutBody!['items'] as List).single as Map;
    expect(line['allowedOverReceiptPct'], 3.46);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑既有单：留空不提交比例(服务端按 0%)', (tester) async {
    final api = await _pumpEdit(tester, null);
    final row = _grid(tester).controller.rows.single;
    expect(row.allowedOverReceiptPct.text, isEmpty);
    await _save(tester);
    final line = (api.lastPutBody!['items'] as List).single as Map;
    expect(line.containsKey('allowedOverReceiptPct'), isFalse);
  });

  testWidgets('允许超收超过 100 拦住不提交并说明', (tester) async {
    final api = await _pumpEdit(tester, 5);
    _grid(tester).controller.rows.single.allowedOverReceiptPct.text = '120';
    await _save(tester);
    expect(api.lastPutBody, isNull);
    expect(find.textContaining('允许超收不是 0 到 100 之间的数'), findsWidgets);
  });
}
