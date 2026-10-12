import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/models/procurement_quantity.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';

import '../../support/native_detail_reader_overrides.dart';

import 'package:uten_imp/components/data_display/uten_review_input_cell.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';

void main() {
  for (final module in ['purchase', 'subcontract']) {
    for (final segment in ['receipts', 'returns']) {
      testWidgets(
        '$module $segment review-only form retains creation columns and submits exact amended quantities once',
        (tester) async {
          final api = await _pump(
            tester,
            module,
            segment,
            chargedQty: '10',
            giftQty: '1',
            quantitySemantics: procurementChargedPlusGiftQuantity,
          );
          final grid = module == 'purchase'
              ? tester.widget<UtenEditableGrid<PurchaseGridRow>>(
                  find.byType(UtenEditableGrid<PurchaseGridRow>),
                )
              : tester.widget<UtenEditableGrid<SubcontractGridRow>>(
                  find.byType(UtenEditableGrid<SubcontractGridRow>),
                );
          final columns = grid.columns.map((column) => column.key).toList();
          expect(columns, containsAll(['goods', 'qty', 'remark']));
          expect(grid.showAddRow, isFalse);
          expect(grid.cloneRow, isNull);
          if (module == 'purchase') {
            final row = _purchaseGrid(tester).controller.rows.single;
            expect(row.sourceLocked, isTrue);
            row.qty.text = '7.3756';
            row.giftQty.text = '0.6256';
          } else {
            final row = tester
                .widget<UtenEditableGrid<SubcontractGridRow>>(
                  find.byType(UtenEditableGrid<SubcontractGridRow>),
                )
                .controller
                .rows
                .single;
            expect(row.sourceLocked, isTrue);
            row.qty.text = '7.3756';
          }
          await tester.pumpAndSettle();
          expect(find.byType(UtenReviewInputCell), findsWidgets);
          final old = find.text('10');
          expect(old, findsWidgets);
          final oldText = tester.widget<Text>(old.first);
          expect(oldText.style?.decoration, TextDecoration.lineThrough);
          await _saveGift(tester);
          expect(api.saved, isNull);
          expect(find.widgetWithText(FilledButton, '确认审核'), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
          await tester.pumpAndSettle();
          final saved = api.saved!;
          expect(saved['expectedSnapshot'], 'a' * 64);
          expect(saved['approveNow'], isTrue);
          final document = saved['document'] as Map<String, dynamic>;
          final item =
              (document['items'] as List).single as Map<String, dynamic>;
          expect(item['qty'], '7.3756');
          expect(item['sourceItemId'], 'draft-line');
          expect(item.containsKey('amountOriginal'), isFalse);
          expect(item.containsKey('amountLocal'), isFalse);
          if (module == 'purchase') {
            expect(item['giftQty'], '0.6256');
            if (segment == 'receipts') {
              expect(item['replacementIntent'], 'NORMAL');
              expect(item['giftReplacementIntent'], 'RETURN_REPLACEMENT');
            }
          }
          expect(find.text('打开审核'), findsOneWidget);
        },
      );
    }
  }
  testWidgets(
    'review source intents survive a local draft round trip independently of charged/free quantities',
    (tester) async {
      await _pump(
        tester,
        'purchase',
        'receipts',
        chargedQty: '10',
        giftQty: '1',
        quantitySemantics: procurementChargedPlusGiftQuantity,
      );
      final row = _purchaseGrid(tester).controller.rows.single;
      expect(row.replacementIntent, 'NORMAL');
      expect(row.giftReplacementIntent, 'RETURN_REPLACEMENT');
      final cloned = PurchaseGridRow.fromDraft(row.exportDraft());
      expect(cloned.replacementIntent, 'NORMAL');
      expect(cloned.giftReplacementIntent, 'RETURN_REPLACEMENT');
      cloned.dispose();
    },
  );
  testWidgets(
    'masked review keeps source commercial values out of the save payload',
    (tester) async {
      final api = await _pump(
        tester,
        'purchase',
        'receipts',
        masked: true,
        chargedQty: '10',
        giftQty: '1',
        quantitySemantics: procurementChargedPlusGiftQuantity,
      );
      _purchaseGrid(tester).controller.rows.single.qty.text = '7.3756';
      await _saveGift(tester);
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pumpAndSettle();
      final document = api.saved!['document'] as Map<String, dynamic>;
      expect(document.containsKey('exchangeRate'), isFalse);
      expect(document.containsKey('taxRate'), isFalse);
      expect(document.containsKey('currencyId'), isFalse);
    },
  );
  testWidgets(
    'changing identity cancels a pending review confirmation and hides old inputs',
    (tester) async {
      final api = await _pump(
        tester,
        'purchase',
        'receipts',
        chargedQty: '10',
        giftQty: '1',
        quantitySemantics: procurementChargedPlusGiftQuantity,
      );
      _purchaseGrid(tester).controller.rows.single.qty.text = '7.3756';
      await _saveGift(tester);
      expect(find.widgetWithText(FilledButton, '确认审核'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PurchaseDocEditPage)),
      );
      (container.read(sessionProvider.notifier) as _ReviewSession)
          .switchReader();
      await tester.pumpAndSettle();
      expect(api.saved, isNull);
      expect(find.byType(UtenEditableGrid<PurchaseGridRow>), findsNothing);
      expect(find.widgetWithText(FilledButton, '确认审核'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _ReviewSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'reviewer-a',
      code: 'A',
      name: '审核人A',
      employeeId: 'reviewer-employee-a',
    ),
  );
  void switchReader() => state = const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'reviewer-b',
      code: 'B',
      name: '审核人B',
      employeeId: 'reviewer-employee-b',
    ),
    impersonationReadOnly: true,
  );
}

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
    initialLocation: base,
    routes: [
      GoRoute(
        path: '$base/edit',
        builder: (_, _) => module == 'purchase'
            ? PurchaseDocEditPage(
                docType: segment == 'receipts'
                    ? PurchaseDocType.receipt
                    : PurchaseDocType.returnDoc,
                id: 'source-draft',
                reviewMode: true,
              )
            : SubcontractDocEditPage(
                docType: segment == 'receipts'
                    ? SubcontractDocType.receipt
                    : SubcontractDocType.returnDoc,
                id: 'source-draft',
                reviewMode: true,
              ),
      ),
      GoRoute(
        path: base,
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => context.push('$base/edit'),
            child: const Text('打开审核'),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(includeSession: false),
        sessionProvider.overrideWith(_ReviewSession.new),
        currentPermissionsProvider.overrideWithValue({
          '${module}_${segment == 'receipts' ? 'receipt' : 'return'}:view',
          '${module}_${segment == 'receipts' ? 'receipt' : 'return'}:approve',
        }),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开审核'));
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
    'canEdit': false,
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
        'replacementIntent': 'NORMAL',
        'giftReplacementIntent': 'RETURN_REPLACEMENT',
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
    if (path == '/$module/$segment/source-draft/review') {
      return {'snapshot': 'a' * 64, 'detail': detail};
    }
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
  }) async {
    if (path == '/$module/$segment/source-draft/review') {
      saved = Map<String, dynamic>.from(body as Map);
      return {...detail, 'status': 1};
    }
    return const {};
  }
}
