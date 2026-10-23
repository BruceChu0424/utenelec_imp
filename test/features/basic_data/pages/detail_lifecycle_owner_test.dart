import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/pages/goods_detail_page.dart';
import 'package:uten_imp/features/basic_data/pages/party_detail_page.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'A'),
);
final _grants = StateProvider<Set<String>>(
  (_) => {
    Perm.goodsView,
    Perm.goodsStatus,
    Perm.goodsDelete,
    Perm.clientView,
    Perm.clientEdit,
    Perm.clientStatus,
    Perm.clientDelete,
    Perm.supplierView,
    Perm.supplierStatus,
    Perm.supplierDelete,
  },
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Wire {
  _Wire(this.kind);
  final String kind;
  String get domain => kind == 'goods' ? 'goods' : '${kind}s';
  String name = '原私有资料';
  String status = '使用';
  int details = 0;
  final writes = <({String method, String path, Map<String, dynamic>? body})>[];
  Completer<void>? detailGate;
  int detailGateAt = 0;
  Completer<void>? optionsGate;
  Completer<void>? writeGate;
  bool failWrite = false;
  late final api = () {
    final dio = Dio(BaseOptions(baseUrl: 'https://detail.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          Object body;
          if (request.method == 'PUT' ||
              request.method == 'PATCH' ||
              request.method == 'DELETE') {
            writes.add((
              method: request.method,
              path: request.path,
              body: request.data is Map
                  ? Map<String, dynamic>.from(request.data as Map)
                  : null,
            ));
            await writeGate?.future;
            if (failWrite) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: request,
                    statusCode: 409,
                    data: {
                      'code': 'CONFLICT',
                      'message': 'PRIVATE-OLD-WRITE-ERROR',
                    },
                  ),
                ),
              );
              return;
            }
            if (request.path.endsWith('/status')) {
              status = (request.data as Map)['status'] as String;
            }
            body = <String, dynamic>{};
          } else if (request.path == '/master/$domain/item-1') {
            final snapshot = {
              'id': 'item-1',
              'code': 'QA001',
              'name': name,
              'status': status,
              'version': 7,
              'writable': true,
              'sourceType': '采购',
              'defaultShipmentPolicy': 'ALLOW_PARTIAL',
            };
            final index = details++;
            if (index == detailGateAt) await detailGate?.future;
            body = snapshot;
          } else if (request.path == '/master/reference-methods/settlement') {
            await optionsGate?.future;
            body = [
              {'id': 'settlement-1', 'code': 'JS001', 'name': '月结30'},
            ];
          } else if (request.path == '/master/currencies/dict') {
            body = [
              {'id': 'cny', 'name': '人民币', 'code': 'CNY'},
            ];
          } else if (request.path.endsWith('/credit-score')) {
            body = {'score': 95};
          } else {
            body = <Map<String, dynamic>>[];
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              data: body,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    return ApiClient(dio);
  }();
}

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  _Wire wire, {
  bool pending = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final fallback = wire.kind == 'goods'
      ? RouteName.basicinfoGoods
      : wire.kind == 'client'
      ? RouteName.basicinfoClient
      : RouteName.basicinfoSupplier;
  final router = GoRouter(
    initialLocation: '/record',
    routes: [
      GoRoute(
        path: '/record',
        builder: (_, _) => wire.kind == 'goods'
            ? const GoodsDetailPage(goodsId: 'item-1')
            : PartyDetailPage(partyType: wire.kind, id: 'item-1'),
      ),
      GoRoute(
        path: '/other',
        builder: (_, _) => const Scaffold(body: Text('另一页')),
      ),
      GoRoute(
        path: fallback,
        builder: (_, _) => const Scaffold(body: Text('返回资料列表')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(wire.api),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
        isSuperAdminProvider.overrideWithValue(false),
        goodsRepositoryProvider.overrideWithValue(DioGoodsRepository(wire.api)),
        clientRepositoryProvider.overrideWithValue(
          DioClientRepository(wire.api),
        ),
        supplierRepositoryProvider.overrideWithValue(
          DioSupplierRepository(wire.api),
        ),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  if (pending) {
    for (var frame = 0; frame < 8; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  } else {
    await tester.pumpAndSettle();
  }
  final page = find.byType(
    wire.kind == 'goods' ? GoodsDetailPage : PartyDetailPage,
  );
  return (
    container: ProviderScope.containerOf(tester.element(page)),
    router: router,
  );
}

Finder _action(_Wire wire, String action) =>
    action == 'delete' && wire.kind == 'goods'
    ? find.widgetWithText(UtenButton, '删除')
    : find.byKey(
        ValueKey(
          '${wire.kind == 'goods' ? 'goods' : 'party'}-detail-${action == 'status' ? 'toggle-status' : 'delete'}',
        ),
      );
Future<void> _openConfirm(
  WidgetTester tester,
  _Wire wire,
  String action,
) async {
  await tester.tap(_action(wire, action));
  await tester.pumpAndSettle();
  expect(find.byType(UtenAlertDialog), findsOneWidget);
  expect(find.byType(UtenBusyOverlay), findsNothing);
}

Future<void> _confirm(WidgetTester tester, String action) async {
  await tester.tap(
    find.widgetWithText(FilledButton, action == 'delete' ? '删除' : '确认'),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'goods pending detail refresh blocks lifecycle callbacks until the current snapshot arrives',
    (tester) async {
      final wire = _Wire('goods');
      await _pump(tester, wire);
      final body = tester.widget<GoodsDetailBody>(find.byType(GoodsDetailBody));
      final oldStatus = body.onToggleStatus!;
      final oldDelete = body.onDelete!;
      final gate = Completer<void>();
      wire
        ..detailGateAt = 1
        ..detailGate = gate;
      body.onDataChanged!();
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await Future<void>.sync(oldStatus);
      await Future<void>.sync(oldDelete);
      await tester.pump();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(wire.writes, isEmpty);
      expect(
        tester.widget<GoodsDetailBody>(find.byType(GoodsDetailBody)).canStatus,
        isFalse,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(wire.details, 2);
      await _openConfirm(tester, wire, 'status');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(wire.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['goods', 'client', 'supplier']) {
    testWidgets(
      '$kind valid status command preserves target version and reloads',
      (tester) async {
        final wire = _Wire(kind);
        await _pump(tester, wire);
        await _openConfirm(tester, wire, 'status');
        await _confirm(tester, 'status');
        await tester.pumpAndSettle();
        expect(wire.writes.single.path, '/master/${wire.domain}/item-1/status');
        expect(wire.writes.single.body, {'status': '禁用', 'version': 7});
        expect(wire.details, 2);
        expect(find.text('启用'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    for (final action in ['status', 'delete']) {
      testWidgets(
        '$kind $action confirmation rejects identity A-B-A and captured old callbacks',
        (tester) async {
          final wire = _Wire(kind);
          final app = await _pump(tester, wire);
          await _openConfirm(tester, wire, action);
          final callback = tester
              .widget<FilledButton>(
                find.widgetWithText(
                  FilledButton,
                  action == 'delete' ? '删除' : '确认',
                ),
              )
              .onPressed!;
          app.container.read(_identity.notifier).state =
              const AuthenticatedScope(userId: 'B');
          await tester.pump();
          app.container.read(_identity.notifier).state =
              const AuthenticatedScope(userId: 'A');
          await tester.pumpAndSettle();
          callback();
          await tester.pumpAndSettle();
          expect(wire.writes, isEmpty);
          expect(find.byType(UtenAlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('$kind old detail response cannot repopulate after A-B-A', (
      tester,
    ) async {
      final gate = Completer<void>();
      final wire = _Wire(kind)..detailGate = gate;
      final app = await _pump(tester, wire, pending: true);
      wire.name = '当前资料';
      app.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'B',
      );
      await tester.pump();
      app.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'A',
      );
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('原私有资料'), findsNothing);
      expect(find.text('当前资料'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'client option loading is owned and a late old editor cannot open',
    (tester) async {
      final gate = Completer<void>();
      final wire = _Wire('client')..optionsGate = gate;
      final app = await _pump(tester, wire);
      await tester.tap(find.byKey(const Key('party-detail-edit')));
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      app.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'B',
      );
      await tester.pump();
      app.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'A',
      );
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(MasterEditForm), findsNothing);
      expect(find.byKey(const Key('party-detail-save')), findsNothing);
      expect(wire.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'client dirty draft and captured save are discarded on revoke/regrant',
    (tester) async {
      final wire = _Wire('client');
      final app = await _pump(tester, wire);
      await tester.tap(find.byKey(const Key('party-detail-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.controller?.text == '原私有资料',
        ),
        '旧草稿',
      );
      final save = tester
          .widget<UtenButton>(find.byKey(const Key('party-detail-save')))
          .onPressed!;
      app.container.read(_grants.notifier).state = {Perm.clientView};
      await tester.pumpAndSettle();
      app.container.read(_grants.notifier).state = {
        Perm.clientView,
        Perm.clientEdit,
      };
      await tester.pumpAndSettle();
      await Future<void>.sync(save);
      await tester.pumpAndSettle();
      expect(find.text('旧草稿'), findsNothing);
      expect(find.byType(MasterEditForm), findsNothing);
      expect(wire.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'client pending inline save drops old private errors and busy portal after route leave',
    (tester) async {
      final gate = Completer<void>();
      final wire = _Wire('client')
        ..writeGate = gate
        ..failWrite = true;
      final app = await _pump(tester, wire);
      await tester.tap(find.byKey(const Key('party-detail-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) => widget is TextField && widget.controller?.text == '原私有资料',
        ),
        '未提交新名称',
      );
      await tester.tap(find.byKey(const Key('party-detail-save')));
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(wire.writes, hasLength(1));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      unawaited(app.router.push<void>('/other'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('PRIVATE-OLD-WRITE-ERROR'), findsNothing);
      expect(wire.writes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read-only impersonation can read a client but cannot start an editor',
    (tester) async {
      final wire = _Wire('client');
      final app = await _pump(tester, wire);
      app.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'A',
        readOnly: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('原私有资料'), findsWidgets);
      await tester.tap(find.byKey(const Key('party-detail-edit')));
      await tester.pumpAndSettle();
      expect(find.byType(MasterEditForm), findsNothing);
      expect(wire.writes, isEmpty);
    },
  );
}
