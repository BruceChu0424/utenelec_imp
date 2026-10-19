import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/pages/account_detail_page.dart';
import 'package:uten_imp/features/sales/pages/sales_scarcity_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../shared/drafts/memory_form_draft_storage.dart';

final _owner = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader'),
);

void main() {
  for (final kind in ['account', 'scarcity', 'outbound']) {
    for (final confirm in [false, true]) {
      testWidgets(
        '$kind ${confirm ? 'confirm' : 'cancel'} waits for controller overlay disposal',
        (tester) async {
          final api = _Api();
          await _mount(tester, api, kind);
          final openLabel = switch (kind) {
            'account' => '设置警戒线',
            'scarcity' => '让单',
            _ => '确认出库',
          };
          await tester.tap(find.text(openLabel));
          await tester.pumpAndSettle();
          final dialog = find.byType(AlertDialog).last;
          final fields = find.descendant(
            of: dialog,
            matching: find.byType(TextField),
          );
          final controllers = tester
              .widgetList<TextField>(fields)
              .map((field) => field.controller!)
              .toList();
          expect(controllers, isNotEmpty);
          if (confirm) {
            await tester.enterText(
              fields.last,
              kind == 'account' ? '20' : '核对后确认',
            );
          }
          final label = confirm
              ? (kind == 'account'
                    ? '保存'
                    : kind == 'scarcity'
                    ? '确认让单'
                    : '确认')
              : '取消';
          final route = ModalRoute.of(tester.element(dialog))!;
          var exited = false;
          route.completed.then((_) => exited = true);
          await tester.tap(
            find.descendant(of: dialog, matching: find.text(label)),
          );
          await tester.pump();
          expect(exited, isFalse);
          void listener() {}
          for (final controller in controllers) {
            expect(() => controller.addListener(listener), returnsNormally);
            controller.removeListener(listener);
          }
          if (confirm) {
            for (final controller in controllers) {
              controller.text = '999';
            }
          }
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          expect(exited, isTrue);
          for (final controller in controllers) {
            expect(() => controller.addListener(listener), throwsFlutterError);
          }
          expect(api.writes.length, confirm ? 1 : 0);
          if (confirm) {
            final body = api.bodies.single as Map;
            if (kind == 'account') {
              expect(body['balanceFloor'], '20.0000');
            } else {
              expect(body['reason'], '核对后确认');
              if (kind == 'scarcity') {
                expect(body['qty'], 10);
              }
            }
            api.command.complete(
              kind == 'account'
                  ? _account()
                  : kind == 'outbound'
                  ? _outbound(shipped: true)
                  : {
                      'id': 'order',
                      'status': 1,
                      'items': <Map<String, dynamic>>[],
                    },
            );
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('account warning old confirmation cannot survive reader A-B-A', (
    tester,
  ) async {
    final api = _Api();
    final container = await _mount(tester, api, 'account');
    await tester.tap(find.text('设置警戒线'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog).last;
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      '20',
    );
    container.read(_owner.notifier).state = const AuthenticatedScope(
      userId: 'other',
    );
    await tester.pump();
    container.read(_owner.notifier).state = const AuthenticatedScope(
      userId: 'reader',
    );
    await tester.pump();
    await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
    await tester.pumpAndSettle();
    expect(api.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  String kind,
) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
        isSuperAdminProvider.overrideWithValue(true),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.accountView,
          Perm.accountBalanceView,
          Perm.accountWarningManage,
          Perm.warehouseSalesOutboundView,
          Perm.warehouseSalesOutboundExecute,
        }),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: switch (kind) {
          'account' => const AccountDetailPage(accountId: 'dialog-account'),
          'scarcity' => const SalesScarcityPage(initialGoodsId: 'goods'),
          _ => const WarehouseSalesOutboundDetailPage(id: 'dialog-outbound'),
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

Map<String, dynamic> _account() => {
  'id': 'dialog-account',
  'code': 'ACC',
  'name': '账户',
  'status': '使用',
  'balanceCurrent': 100,
  'balanceFloor': 10,
};

Map<String, dynamic> _outbound({bool shipped = false}) => {
  'id': 'dialog-outbound',
  'billNo': 'SHIP',
  'warehouseId': 'warehouse',
  'warehouseWorkStatus': shipped ? 'SHIPPED' : 'PENDING_PICK',
  'allowedWarehouseTargets': shipped ? <String>[] : ['SHIPPED'],
  'lines': [
    {
      'id': 'line-1',
      'quantity': '1',
      'warehouseId': 'warehouse',
      'actualStockPlace': 'A1',
    },
  ],
};

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'reader', code: 'reader', name: 'Reader'),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://example.invalid/api')));
  final command = Completer<Map<String, dynamic>>();
  final writes = <String>[];
  final bodies = <Object?>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/auth/me') return {'session': <String, dynamic>{}};
    if (path.endsWith('/dialog-account')) return _account();
    if (path.endsWith('/dialog-outbound')) return _outbound();
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/reservations/scarce') {
      return [
        {
          'reservationId': 'r1',
          'orderItemId': 'oi1',
          'orderNo': 'ORDER',
          'reservedQty': 10,
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) {
    writes.add(path);
    bodies.add(body);
    return command.future;
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) {
    writes.add(path);
    bodies.add(body);
    return command.future;
  }

  @override
  Future<Map<String, dynamic>> patch(String path, {Object? body}) {
    writes.add(path);
    bodies.add(body);
    return command.future;
  }
}
