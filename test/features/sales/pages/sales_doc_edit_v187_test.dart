import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
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
      final settlementFinder = _dropdownWithLabel('结账方式');
      expect(settlementFinder, findsOneWidget);
      final settlement = tester.widget<UtenDropdownField>(settlementFinder);
      expect(settlement.required, isTrue);
      expect(settlement.value, isNull);
      expect(settlement.allowClear, isFalse);
      final decorator = tester.widget<InputDecorator>(
        find.descendant(
          of: settlementFinder,
          matching: find.byType(InputDecorator),
        ),
      );
      final border = decorator.decoration.enabledBorder! as OutlineInputBorder;
      expect(
        border.borderSide.color,
        Theme.of(tester.element(settlementFinder)).colorScheme.error,
      );
      expect(_textFieldWithLabel('税率(%)'), findsOneWidget);
      expect(_textFieldWithLabel('汇率'), findsNothing);
      expect(find.text('金额(订单币种)'), findsOneWidget);
      expect(find.text('总金额(订单币种) 0.00'), findsOneWidget);
      expect(find.text('合计(订单币种) 0.00'), findsOneWidget);
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
    expect(find.text('历史订单(未指定)'), findsOneWidget);
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
          'settlementMethodId': 'settlement-net30',
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
              'unitId': 'unit-box',
              'unitRate': 10,
              'qty': 2,
              'weight': 5.25,
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
      expect(item['id'], 'order-item-1');
      expect(item['unitId'], 'unit-box');
      expect(item['unitRate'], 10);
      expect(item['weight'], 5.25);
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

  testWidgets(
    'finance-rejected order shows reason and save explains reapproval',
    (tester) async {
      await _pumpEditor(
        tester,
        type: SalesDocType.order,
        id: 'order-finance-rejected',
        detail: const {
          'id': 'order-finance-rejected',
          'billNo': 'SO-REJECTED',
          'billDate': '2026-08-27',
          'status': 1,
          'writable': true,
          'clientId': 'client-1',
          'currencyId': 'currency-usd',
          'settlementMethodId': 'settlement-net30',
          'taxRate': 13,
          'sellerId': 'seller-1',
          'deliverDate': '2026-09-10',
          'shipmentPolicy': 'ALLOW_PARTIAL',
          'financeConfirmed': false,
          'financeRejected': true,
          'financeRejectedReason': '结账方式错误',
          'financeRejectedAt': '2026-08-27T08:00:00+08:00',
          'financeRejectedByName': '财务张经理',
          'items': [
            {
              'id': 'order-item-1',
              'goodsId': 'goods-1',
              'unitId': 'unit-box',
              'unitRate': 10,
              'qty': 2,
              'price': 10,
              'discount': 1,
            },
          ],
        },
      );

      expect(
        find.byKey(const ValueKey('sales-order-finance-rejection-edit-notice')),
        findsOneWidget,
      );
      expect(find.text('结账方式错误'), findsOneWidget);
      expect(find.textContaining('重新审核'), findsOneWidget);

      await tester.tap(find.text('保存'));
      // 保存是异步链 + 通知栈有 220ms 入栈动画，单帧 pump 看不到通知文案。
      await tester.pumpAndSettle();
      expect(find.text('已转草稿，请重新审核提交财务'), findsOneWidget);
    },
  );
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
      child: MaterialApp.router(
        // 保存成功后会 context.replace 跳详情；无 GoRouter 会抛断言，
        // 使「保存失败」通知顶掉 V187 转草稿提示（旧卡降级为无文本轮廓）。
        routerConfig: GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => SalesDocEditPage(docType: type, id: id),
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
