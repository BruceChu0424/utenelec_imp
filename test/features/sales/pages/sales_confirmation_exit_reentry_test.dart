import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../../support/native_detail_reader_overrides.dart';

void main() {
  for (final quantity in [true, false]) {
    testWidgets(
      '${quantity ? 'order quantity' : 'shipment reject'} ignores a second real pointer during confirmation exit',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = _Api(quantity);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...nativeDetailReaderOverrides(),
              apiClientProvider.overrideWithValue(api),
              salesMasterNameServiceProvider.overrideWithValue(
                SalesMasterNameService(api),
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.salesOrderView,
                Perm.salesOrderChangeQty,
                Perm.salesShipmentView,
                Perm.salesShipmentReject,
              }),
              isSuperAdminProvider.overrideWithValue(false),
            ],
            child: MaterialApp(
              home: SalesDocDetailPage(
                docType: quantity ? SalesDocType.order : SalesDocType.shipment,
                id: 'exit-owner',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final action = find.text(quantity ? '改量' : '驳回');
        expect(action, findsOneWidget);
        final backgroundPoint = tester.getCenter(action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog).last;
        final route = ModalRoute.of(tester.element(dialog))!;
        var exited = false;
        route.completed.then((_) => exited = true);
        await tester.enterText(
          find.descendant(of: dialog, matching: find.byType(TextField)).first,
          quantity ? '5' : '核对后退回',
        );
        await tester.tap(
          find.descendant(
            of: dialog,
            matching: find.text(quantity ? '确认改量' : '确认驳回'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(exited, isFalse);
        expect(api.commands, isEmpty);
        // This is a real hit test against the background button, rather than
        // invoking its callback while a modal route owns pointer input.
        await tester.tapAt(backgroundPoint);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          find.byType(AlertDialog),
          findsOneWidget,
          reason:
              'The first confirmation is still exiting; another must not open.',
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(exited, isTrue);
        expect(api.commands.length, 1);
        api.command.complete(api.detail);
        await tester.pumpAndSettle();
        expect(api.commands.length, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _Api extends ApiClient {
  _Api(bool quantity)
    : detail = {
        'id': 'exit-owner',
        'status': quantity ? 1 : 0,
        'writable': true,
        'financeConfirmed': quantity,
        'canReject': true,
        'items': [
          {'id': 'line', 'goodsId': 'goods', 'qty': 3, 'price': 10},
        ],
      },
      super(Dio());
  final Map<String, dynamic> detail;
  final command = Completer<Map<String, dynamic>>();
  final commands = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => detail;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    commands.add(path);
    return command.future;
  }
}
