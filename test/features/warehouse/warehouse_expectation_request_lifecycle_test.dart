import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_expectations_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets('unmounting while loading does not start follow-up reads', (
    tester,
  ) async {
    final api = _DelayedApi();
    await tester.pumpWidget(
      _host(api, const WarehouseInboundExpectationsView()),
    );
    await tester.pump();
    expect(api.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    api.requests.single.complete(_emptyPage);
    await tester.pump();
    expect(api.countReads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing an embedded source switches the server filter', (
    tester,
  ) async {
    final api = _DelayedApi();
    Future<void> mount(ProcurementInboundOrderType type) => tester.pumpWidget(
      _host(
        api,
        WarehouseInboundExpectationsView(fixedOrderType: type, embedded: true),
      ),
    );
    await mount(ProcurementInboundOrderType.purchase);
    await tester.pump();
    await mount(ProcurementInboundOrderType.subcontract);
    await tester.pump();
    expect(api.types, ['PURCHASE', 'SUBCONTRACT']);
    api.requests.last.complete(_emptyPage);
    await tester.pumpAndSettle();
    api.requests.first.complete(_emptyPage);
    await tester.pumpAndSettle();
    // Only the current page may request its supplementary counts.
    expect(api.countReads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unexpected failures do not show internal details to staff', (
    tester,
  ) async {
    final api = _DelayedApi();
    await tester.pumpWidget(
      _host(api, const WarehouseInboundExpectationsView()),
    );
    await tester.pump();
    api.requests.single.completeError(StateError('internal-table-diagnostic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('internal-table-diagnostic'), findsNothing);
    expect(find.text('出错了，请稍后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

const _emptyPage = <String, dynamic>{
  'items': <dynamic>[],
  'page': 1,
  'size': 20,
  'total': 0,
};

Widget _host(_DelayedApi api, Widget child) => ProviderScope(
  overrides: [
    apiClientProvider.overrideWithValue(api),
    sharedPreferencesProvider.overrideWithValue(_preferences),
    sessionProvider.overrideWith(_Session.new),
    currentPermissionsProvider.overrideWithValue(const {
      Perm.warehouseInboundView,
    }),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _DelayedApi extends ApiClient {
  _DelayedApi() : super(Dio());
  final requests = <Completer<Map<String, dynamic>>>[];
  final types = <String?>[];
  var countReads = 0;

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    if (path == '/warehouse/inbound/expectations') {
      final pending = Completer<Map<String, dynamic>>();
      requests.add(pending);
      types.add(query?['orderType'] as String?);
      return pending.future;
    }
    countReads++;
    return Future.value(const <String, dynamic>{});
  }
}
