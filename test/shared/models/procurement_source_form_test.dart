import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_placeholder.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/models/procurement_quantity.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';

import '../../support/native_detail_reader_overrides.dart';

void main() {
  for (final segment in ['receipts', 'returns']) {
    testWidgets(
      'purchase $segment separates charged10 gift1 physical11 in actual load and save',
      (tester) async {
        final api = await _pump(
          tester,
          'purchase',
          segment,
          chargedQty: '10',
          giftQty: '1',
          quantitySemantics: procurementChargedPlusGiftQuantity,
        );
        final row = _purchaseGrid(tester).controller.rows.single;
        expect(row.qty.text, '10');
        expect(row.giftQty.text, '1');
        expect(row.physicalQtyText, '11');
        await _saveGift(tester);
        final item = (api.saved!['items'] as List)
            .cast<Map<String, dynamic>>()
            .single;
        expect(item['qty'], '10');
        expect(item['giftQty'], '1');
        expect(item.containsKey('physicalQty'), isFalse);
        expect(item.containsKey('amountOriginal'), isFalse);
        expect(item.containsKey('amountLocal'), isFalse);
      },
    );
    testWidgets(
      'purchase $segment permits recorded gift-only actual quantity without charged quantity',
      (tester) async {
        final api = await _pump(
          tester,
          'purchase',
          segment,
          chargedQty: '0',
          giftQty: '1',
          quantitySemantics: procurementChargedPlusGiftQuantity,
        );
        expect(
          _purchaseGrid(tester).controller.rows.single.physicalQtyText,
          '1',
        );
        await _saveGift(tester);
        final item = (api.saved!['items'] as List)
            .cast<Map<String, dynamic>>()
            .single;
        expect(item['qty'], '0');
        expect(item['giftQty'], '1');
      },
    );
    testWidgets(
      'purchase $segment retains legacy physical10 until explicit draft upgrade and draft restore',
      (tester) async {
        final api = await _pump(
          tester,
          'purchase',
          segment,
          chargedQty: '10',
          giftQty: '1',
          quantitySemantics: procurementLegacyQuantity,
        );
        final row = _purchaseGrid(tester).controller.rows.single;
        expect(row.physicalQtyText, '10');
        expect(row.hasExtraGift, isFalse);
        final giftField = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && identical(widget.controller, row.giftQty),
        );
        expect(tester.widget<TextField>(giftField).readOnly, isTrue);
        final confirm = find.byKey(
          const Key('purchase-confirm-gift-semantics'),
        );
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pump();
        expect(row.physicalQtyText, '11');
        expect(row.hasExtraGift, isTrue);
        final state = _formState(tester, 'purchase');
        final captured =
            jsonDecode(jsonEncode(state.captureFormDraft()))
                as Map<String, dynamic>;
        expect(captured['confirmGiftSemantics'], isTrue);
        await state.restoreFormDraft(captured);
        await tester.pump();
        expect(
          _purchaseGrid(tester).controller.rows.single.physicalQtyText,
          '11',
        );
        await _saveGift(tester);
        expect(api.saved!['confirmGiftSemantics'], isTrue);
      },
    );
    testWidgets(
      'purchase $segment blocks a negative gift without sending a save',
      (tester) async {
        final api = await _pump(
          tester,
          'purchase',
          segment,
          chargedQty: '10',
          giftQty: '1',
          quantitySemantics: procurementChargedPlusGiftQuantity,
        );
        final row = _purchaseGrid(tester).controller.rows.single;
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                identical(widget.controller, row.giftQty),
          ),
          '-0.0001',
        );
        await _saveGift(tester);
        expect(api.saved, isNull);
      },
    );
  }

  for (final module in ['purchase', 'subcontract']) {
    for (final segment in ['receipts', 'returns']) {
      testWidgets(
        '$module $segment retains source terms through draft restore and omits them from a real save',
        (tester) async {
          final api = await _pump(tester, module, segment);
          final rate = tester.widget<TextField>(_field('汇率'));
          expect(rate.controller?.text, '7.123456');
          expect(rate.readOnly, isTrue);
          final tax = tester.widget<TextField>(_field('税率(%)'));
          expect(tax.controller?.text, '13.120001');
          expect(tax.readOnly, isTrue);
          final currency = tester.widget<UtenDropdownField>(
            find.byWidgetPredicate(
              (widget) => widget is UtenDropdownField && widget.label == '币种',
            ),
          );
          expect(currency.enabled, isFalse);

          final state = _formState(tester, module);
          final captured = Map<String, dynamic>.from(state.captureFormDraft());
          final restored =
              jsonDecode(jsonEncode(captured)) as Map<String, dynamic>;
          expect(restored['sourceTerms'], {
            'currencyId': 'usd',
            'exchangeRate': '7.123456',
            'taxRate': '13.120001',
            'settlementMethodId': 'monthly',
          });
          await state.restoreFormDraft(restored);
          await tester.pump();
          expect(
            (state.captureFormDraft())['sourceTerms'],
            restored['sourceTerms'],
          );

          final save = find.byWidgetPredicate(
            (widget) =>
                widget is UtenButton &&
                widget.child is Text &&
                (widget.child as Text).data!.startsWith('保存'),
          );
          expect(save, findsOneWidget);
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();

          expect(api.saved, isNotNull);
          for (final key in [
            'currencyId',
            'exchangeRate',
            'taxRate',
            'settlementMethodId',
            'sourceTerms',
          ]) {
            expect(
              api.saved!.containsKey(key),
              isFalse,
              reason: '$key must be derived by the server',
            );
          }
          final line = (api.saved!['items'] as List).single as Map;
          expect(
            line[segment == 'receipts' ? 'orderItemId' : 'receiptItemId'],
            'source-line',
          );
          expect(line['qty'].toString(), '10.1256');
          expect(line.containsKey('amountOriginal'), isFalse);
          expect(line.containsKey('amountLocal'), isFalse);
          expect(find.text('saved-detail'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('$module masked linked receipt shows no invented rate', (
      tester,
    ) async {
      await _pump(tester, module, 'receipts', masked: true);
      final field = tester.widget<TextField>(_field('汇率'));
      expect(field.controller?.text, isEmpty);
      expect(field.readOnly, isTrue);
      final state = _formState(tester, module);
      expect(
        (state.captureFormDraft()['sourceTerms']
            as Map<String, dynamic>)['exchangeRate'],
        isNull,
      );
    });

    testWidgets(
      '$module masked old payload cannot reveal a remaining raw rate',
      (tester) async {
        await _pump(
          tester,
          module,
          'receipts',
          masked: true,
          staleMaskedRate: true,
        );
        final field = tester.widget<TextField>(_field('汇率'));
        expect(field.controller?.text, isEmpty);
        expect(field.readOnly, isTrue);
      },
    );

    testWidgets('$module missing tax facts remain empty instead of zero', (
      tester,
    ) async {
      await _pump(tester, module, 'receipts', unknownTax: true);
      final field = tester.widget<TextField>(_field('税率(%)'));
      expect(field.controller?.text, isEmpty);
      final state = _formState(tester, module);
      expect(
        (state.captureFormDraft()['sourceTerms']
            as Map<String, dynamic>)['taxRate'],
        isNull,
      );
    });

    testWidgets('$module legacy numeric rate remains a recorded source fact', (
      tester,
    ) async {
      await _pump(tester, module, 'receipts', legacyNumericRate: true);
      final field = tester.widget<TextField>(_field('汇率'));
      expect(field.controller?.text, '7.1');
      final state = _formState(tester, module);
      expect(
        (state.captureFormDraft()['sourceTerms']
            as Map<String, dynamic>)['exchangeRate'],
        '7.1',
      );
    });
  }
}

// An empty field now has the same business name in its label and placeholder.
// Match the field itself once, keeping uniqueness and every business assertion.
Finder _field(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.decoration != null &&
      utenDecorationFieldName(widget.decoration!) == label,
);

FormDraftMixin<ConsumerStatefulWidget> _formState(
  WidgetTester tester,
  String module,
) =>
    tester.state(
          module == 'purchase'
              ? find.byType(PurchaseDocEditPage)
              : find.byType(SubcontractDocEditPage),
        )
        as FormDraftMixin<ConsumerStatefulWidget>;

Future<_FormApi> _pump(
  WidgetTester tester,
  String module,
  String segment, {
  bool masked = false,
  bool staleMaskedRate = false,
  bool legacyNumericRate = false,
  bool unknownTax = false,
  String? chargedQty,
  String? giftQty,
  String? quantitySemantics,
}) async {
  await tester.binding.setSurfaceSize(const Size(1700, 1250));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _FormApi(
    module,
    segment,
    masked,
    staleMaskedRate: staleMaskedRate,
    legacyNumericRate: legacyNumericRate,
    unknownTax: unknownTax,
    chargedQty: chargedQty,
    giftQty: giftQty,
    quantitySemantics: quantitySemantics,
  );
  final base = '/$module/$segment/source-draft';
  final router = GoRouter(
    initialLocation: '$base/edit',
    routes: [
      GoRoute(
        path: '$base/edit',
        builder: (_, _) => module == 'purchase'
            ? PurchaseDocEditPage(
                docType: segment == 'receipts'
                    ? PurchaseDocType.receipt
                    : PurchaseDocType.returnDoc,
                id: 'source-draft',
              )
            : SubcontractDocEditPage(
                docType: segment == 'receipts'
                    ? SubcontractDocType.receipt
                    : SubcontractDocType.returnDoc,
                id: 'source-draft',
              ),
      ),
      GoRoute(
        path: base,
        builder: (_, _) => const Scaffold(body: Text('saved-detail')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

UtenEditableGrid<PurchaseGridRow> _purchaseGrid(WidgetTester tester) =>
    tester.widget(find.byType(UtenEditableGrid<PurchaseGridRow>));
Future<void> _saveGift(WidgetTester tester) async {
  final save = find.byWidgetPredicate(
    (widget) =>
        widget is UtenButton &&
        widget.child is Text &&
        (widget.child as Text).data!.startsWith('保存'),
  );
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

class _FormApi extends ApiClient {
  _FormApi(
    this.module,
    this.segment,
    this.masked, {
    this.staleMaskedRate = false,
    this.legacyNumericRate = false,
    this.unknownTax = false,
    this.chargedQty,
    this.giftQty,
    this.quantitySemantics,
  }) : super(Dio());
  final String module;
  final String segment;
  final bool masked;
  final bool staleMaskedRate;
  final bool legacyNumericRate;
  final bool unknownTax;
  final String? chargedQty;
  final String? giftQty;
  final String? quantitySemantics;
  Map<String, dynamic>? saved;

  Map<String, dynamic> get detail => {
    'id': 'source-draft',
    'status': 0,
    'writable': true,
    'canEdit': true,
    'makerId': 'maker-owner',
    'billDate': '2026-10-11',
    'supplierId': 'supplier',
    'warehouseId': 'warehouse',
    'currencyId': 'usd',
    'exchangeRate': masked
        ? (staleMaskedRate ? 7.123456 : null)
        : (legacyNumericRate ? 7.1 : 7.123456),
    'exchangeRateExact': masked
        ? (staleMaskedRate ? '7.123456' : null)
        : (legacyNumericRate ? null : '7.123456'),
    'priceMasked': masked,
    'taxRate': unknownTax ? null : 13.12,
    'taxRateExact': unknownTax ? null : '13.120001',
    'settlementMethodId': 'monthly',
    'items': [
      {
        'id': 'draft-line',
        'goodsId': 'goods',
        'goodsCodeSnapshot': 'G001',
        'goodsNameSnapshot': '货品',
        'unitId': 'piece',
        'unitRate': 1,
        'qty': chargedQty == null ? 10.1256 : double.parse(chargedQty!),
        'qtyExact': chargedQty ?? '10.1256',
        if (giftQty != null) 'giftQtyExact': giftQty,
        if (quantitySemantics != null) 'quantitySemantics': quantitySemantics,
        'price': 4.05,
        if (segment == 'receipts')
          'orderItemId': 'source-line'
        else
          'receiptItemId': 'source-line',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/$module/$segment/source-draft') return detail;
    return const {
      'items': <Map<String, dynamic>>[],
      'total': 0,
      'page': 1,
      'size': 20,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('currencies')) {
      return const [
        {'id': 'usd', 'name': '美元'},
      ];
    }
    if (path.contains('settlement-methods')) {
      return const [
        {'id': 'monthly', 'name': '月结', 'status': '使用'},
      ];
    }
    if (path.contains('suppliers')) {
      return const [
        {'id': 'supplier', 'name': '供应商', 'status': '使用'},
      ];
    }
    if (path.contains('units')) {
      return const [
        {'id': 'piece', 'name': '件'},
      ];
    }
    if (path.contains('goods') && path.contains('lookup')) {
      return const [
        {'id': 'goods', 'code': 'G001', 'name': '货品'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    saved = Map<String, dynamic>.from(body as Map);
    return detail;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async => const {};
}
