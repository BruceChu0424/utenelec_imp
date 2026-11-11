import '../support/return_probe_grid.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import '../support/memory_form_draft_storage.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/layout/uten_doc_link_picker_sheet.dart';
import 'package:uten_imp/components/buttons/uten_import_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';
import 'package:uten_imp/shared/models/procurement_source_terms.dart';
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
  }) async => {
    'items': <Object>[],
    'page': 1,
    'size': 50,
    'total': 0,
    'totalPages': 0,
  };
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
      'repeat upstream import while source read pending ${purchase ? 'purchase' : 'subcontract'} source',
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
        const rows = [
          UtenDocLinkPickedItem(
            goodsId: 'g-A',
            qty: 2,
            upstreamItemId: 'approved-receipt-A',
            unitRate: 1,
          ),
        ];
        const terms = ProcurementSourceTerms(
          currencyId: 'currency-A',
          exchangeRate: '1',
          taxRate: '0',
          settlementMethodId: 'terms-A',
        );
        if (purchase) {
          nav.currentState!.pop(
            const UtenDocLinkPickResult<PurchaseDocItem>(
              items: rows,
              partyId: 'supplier-A',
              sourceTerms: terms,
            ),
          );
        } else {
          nav.currentState!.pop(
            const UtenDocLinkPickResult<SubcontractDocItem>(
              items: rows,
              partyId: 'supplier-A',
              sourceTerms: terms,
            ),
          );
        }
        for (var tick = 0; tick < 12; tick++) {
          await t.pump(const Duration(milliseconds: 80));
        }
        expect(names.detailEntered, true);
        final overlayCount = find.byType(UtenBusyOverlay).evaluate().length;
        debugPrint('AUDIT pending lookup busyOverlayCount=$overlayCount');
        expect(
          overlayCount,
          1,
          reason: 'source enrichment is part of the same waiting action',
        );
        expect(
          t.widget<UtenImportButton>(find.byType(UtenImportButton)).onPressed,
          isNull,
        );
        expect(
          nav.currentState!.canPop(),
          false,
          reason:
              'the first action owns the complete import until enrichment finishes',
        );
        names.proceed.complete();
        for (var tick = 0; tick < 12; tick++) {
          await t.pump(const Duration(milliseconds: 80));
        }
        final ids = [for (final row in grid.rows) row.upstreamItemId];
        debugPrint(
          'audit purchase=$purchase retired=${!state.formDraftIdentityIsCurrent} sourceIds=$ids originalInput=${grid.rows.first.qty.text}',
        );
        expect(
          ids.where((id) => id == 'approved-receipt-A'),
          hasLength(1),
          reason:
              'repeated click during pending lookup cannot append the same source twice',
        );
        await t.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await t.pump();
      },
    );
  }
}
