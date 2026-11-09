import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/widgets/sales_batch_ship_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../helpers/badge_summary_fixture.dart';

const _total = 301;

class _Names extends SalesMasterNameService {
  _Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsNames(Iterable<String> ids) async {}
  @override
  Future<void> loadClientNames(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '产品$id';
  @override
  String client(String? id) => '客户$id';
  @override
  String color(String? id) => '';
  @override
  String unit(String? id) => '箱';
}

/// Offset-exact shippable lines. While [continuation] is set, every batch
/// after the first waits for it, so the first batch stays a growing prefix.
class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));

  final queries = <Map<String, dynamic>>[];
  final commands = <Map<String, dynamic>>[];
  Completer<void>? continuation;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/orders/shippable-lines/page') return {};
    final parameters = Map<String, dynamic>.of(query!);
    queries.add(parameters);
    final page = parameters['page'] as int;
    final size = parameters['size'] as int;
    if ((page - 1) * size > 0) await continuation?.future;
    return {
      'items': [
        for (
          var i = (page - 1) * size + 1;
          i <= page * size && i <= _total;
          i++
        )
          {
            'orderItemId': 'line-$i',
            'orderId': 'order-$i',
            'billNo': 'SO-$i',
            'clientId': 'client-a',
            'goodsId': 'goods-$i',
            'reservedQty': 10,
            'writable': true,
          },
      ],
      'page': page,
      'size': size,
      'total': _total,
      'totalPages': (_total / size).ceil(),
    };
  }

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    expect(path, '/sales/shipments/batch');
    commands.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(body)) as Map),
    );
    return [
      {'id': 'created-shipment'},
    ];
  }
}

Finder _rowCheck(int index) =>
    find.byKey(ValueKey('sales-batch-select-line-$index'));

Finder _qty(int index) => find.descendant(
  of: find.byKey(ValueKey('sales-batch-qty-line-$index')),
  matching: find.byType(TextField),
);

UtenButton _confirm(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('sales-batch-confirm')));

void main() {
  testWidgets(
    'while a read is still growing, row checks and 生成出货单 wait for the '
    'complete result; the kept selection and quantity survive',
    (tester) async {
      final api = _Api();
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            salesMasterNameServiceProvider.overrideWithValue(_Names(api)),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'sales-reader'),
            ),
            apiBaseUrlProvider.overrideWithValue('https://fixture.invalid/api'),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesShipmentCreate,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            fixedBadgeSummaryOverride(badgeSummaryFixture()),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () => showSalesBatchShipPanel(context, ref),
                  child: const Text('打开批量发货'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开批量发货'));
      await tester.pumpAndSettle();

      // A complete result: pick one line and edit its quantity.
      await tester.tap(_rowCheck(1));
      await tester.pumpAndSettle();
      await tester.enterText(_qty(1), '0002.5000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('生成出货单(1 行)'), findsOneWidget);

      // A new query keeps the selection; its first batch shows at once while
      // the following batches are still being read.
      api.continuation = Completer<void>();
      final reads = api.queries.length;
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('sales-batch-search')),
          matching: find.byType(TextField),
        ),
        'SO',
      );
      for (var frame = 0; frame < 60; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (api.queries.length >= reads + 2) break;
      }
      await tester.pump(const Duration(milliseconds: 16));
      expect(api.queries.skip(reads).map((query) => query['keyword']), [
        'SO',
        'SO',
      ]);
      expect(_rowCheck(2), findsOneWidget);

      expect(tester.widget<Checkbox>(_rowCheck(2)).onChanged, isNull);
      expect(tester.widget<Checkbox>(_rowCheck(1)).onChanged, isNull);
      expect(tester.widget<Checkbox>(_rowCheck(1)).value, isTrue);
      expect(find.text('生成出货单(1 行)'), findsOneWidget);
      expect(_confirm(tester).onPressed, isNull);
      await tester.tap(find.byKey(const Key('sales-batch-confirm')));
      await tester.pump();
      expect(api.commands, isEmpty);
      expect(tester.widget<TextField>(_qty(1)).controller!.text, '0002.5000');

      // The complete result restores row checks and the batch shipment.
      api.continuation!.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(_rowCheck(2)).onChanged, isNotNull);
      expect(tester.widget<Checkbox>(_rowCheck(1)).value, isTrue);
      expect(_confirm(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('sales-batch-confirm')));
      await tester.pumpAndSettle();
      expect(api.commands.single['lines'], [
        {'orderItemId': 'line-1', 'qty': 2.5},
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
