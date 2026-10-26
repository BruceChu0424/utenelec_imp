import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_supplier_picker.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  for (final subcontract in [false, true]) {
    for (final manual in [false, true]) {
      testWidgets(
        '${subcontract ? 'subcontract' : 'purchase'} late settlement keeps ${manual ? 'manual input' : 'the current supplier'}',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1600, 1100));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final methods = Completer<List<ReferenceMethodOption>>();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                apiBaseUrlProvider.overrideWithValue(
                  'http://localhost:8080/api',
                ),
                apiClientProvider.overrideWithValue(_Api()),
                sessionProvider.overrideWith(_Session.new),
                settlementMethodOptionsProvider.overrideWith(
                  (ref) => methods.future,
                ),
              ],
              child: MaterialApp(
                home: subcontract
                    ? const SubcontractDocEditPage(
                        docType: SubcontractDocType.receipt,
                      )
                    : const PurchaseDocEditPage(
                        docType: PurchaseDocType.receipt,
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final supplier = find.byType(SupplierPickerField);
          tester.widget<SupplierPickerField>(supplier).onChanged('supplier-a');
          await tester.pump();
          final field = find.byWidgetPredicate(
            (widget) =>
                widget is UtenDropdownField &&
                widget.label == (subcontract ? '结算方式' : '结账方式'),
          );
          if (manual) {
            tester.widget<UtenDropdownField>(field).onChanged('manual');
          } else {
            tester
                .widget<SupplierPickerField>(supplier)
                .onChanged('supplier-b');
          }
          await tester.pump();
          methods.complete(const [
            ReferenceMethodOption(
              id: 'default-a',
              code: 'A',
              name: 'Default A',
            ),
            ReferenceMethodOption(
              id: 'default-b',
              code: 'B',
              name: 'Default B',
            ),
            ReferenceMethodOption(id: 'manual', code: 'M', name: 'Manual'),
          ]);
          await tester.pumpAndSettle();
          expect(
            tester.widget<UtenDropdownField>(field).value,
            manual ? 'manual' : 'default-b',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'items': <Object>[],
    'page': 1,
    'size': 1,
    'total': 0,
    'totalPages': 0,
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.suppliersDict) {
      return [
        {
          'id': 'supplier-a',
          'name': 'Supplier A',
          'defaultSettlementMethodId': 'default-a',
        },
        {
          'id': 'supplier-b',
          'name': 'Supplier B',
          'defaultSettlementMethodId': 'default-b',
        },
      ];
    }
    return [];
  }
}
