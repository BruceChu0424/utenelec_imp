import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../../support/audit_screenshot_support.dart';
import '../../../support/native_detail_reader_overrides.dart';
import '../../../support/pump_until.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_client_picker.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  for (final metadataLoaded in [false, true]) {
    testWidgets(
      'sales return own line locator with empty metadata loaded=$metadataLoaded',
      (tester) async {
        final api = await _pumpEditor(
          tester,
          type: SalesDocType.returnDoc,
          id: 'return-draft',
          nativeReader: true,
          permissions: {Perm.salesReturnView, Perm.salesReturnEdit},
          detail: const {
            'id': 'return-draft',
            'status': 0,
            'writable': true,
            'canEdit': true,
            'makerId': 'maker-owner',
            'billDate': '2026-10-11',
            'clientId': 'client-1',
            'warehouseId': 'warehouse-1',
            'currencyId': 'currency-usd',
            'exchangeRate': 7.123456,
            'exchangeRateExact': '7.123456',
            'taxRate': 0,
            'items': [
              {
                'id': 'return-own-line',
                'goodsId': 'goods-1',
                'goodsCodeSnapshot': 'G001',
                'goodsNameSnapshot': '来源货品',
                'qty': 10.1256,
                'qtyExact': '10.1256',
                'price': 4.05,
                'outItemId': 'source-out-line',
                'orderItemId': 'source-order-line',
                'unitId': 'piece',
                'unitRate': 1,
              },
            ],
          },
        );
        final grid = tester.widget<UtenEditableGrid<SalesGridRow>>(
          find.byType(UtenEditableGrid<SalesGridRow>),
        );
        final row = grid.controller.rows.single;
        if (metadataLoaded) {
          row.platformFields.adopt(
            const PlatformRowValues(
              recordId: 'return-own-line',
              version: 17,
              canWrite: true,
            ),
          );
          expect(row.platformFields.savePayload()?['expectedVersion'], 17);
        } else {
          row.platformFields
            ..sourceRecordId = null
            ..loaded = false
            ..dirty = false;
        }
        expect(row.platformFields.cells, isEmpty);
        if (!metadataLoaded) expect(row.platformFields.savePayload(), isNull);
        final clone = row.clone();
        expect(clone.documentItemId, isNull);
        expect(clone.platformFields.sourceRecordId, isNull);
        clone.dispose();
        if (!metadataLoaded) {
          final state =
              tester.state(find.byType(SalesDocEditPage))
                  as FormDraftMixin<SalesDocEditPage>;
          final draft = Map<String, dynamic>.from(state.captureFormDraft());
          await pumpUntilCompletes(
            tester,
            state.restoreFormDraft(draft),
            reason: 'Restoration must finish while its UI slices yield',
          );
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(api.lastPutBody, isNotNull);
        final item = (api.lastPutBody!['items'] as List).single as Map;
        expect(item['id'], 'return-own-line');
        expect(item['outItemId'], 'source-out-line');
        expect(item['orderItemId'], 'source-order-line');
        expect(item['qty'], '10.1256');
        if (metadataLoaded) {
          expect(item['platformFields'], {
            'sourceRecordId': 'return-own-line',
            'expectedVersion': 17,
            'cells': <Object>[],
          });
        } else {
          expect(item.containsKey('platformFields'), isFalse);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final hidden in [false, true]) {
    testWidgets(
      'sales picker ${hidden ? 'rejects a newly hidden' : 'accepts a selectable'} client after fresh lookup',
      (tester) async {
        final api = await _pumpEditor(tester, type: SalesDocType.order);
        api.offerClient = true;
        final field = find.byType(ClientPickerField);
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text('新选客户'));
        api.clientSelectable = !hidden;
        await tester.pump();
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<ClientPickerField>(field).initialId,
          hidden ? isNull : 'client-1',
        );
        expect(api.lastPutBody, isNull);
        expect(api.batchBodies, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'selected order products prefill partial shipment and save without warehouse',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.shipment,
        initialOrderId: 'source-order',
        initialOrderItems: 'source-line:7.5',
        detail: _prefillOrder,
      );
      expect(_dropdownWithLabel('仓库'), findsNothing);
      expect(find.text('库位号'), findsNothing);
      final quantity = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '7.5',
      );
      expect(quantity, findsOneWidget);
      await tester.enterText(quantity, '3');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final body = api.batchBodies.single;
      expect(body.containsKey('warehouseId'), isFalse);
      expect(body['idempotencyKey'], isNotEmpty);
      expect(body['sellerId'], 'seller-1');
      expect(body['settlementMethodId'], 'settlement-net30');
      expect(body['lines'], [
        {'orderItemId': 'source-line', 'qty': '3'},
      ]);
      expect(api.lastPutBody, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unconfirmed multi-shipment creation retries identical intent and then shows created documents',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.shipment,
        initialOrderId: 'source-order',
        initialOrderItems: 'source-line:7.5',
        detail: _prefillOrder,
        failBatchOnce: true,
        batchCount: 2,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('重试确认开单'), findsOneWidget);
      expect(
        tester.widget<PopScope>(find.byType(PopScope).first).canPop,
        isFalse,
      );
      final back = find.byType(UtenBackButton);
      expect(tester.widget<UtenBackButton>(back).enabled, isFalse);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: back, matching: find.byType(IconButton)),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(back, warnIfMissed: false);
      await tester.pump();
      expect(find.byType(SalesDocEditPage), findsOneWidget);
      await tester.tap(find.text('重试确认开单'));
      await tester.pumpAndSettle();
      expect(api.batchBodies, hasLength(2));
      expect(api.batchBodies.first, api.batchBodies.last);
      expect(find.text('已生成 2 张出货单'), findsOneWidget);
      expect(find.text('SH-0'), findsOneWidget);
      expect(find.text('SH-1'), findsOneWidget);
      expect(find.text('仓库'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stale product availability blocks prefill with a recovery message',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.shipment,
        initialOrderId: 'source-order',
        initialOrderItems: 'source-line:11',
        detail: _prefillOrder,
      );
      expect(find.textContaining('可发数量已变化'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      expect(api.batchBodies, isEmpty);
    },
  );
  testWidgets(
    'direct customer edit retains exact decimals and stable row revision',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.customerShipment,
        id: 'direct-exact',
        detail: const {
          'id': 'direct-exact',
          'shipmentKind': 'DIRECT_CUSTOMER',
          'billingMode': 'CHARGED',
          'directPurpose': 'SAMPLE',
          'reviewRevision': 3,
          'status': 0,
          'writable': true,
          'clientId': 'client-1',
          'currencyId': 'currency-usd',
          'warehouseId': 'warehouse-1',
          'shipAddr': '客户收货处',
          'linkPhone': '1234567',
          'warehouseWorkStatus': 'PENDING_PICK',
          'items': [
            {
              'id': 'stable-direct-line',
              'goodsId': 'goods-1',
              'unitId': 'unit-box',
              'unitRate': 1,
              'unitRateExact': '1.000000',
              'qty': 2,
              'qtyExact': '2.0000',
              'price': 1234567890123.4568,
              'priceExact': '1234567890123.4567',
              'discount': 1,
              'discountExact': '1.0000',
            },
          ],
        },
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.controller?.text == '1234567890123.4567',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.lastPutBody, isNotNull);
      expect(api.lastPutBody!['expectedRevision'], 3);
      expect(api.lastPutBody!['shipmentKind'], 'DIRECT_CUSTOMER');
      final line = (api.lastPutBody!['items'] as List).single as Map;
      expect(line['id'], 'stable-direct-line');
      expect(line['price'], '1234567890123.4567');
      expect(line['qty'], '2');
      expect(line['unitRate'], '1.000000');
      expect(line['discount'], '1');
      expect(line.containsKey('amountOriginal'), isFalse);
      expect(line.containsKey('amountLocal'), isFalse);
    },
  );

  testWidgets(
    'direct customer total amount reverses exact price and submits decimal strings',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.customerShipment,
        id: 'direct-total',
        detail: _directTotal,
      );
      final row = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller
          .rows
          .single;
      row.qty.text = '10000';
      row.discount.text = '0.8';
      row.pricing.totalAmount.text = '100';
      await tester.pump();
      expect(row.price.text, '0.0125');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final line = (api.lastPutBody!['items'] as List).single as Map;
      expect(line['qty'], '10000');
      expect(line['price'], '0.0125');
      expect(line['discount'], '0.8');
      expect(line.containsKey('totalAmountInput'), isFalse);
      expect(line.containsKey('amountOriginal'), isFalse);
    },
  );

  testWidgets(
    'direct customer inexact total blocks save without silently rounding price',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.customerShipment,
        id: 'direct-total',
        detail: _directTotal,
      );
      final row = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller
          .rows
          .single;
      row.qty.text = '3';
      row.pricing.totalAmount.text = '1';
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.lastPutBody, isNull);
      expect(row.price.text, isEmpty);
      expect(row.pricing.totalAmount.text, '1');
      expect(row.pricing.error.value, contains('精确单价'));
    },
  );

  testWidgets(
    'unlinked sales return includes its stored discount when reversing total',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.returnDoc,
        id: 'return-total',
        detail: {
          ..._directTotal,
          'id': 'return-total',
          'items': [
            {
              'id': 'return-line',
              'goodsId': 'goods-1',
              'qty': 10,
              'price': 2,
              'discount': 0.8,
            },
          ],
        },
      );
      final row = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller
          .rows
          .single;
      expect(row.amountExactNotifier.value, '16');
      row.pricing.totalAmount.text = '8';
      await tester.pump();
      expect(row.price.text, '1');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final line = (api.lastPutBody!['items'] as List).single as Map;
      expect(line['qty'], '10');
      expect(line['price'], '1');
      expect(line['discount'], '0.8');
    },
  );

  testWidgets(
    'explicit free dispatch hides unnecessary price and currency inputs',
    (tester) async {
      final api = await _pumpEditor(
        tester,
        type: SalesDocType.customerShipment,
        id: 'direct-free',
        detail: const {
          'id': 'direct-free',
          'shipmentKind': 'DIRECT_CUSTOMER',
          'billingMode': 'FREE',
          'directPurpose': 'GIFT',
          'freeReason': '客户试用约定',
          'reviewRevision': 0,
          'status': 0,
          'writable': true,
          'clientId': 'client-1',
          'warehouseId': 'warehouse-1',
          'shipAddr': '客户收货处',
          'linkPhone': '1234567',
          'warehouseWorkStatus': 'PENDING_PICK',
          'items': [
            {
              'id': 'free-line',
              'goodsId': 'goods-1',
              'unitId': 'unit-box',
              'unitRate': 1,
              'qty': 2,
              'price': 0,
              'discount': 1,
            },
          ],
        },
      );
      expect(_dropdownWithLabel('币种'), findsNothing);
      expect(find.text('单价'), findsNothing);
      expect(
        find.byKey(const ValueKey('customer-shipment-free-reason')),
        findsOneWidget,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.lastPutBody!['billingMode'], 'FREE');
      expect(api.lastPutBody!['freeReason'], '客户试用约定');
      final line = (api.lastPutBody!['items'] as List).single as Map;
      expect(line.containsKey('price'), isFalse);
      expect(line.containsKey('amountOriginal'), isFalse);
    },
  );

  testWidgets('new order uses partial shipment without a policy input', (
    tester,
  ) async {
    final capture = GlobalKey();
    await _pumpEditor(tester, type: SalesDocType.order, capture: capture);
    final form =
        tester.state(find.byType(SalesDocEditPage))
            as FormDraftMixin<SalesDocEditPage>;
    expect(form.captureFormDraft()['shipmentPolicy'], 'ALLOW_PARTIAL');
    await tester.runAsync(
      () => form.restoreFormDraft({
        ...form.captureFormDraft(),
        'shipmentPolicy': 'REQUIRE_COMPLETE',
      }),
    );
    await tester.pumpAndSettle();
    expect(form.captureFormDraft()['shipmentPolicy'], 'ALLOW_PARTIAL');

    expect(
      find.byKey(const ValueKey('sales-order-shipment-policy')),
      findsNothing,
    );
    // 新单自动允许分批，不再要求选择策略。
    expect(find.text('客户确认后分批'), findsNothing);
    expect(find.textContaining('请选择发运策略'), findsNothing);
    expect(_dropdownWithLabel('发运策略'), findsNothing);

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
    expect(find.text('总金额(订单币种)'), findsOneWidget);
    // 表尾合计条（UtenTotalsSummaryBar）：标签与数值分两个 Text 渲染。
    // 2026-09-11 底部固定操作条改成右下角悬浮「取消/保存」后，原来那条
    //「合计(订单币种) 0.00」已删除——明细表下方本来就有合计，底部再报一遍是重复。
    expect(find.text('总金额(订单币种): '), findsOneWidget);
    expect(find.text('合计(订单币种) 0.00'), findsNothing);
    expect(find.textContaining('¥'), findsNothing);
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final rendered = await boundary.toImage();
      final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/staff-feedback/new-order.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      rendered.dispose();
    });
  });

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

      // 折扣列在横向虚拟化视口外时 TextField 未挂载，走控制器通道核对与修改
      //（与同文件 direct customer total 用例一致）。
      final row = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller
          .rows
          .single;
      expect(row.discount.text.trim(), '0.8');
      row.discount.text = '0.75';
      await tester.pump();

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(api.lastPutBody, isNotNull);
      expect(api.lastPutBody!['currencyId'], 'currency-usd');
      expect(api.lastPutBody!['taxRate'], '13');
      expect(api.lastPutBody!.containsKey('exchangeRate'), isFalse);
      expect(api.lastPutBody!.containsKey('deposit'), isFalse);
      final item = Map<String, dynamic>.from(
        (api.lastPutBody!['items'] as List<dynamic>).single as Map,
      );
      expect(item['id'], 'order-item-1');
      expect(item['unitId'], 'unit-box');
      expect(item['unitRate'], '10.0');
      expect(item['weight'], '5.25');
      expect(item['discount'], '0.75');
      expect(
        item.containsKey('amountOriginal'),
        isFalse,
        reason: 'binary preview is never submitted as financial authority',
      );
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
    expect(find.textContaining('订货发货必须从订货单引入'), findsOneWidget);
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
  String? initialOrderId,
  String? initialOrderItems,
  bool failBatchOnce = false,
  int batchCount = 1,
  Size size = const Size(1600, 1200),
  GlobalKey? capture,
  Set<String>? permissions,
  bool nativeReader = false,
}) async {
  if (capture != null) await loadAuditScreenshotFonts(tester);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _EditorApi(
    detail,
    failBatchOnce: failBatchOnce,
    batchCount: batchCount,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        apiClientProvider.overrideWithValue(api),
        // 本套件核对订单保存提交的单价/折扣原文：看不到价格的账号会被客户端
        // 脱敏(_priceMasked)，价格与折扣都不随保存提交，须显式授予价格查看权限。
        currentPermissionsProvider.overrideWithValue(
          permissions ??
              const {
                Perm.salesOrderView,
                Perm.salesOrderEdit,
                Perm.salesOrderPriceView,
              },
        ),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        if (nativeReader)
          ...nativeDetailReaderOverrides()
        else
          sessionProvider.overrideWith(_TestSessionNotifier.new),
      ],
      child: RepaintBoundary(
        key: capture,
        child: MaterialApp.router(
          theme: capture == null ? null : buildLightTheme(),
          // 保存成功后会 context.replace 跳详情；无 GoRouter 会抛断言，
          // 使「保存失败」通知顶掉 V187 转草稿提示（旧卡降级为无文本轮廓）。
          routerConfig: GoRouter(
            initialLocation: '/edit',
            routes: [
              GoRoute(
                path: '/edit',
                builder: (_, _) => SalesDocEditPage(
                  docType: type,
                  id: id,
                  initialOrderId: initialOrderId,
                  initialOrderItems: initialOrderItems,
                ),
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
  _EditorApi(this.detail, {this.failBatchOnce = false, this.batchCount = 1})
    : super(Dio());

  final Map<String, dynamic>? detail;
  Map<String, dynamic>? lastPutBody;
  final bool failBatchOnce;
  final int batchCount;
  final batchBodies = <Map<String, dynamic>>[];
  bool offerClient = false;
  bool clientSelectable = true;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (offerClient && path.endsWith('/clients')) {
      return {
        'items': [
          {
            'id': 'client-1',
            'name': '新选客户',
            'code': 'C1',
            'categoryId': 'client-category',
          },
        ],
        'page': 1,
        'size': 100,
        'total': 1,
        'totalPages': 1,
      };
    }
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
    if (offerClient && path.contains('client-categories')) {
      return [
        {
          'id': 'client-category',
          'code': 'C',
          'name': '客户分类',
          'level': 0,
          'children': <dynamic>[],
        },
      ];
    }
    if (offerClient && path == '/master/clients/lookup') {
      return [
        {
          'id': 'client-1',
          'name': '新选客户',
          'code': 'C1',
          'selectable': clientSelectable,
        },
      ];
    }
    if (path.endsWith('/plan-progress') && detail?['id'] == 'source-order') {
      return [
        {
          'orderItemId': 'source-line',
          'qty': 1000,
          'shippableQty': 10,
          'pendingShipmentQty': 0,
        },
      ];
    }
    return const [];
  }

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    if (path == '/sales/shipments/batch') {
      batchBodies.add(Map<String, dynamic>.from(body! as Map));
      if (failBatchOnce && batchBodies.length == 1) {
        throw NetworkTimeoutException();
      }
      return [
        for (var i = 0; i < batchCount; i++)
          {'id': 'shipment-$i', 'billNo': 'SH-$i', 'items': <Object>[]},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    lastPutBody = Map<String, dynamic>.from(body! as Map);
    return detail ?? const {'id': 'saved-order', 'items': <Object>[]};
  }
}

const _prefillOrder = {
  'id': 'source-order',
  'status': 1,
  'writable': true,
  'financeConfirmed': true,
  'clientId': 'client-1',
  'sellerId': 'seller-1',
  'settlementMethodId': 'settlement-net30',
  'items': [
    {
      'id': 'source-line',
      'goodsId': 'goods-1',
      'qty': 1000,
      'price': 2,
      'unitId': 'unit-box',
      'unitRate': 1,
    },
  ],
};

const _directTotal = {
  'id': 'direct-total',
  'shipmentKind': 'DIRECT_CUSTOMER',
  'billingMode': 'CHARGED',
  'directPurpose': 'SAMPLE',
  'reviewRevision': 0,
  'status': 0,
  'writable': true,
  'clientId': 'client-1',
  'currencyId': 'currency-usd',
  'warehouseId': 'warehouse-1',
  'shipAddr': '客户收货处',
  'linkPhone': '1234567',
  'warehouseWorkStatus': 'PENDING_PICK',
  'items': [
    {
      'id': 'direct-line',
      'goodsId': 'goods-1',
      'unitId': 'unit-box',
      'unitRate': 1,
      'qty': 2,
      'price': 1,
      'discount': 1,
    },
  ],
};
