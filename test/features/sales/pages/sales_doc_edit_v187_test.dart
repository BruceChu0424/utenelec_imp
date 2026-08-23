import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'new order defaults to empty shipment policy for sales to choose',
    (tester) async {
      await _pumpEditor(tester, type: SalesDocType.order);

      expect(
        find.byKey(const ValueKey('sales-order-shipment-policy')),
        findsOneWidget,
      );
      // customerConfirm 不再提供给新单：默认空，由销售自选 ALLOW_PARTIAL / REQUIRE_COMPLETE。
      expect(find.text('客户确认后分批'), findsNothing);
      expect(find.textContaining('请选择发运策略'), findsNothing);
      expect(_dropdownWithLabel('发运策略'), findsOneWidget);

      // 销售订单仍需选择币种、填写税率，但汇率改由财务维护。
      expect(_dropdownWithLabel('币种'), findsOneWidget);
      expect(_textFieldWithLabel('税率(%)'), findsOneWidget);
      expect(_textFieldWithLabel('汇率'), findsNothing);
      expect(find.text('金额（订单币种）'), findsOneWidget);
      expect(find.text('总金额（订单币种） 0.00'), findsOneWidget);
      expect(find.text('合计（订单币种） 0.00'), findsOneWidget);
      expect(find.textContaining('¥'), findsNothing);
    },
  );

  testWidgets('375px order editor has no deposit or advance receipt input', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      type: SalesDocType.order,
      size: const Size(375, 900),
    );

    expect(_textFieldWithLabel('订金'), findsNothing);
    expect(_textFieldWithLabel('定金'), findsNothing);
    expect(_textFieldWithLabel('预收款'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy order keeps shipment policy read-only', (tester) async {
    await _pumpEditor(
      tester,
      type: SalesDocType.order,
      id: 'legacy-order',
      detail: const {
        'id': 'legacy-order',
        'status': 0,
        'writable': true,
        'shipmentPolicy': 'LEGACY_UNSPECIFIED',
        'items': <Map<String, dynamic>>[],
      },
    );

    expect(
      find.byKey(const ValueKey('sales-order-shipment-policy-readonly')),
      findsOneWidget,
    );
    expect(find.text('历史订单（未指定）'), findsOneWidget);
    expect(find.textContaining('编辑其它字段时系统会保留'), findsNothing);
  });

  testWidgets('non-order currency document keeps exchange rate editor', (
    tester,
  ) async {
    await _pumpEditor(tester, type: SalesDocType.otherShipment);

    expect(_dropdownWithLabel('币种'), findsOneWidget);
    expect(_textFieldWithLabel('汇率'), findsOneWidget);
    expect(_textFieldWithLabel('税率(%)'), findsOneWidget);
  });

  testWidgets(
    'order save omits exchange rate but keeps currency and tax rate',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.order,
        id: 'order-rate-hidden',
        detail: const {
          'id': 'order-rate-hidden',
          'billNo': 'XD202608080001',
          'billDate': '2026-08-08',
          'status': 0,
          'writable': true,
          'clientId': 'client-1',
          'currencyId': 'currency-usd',
          'exchangeRate': 7.2,
          'taxRate': 13,
          'sellerId': 'seller-1',
          'deliverDate': '2026-08-20',
          'shipmentPolicy': 'ALLOW_PARTIAL',
          'deposit': 88.88,
          'items': [
            {
              'id': 'order-item-1',
              'goodsId': 'goods-1',
              'qty': 2,
              'price': 10,
              'discount': 0.8,
            },
          ],
        },
      );

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(api.lastPutBody, isNotNull);
      expect(api.lastPutBody!['currencyId'], 'currency-usd');
      expect(api.lastPutBody!['taxRate'], 13);
      expect(api.lastPutBody!.containsKey('exchangeRate'), isFalse);
      expect(api.lastPutBody!.containsKey('deposit'), isFalse);
      final item = Map<String, dynamic>.from(
        (api.lastPutBody!['items'] as List<dynamic>).single as Map,
      );
      expect(item['amountOriginal'], 16);
      expect(item.containsKey('amountLocal'), isFalse);
    },
  );

  testWidgets('new sales shipment explains mandatory order linkage', (
    tester,
  ) async {
    await _pumpEditor(tester, type: SalesDocType.shipment);

    expect(
      find.byKey(const ValueKey('sales-shipment-order-link-guidance')),
      findsOneWidget,
    );
    expect(find.textContaining('销售出货必须从订货单引入'), findsOneWidget);
  });
}

Finder _dropdownWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == label,
);

Finder _textFieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<_EditorApi> _pumpEditor(
  WidgetTester tester, {
  required SalesDocType type,
  String? id,
  Map<String, dynamic>? detail,
  Size size = const Size(1600, 1200),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _EditorApi(detail);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        sessionProvider.overrideWith(_TestSessionNotifier.new),
      ],
      child: MaterialApp(
        home: SalesDocEditPage(docType: type, id: id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _EditorApi extends ApiClient {
  _EditorApi(this.detail) : super(Dio());

  final Map<String, dynamic>? detail;
  Map<String, dynamic>? lastPutBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (detail != null && path.endsWith('/${detail!['id']}')) {
      return detail!;
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
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail ?? const {'id': 'saved-order', 'items': <Object>[]};
  }
}
