import '../support/return_probe_grid.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import '../support/memory_form_draft_storage.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/buttons/uten_import_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import '../support/document_scope_capability_overrides.dart';

class Session extends SessionNotifier {
  @override
  SessionState build() => userState('A');
  SessionState userState(String id) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: id,
      name: id,
      code: id,
      permissions: const [
        'purchase_return:create',
        'subcontract_return:create',
      ],
    ),
  );
  void switchOwner() => state = userState('B');
}

class Api extends ApiClient {
  Api() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    const doc = <String, dynamic>{
      'id': 'source-doc',
      'billNo': 'EXACT-SOURCE',
      'billDate': '2026-11-11',
      'supplierId': 'supplier-A',
      'status': 1,
    };
    if (path.endsWith('/receipts')) {
      return {
        'items': [doc],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path.endsWith('/receipts/source-doc')) {
      return {
        ...doc,
        'currencyId': 'currency-A',
        'exchangeRate': 1,
        'exchangeRateExact': '1',
        'taxRate': 0,
        'taxRateExact': '0',
        'settlementMethodId': 'terms-A',
        'priceMasked': false,
        'items': [
          {
            'id': 'approved-receipt-A',
            'goodsId': 'g-A',
            'qty': 1234567890123.0,
            'qtyExact': '1234567890123.0001',
            'unitRate': 1,
            'unitRateExact': '1',
            'returnedQty': 0,
            'returnedQtyExact': '0',
            'giftQty': 0,
            'giftQtyExact': '0',
            'giftReturnedQty': 0,
            'giftReturnedQtyExact': '0',
            'returnableGiftQty': 0,
            'returnableGiftQtyExact': '0',
            'quantitySemantics': 'CHARGED_PLUS_GIFT_V1',
            'price': 1,
            'priceExact': '1.000000000000000001',
          },
        ],
      };
    }
    return {
      'items': <Object>[],
      'page': 1,
      'size': 50,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

class Names extends MasterNameService {
  Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  final proceed = Completer<void>();
  var detailEntered = false;
  @override
  Future<void> loadGoodsNamesWithCodes(Iterable<String> ids) async {}
  @override
  GoodsOption? goodsOptionOf(String? id) => GoodsOption(id: id!, name: '来源A');
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {
    if (ids.contains('g-A')) {
      detailEntered = true;
      await proceed.future;
    }
  }
}

void main() {
  for (final purchase in [true, false]) {
    testWidgets(
      'actual source adapter must retain exact quantity and price ${purchase ? 'purchase' : 'subcontract'} source',
      (t) async {
        await t.binding.setSurfaceSize(const Size(1800, 1150));
        addTearDown(() => t.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final api = Api(),
            names = Names(api),
            nav = GlobalKey<NavigatorState>();
        final page = purchase
            ? const PurchaseDocEditPage(docType: PurchaseDocType.returnDoc)
            : const SubcontractDocEditPage(
                docType: SubcontractDocType.returnDoc,
              );
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(Session.new),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
            apiClientProvider.overrideWithValue(api),
            masterNameServiceProvider.overrideWithValue(names),
            writeAllDocumentScope(
              purchase
                  ? DocumentDataScope.purchase
                  : DocumentDataScope.subcontract,
            ),
          ],
        );
        addTearDown(container.dispose);
        await t.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(navigatorKey: nav, home: page),
          ),
        );
        for (var tick = 0; tick < 12; tick++) {
          await t.pump(const Duration(milliseconds: 80));
        }
        final state =
            t.state<State>(find.byWidget(page))
                as FormDraftMixin<ConsumerStatefulWidget>;
        final grid = ReturnProbeGrid.capture(t, purchase);
        grid.rows.first.qty.text = '7.125';
        expect(state.formDraftIdentityIsCurrent, true);
        await t.tap(find.byType(UtenImportButton));
        for (var tick = 0; tick < 12; tick++) {
          await t.pump(const Duration(milliseconds: 80));
        }
        const exactQty = '1234567890123.0001',
            exactPrice = '1.000000000000000001';
        names.proceed.complete();
        expect(find.text('EXACT-SOURCE'), findsOneWidget);
        await t.tap(find.text('EXACT-SOURCE'));
        await t.pump(const Duration(milliseconds: 80));
        await t.tap(find.text('EXACT-SOURCE'));
        for (var tick = 0; tick < 12; tick++) {
          await t.pump(const Duration(milliseconds: 80));
        }
        expect(find.byType(Checkbox), findsWidgets);
        await t.tap(find.byType(Checkbox).hitTestable().first);
        await t.pump();
        await t.tap(find.text('引入').hitTestable());
        for (var tick = 0; tick < 20; tick++) {
          await t.pump(const Duration(milliseconds: 80));
        }
        expect(names.detailEntered, true);
        expect(state.formDraftIdentityIsCurrent, true);
        final row = grid.rows.last;
        debugPrint(
          'AUDIT purchase=$purchase expected qty=$exactQty price=$exactPrice actual qty=${row.qty.text} price=${row.price.text} originalInput=${grid.rows.first.qty.text}',
        );
        expect([row.qty.text, row.price.text], [exactQty, exactPrice]);
        await t.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await t.pump();
      },
    );
  }
}
