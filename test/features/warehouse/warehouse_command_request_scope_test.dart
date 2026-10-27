import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/device_audit_interceptor.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/features/warehouse/models/production_finished_inbound_task.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/production_draw_batch_issue_page.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_batch_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_edit_page.dart';
import 'package:uten_imp/features/warehouse/widgets/stock_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../helpers/document_scope_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'outbound_weight_fakes.dart';

const _base = 'https://warehouse-request.invalid/api';
final _issuer = AuthBackendRealmPolicy().issuerFor(_base);
const _arrival =
    '/warehouse/production-finished-in/arrival-registrations/batch';
final _permissions = StateProvider<Set<String>>(
  (ref) => {
    Perm.stockDocView,
    Perm.stockDocCreate,
    Perm.stockDocEdit,
    Perm.stockDocApprove,
    Perm.stockDocIssue,
    Perm.productionFinishedInBeforeInspection,
  },
);

enum _Action {
  draw,
  finished,
  arrival,
  preStock,
  reverseArrival,
  create,
  update,
}

class _Session extends SessionNotifier {
  int intent = 0;
  @override
  int get requestIntentEpoch => intent;
  @override
  SessionState build() => const SessionState();
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _Credentials extends SecureStorage {
  _Credentials() : super(const FlutterSecureStorage());
  AuthTokenSnapshot auth = AuthTokenSnapshot(
    accessToken: 'original-A',
    refreshToken: null,
    generation: 1,
    intentGeneration: 1,
    sessionLineage: 'original-A-login',
    issuer: _issuer,
  );
  ImpersonationRecord? impersonation;
  Completer<void>? captureGate;
  int gatedReads = 0;
  bool failCapture = false;
  @override
  Future<AuthTokenSnapshot> getAuthTokenSnapshot() async {
    if (failCapture) throw StateError('secure storage temporarily unavailable');
    final gate = captureGate;
    if (gate != null) {
      gatedReads++;
      await gate.future;
    }
    return auth;
  }

  @override
  Future<ImpersonationRecord?> getImpersonationRecord() async => impersonation;
}

class _Audit implements DeviceAuditStore {
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<DeviceAuditProfile> profile() async {
    final waiting = gate;
    if (waiting != null) {
      final signal = entered;
      if (signal != null && !signal.isCompleted) signal.complete();
      await waiting.future;
    }
    return const DeviceAuditProfile(
      installationId: '123e4567-e89b-42d3-a456-426614174001',
      platform: 'windows',
      appVersion: 'test',
      appBuild: 'test',
    );
  }

  @override
  Future<void> beginReceipt({
    required String clientEventId,
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  }) async {}
  @override
  Future<void> completeReceipt({
    required String clientEventId,
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  }) async {}
  @override
  Future<void> updateRetentionMonths(int months) async {}
  @override
  Future<LocalAuditReceipt?> findReceipt(String clientEventId) async => null;
}

class _Names extends MasterNameService {
  _Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '实物件';
  @override
  String unit(String? id) => '件';
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'leaf', name: '成品仓', selectableForNew: true),
  ];
}

Map<String, dynamic> _report({bool history = false}) => {
  'reportId': 'report',
  'reportNo': 'RB-1',
  'reportDate': '2026-10-22',
  'registered': history,
  'lots': [
    {
      'lotId': 'lot',
      'lineNo': 1,
      'goodsId': 'goods',
      'goodsCode': 'G1',
      'goodsName': '实物件',
      'unitId': 'unit',
      'unitName': '件',
      'reportedQty': 5,
      'demandQty': 5,
      'lastWarehouseId': 'leaf',
      'place': 'A-01',
      'members': [
        {'reportItemId': 'line', 'qty': 5, 'kind': 'DEMAND'},
      ],
    },
  ],
  if (history)
    'batches': [
      {
        'registrationId': 'registration',
        'warehouseId': 'leaf',
        'warehouseName': '成品仓',
        'itemCount': 1,
        'reversible': true,
      },
    ],
};

Map<String, dynamic> _document({bool draw = false}) => {
  'id': 'doc',
  'docType': draw ? 'DRAW' : 'OTHER_OUT',
  'billNo': 'DOC-1',
  'billDate': '2026-10-22',
  'status': draw ? 1 : 0,
  'warehouseId': 'leaf',
  'makerId': 'A',
  'canEdit': true,
  'items': [
    {
      'id': 'line',
      'goodsId': 'goods',
      'unitId': 'unit',
      'unitRate': 1,
      'qty': '5',
      'requestedQty': '5',
      'issuedQty': '0',
      'warehouseId': 'leaf',
    },
  ],
};

class _Wire implements HttpClientAdapter {
  _Wire(this.action);
  final _Action action;
  final requests = <RequestOptions>[];
  final mutations = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.path;
    final command =
        options.method != 'GET' &&
        (path == '/stock/docs/issue-batch' ||
            path == '/stock/docs/finished-in/confirm-batch' ||
            path == _arrival ||
            path.endsWith('/registration/reverse') ||
            path.contains('/registration') && path.endsWith('/reverse') ||
            path == '/stock/docs' ||
            path == '/stock/docs/doc');
    if (command) mutations.add(options);
    Object value = <String, dynamic>{};
    if (options.method == 'GET' && path == '/stock/docs/doc') {
      value = _document(draw: action == _Action.draw);
    } else if (options.method == 'GET' && path == '/stock/docs') {
      value = {
        'items': <Object>[],
        'page': 1,
        'size': 1,
        'total': 0,
        'totalPages': 0,
      };
    } else if (options.method == 'GET' && path == _arrival) {
      value = [_report(history: action == _Action.reverseArrival)];
    } else if (path == '/warehouse/place-suggestions') {
      value = {
        'items': [
          {'goodsId': 'goods', 'place': 'A-01', 'source': 'GOODS_MASTER'},
        ],
      };
    } else if (path == '/stock/docs/issue-batch') {
      value = {
        'issuedCount': 1,
        'skippedCount': 0,
        'replayedCount': 0,
        'replayed': false,
        'issuedDocNos': ['DOC-1'],
      };
    } else if (path.contains('confirm-batch')) {
      value = {
        'confirmedCount': 1,
        'items': [
          {'documentId': 'doc'},
        ],
      };
    } else if (path == _arrival) {
      value = {
        'registeredCount': 1,
        'reports': [
          {'reportId': 'report', 'reportNo': 'RB-1'},
        ],
      };
    } else if (path.endsWith('/reverse')) {
      value = _report();
    } else if (path == '/stock/docs' || path == '/stock/docs/doc') {
      value = _document();
    }
    return ResponseBody.fromString(
      jsonEncode(value),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<
  ({
    ProviderContainer container,
    _Session session,
    _Credentials credentials,
    _Audit audit,
    _Wire wire,
  })
>
_open(WidgetTester tester, _Action action) async {
  tester.view.physicalSize = const Size(1800, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final credentials = _Credentials();
  final audit = _Audit();
  final wire = _Wire(action);
  final dio = Dio(BaseOptions(baseUrl: _base))..httpClientAdapter = wire;
  dio.interceptors.add(DeviceAuditInterceptor(audit));
  dio.interceptors.add(AuthInterceptor(storage: credentials, baseUrl: _base));
  final api = ApiClient(dio);
  Widget page() => switch (action) {
    _Action.draw => const ProductionDrawBatchIssuePage(
      documentIds: ['doc'],
      selectedItemIds: ['line'],
    ),
    _Action.finished => ProductionFinishedBatchStockInPage(
      targets: [
        ProductionFinishedInboundTask.fromJson({
          'taskId': 'doc',
          'taskStage': 'FINAL_COUNT',
          'documentId': 'doc',
          'documentNo': 'IN-1',
          'documentDate': '2026-10-22',
          'createdAt': '2026-10-22',
          'lineCount': 1,
          'pendingQty': 5,
          'residualTask': false,
        }),
      ],
      selectedItemIds: const ['line'],
      selectedItemDocuments: const {'line': 'doc'},
    ),
    _Action.create || _Action.update => StockDocEditPage(
      docType: StockDocType.otherOut,
      id: action == _Action.update ? 'doc' : null,
    ),
    _ => ProductionFinishedArrivalRegistrationPage(
      reportIds: const ['report'],
      canRegister: true,
      route: action == _Action.preStock
          ? InboundRoute.stockInFirst
          : InboundRoute.inspectFirst,
    ),
  };
  final router = GoRouter(
    initialLocation: '/operation',
    routes: [
      GoRoute(path: '/operation', builder: (_, _) => page()),
      GoRoute(
        path: '/warehouse/:type/:id',
        builder: (_, _) => const Text('已保存详情'),
      ),
      GoRoute(
        path: RouteName.warehouseDrawTasks,
        builder: (_, _) => const Text('领料任务'),
      ),
      GoRoute(
        path: RouteName.warehouseProductionFinishedInboundTasks,
        builder: (_, _) => const Text('点收任务'),
      ),
    ],
  );
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue(_base),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'A'),
      ),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
      masterNameServiceProvider.overrideWithValue(_Names(api)),
      documentScopeOverride(writeAll: true),
      fixedBadgeSummaryOverride(),
      fakeWeightRepositoryOverride(),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (action == _Action.create) {
    final grid = tester.widget<UtenEditableGrid<StockGridRow>>(
      find.byType(UtenEditableGrid<StockGridRow>),
    );
    grid.controller.rows.single
      ..goods = const GoodsOption(id: 'goods', name: '实物件')
      ..unitId = 'unit'
      ..warehouseId = 'leaf'
      ..qty.text = '5';
    await tester.pumpAndSettle();
  }
  expect(
    _entry(action),
    findsOneWidget,
    reason:
        '${wire.requests.map((request) => request.path).toList()} / ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}',
  );
  await tester.ensureVisible(_entry(action));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return (
    container: container,
    session: container.read(sessionProvider.notifier) as _Session,
    credentials: credentials,
    audit: audit,
    wire: wire,
  );
}

Finder _entry(_Action action) {
  final key = switch (action) {
    _Action.draw => const Key('warehouse-draw-batch-confirm'),
    _Action.finished => const Key('production-finished-batch-confirm'),
    _Action.reverseArrival => const ValueKey(
      'production-finished-arrival-reverse-registration',
    ),
    _Action.preStock => InboundRoute.stockInFirst.submitKey,
    _Action.arrival => InboundRoute.inspectFirst.submitKey,
    _ => null,
  };
  return key == null ? find.text('保存').last : find.byKey(key);
}

Future<void> _begin(WidgetTester tester, _Action action) async {
  await tester.tap(_entry(action));
  await tester.pump(const Duration(milliseconds: 300));
  if (action == _Action.reverseArrival) {
    await tester.enterText(
      find.byKey(const Key('production-finished-arrival-reverse-reason')),
      '仓库选错',
    );
    await tester.pump();
  }
}

Future<void> _confirm(WidgetTester tester, _Action action) async {
  final label = switch (action) {
    _Action.finished => '确认批量入库',
    _Action.arrival => '确认登记送检',
    _Action.preStock => '确认登记并先入库',
    _Action.reverseArrival => '确认撤回登记',
    _ => null,
  };
  if (label != null) await tester.tap(find.text(label));
  await tester.pump(const Duration(milliseconds: 300));
}

void _replaceIdentity(
  String change,
  _Session session,
  _Credentials credentials,
) {
  if (change == 'unchanged') return;
  session.intent++;
  if (change == 'same-login') {
    credentials.auth = AuthTokenSnapshot(
      accessToken: 'replacement-A',
      refreshToken: null,
      generation: 2,
      intentGeneration: 2,
      sessionLineage: 'replacement-A-login',
      issuer: _issuer,
    );
  } else {
    credentials.impersonation = ImpersonationRecord(
      accessToken: 'target-token',
      windowExpiresAtEpochMs: DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      lineage: 'new-target-lineage',
    );
  }
}

void main() {
  for (final action in _Action.values) {
    testWidgets(
      '${action.name} releases its input lock after capture failure and retains the draft',
      (tester) async {
        final env = await _open(tester, action);
        await tester.pump(const Duration(seconds: 1));
        final before = env.container
            .read(formDraftsProvider)
            .map((draft) => jsonEncode(draft.data))
            .toList();
        env.credentials.failCapture = true;
        await tester.tap(_entry(action));
        await tester.pumpAndSettle();
        expect(env.wire.mutations, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          env.container
              .read(formDraftsProvider)
              .map((draft) => jsonEncode(draft.data)),
          before,
        );
        env.credentials.failCapture = false;
        await _begin(tester, action);
        await _confirm(tester, action);
        await tester.pumpAndSettle();
        expect(env.wire.mutations, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${action.name} locks synchronously while capturing identity and ignores a second click',
      (tester) async {
        final env = await _open(tester, action);
        final gate = Completer<void>();
        if (action == _Action.create || action == _Action.update) {
          await tester.showKeyboard(
            find.byKey(const ValueKey('stock-grid-qty')).first,
          );
          expect(tester.testTextInput.hasAnyClients, isTrue);
        }
        env.credentials.captureGate = gate;
        await tester.tap(_entry(action));
        await tester.tap(_entry(action));
        await tester.pump(const Duration(milliseconds: 200));
        expect(env.credentials.gatedReads, 1, reason: '第二次点击不得再捕获身份或打开第二个确认框');
        expect(env.wire.mutations, isEmpty);
        if (action == _Action.create || action == _Action.update) {
          expect(
            tester.testTextInput.hasAnyClients,
            isFalse,
            reason: '捕获等待期间连已聚焦的数量输入也冻结，不把后打的数量并入原保存',
          );
        }
        gate.complete();
        env.credentials.captureGate = null;
        await tester.pumpAndSettle();
        if (action == _Action.reverseArrival) {
          await tester.enterText(
            find.byKey(const Key('production-finished-arrival-reverse-reason')),
            '仓库选错',
          );
          await tester.pump();
        }
        await _confirm(tester, action);
        await tester.pumpAndSettle();
        expect(env.wire.mutations, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
    for (final change in [
      'same-login',
      'impersonation',
      'permission',
      'unchanged',
    ]) {
      testWidgets(
        '${action.name} binds one identity across real device-audit await: $change',
        (tester) async {
          final env = await _open(tester, action);
          env.audit.gate = Completer<void>();
          env.audit.entered = Completer<void>();
          await _begin(tester, action);
          await _confirm(tester, action);
          for (
            var frame = 0;
            frame < 40 && !env.audit.entered!.isCompleted;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(
            env.audit.entered!.isCompleted,
            isTrue,
            reason: '真实生产仓储须进入设备审计等待',
          );
          expect(env.wire.mutations, isEmpty);
          if (change == 'permission') {
            env.container.read(_permissions.notifier).state = {
              Perm.stockDocView,
            };
            await tester.pump();
          } else {
            _replaceIdentity(change, env.session, env.credentials);
          }
          expect(
            env.container.read(authenticatedScopeProvider),
            const AuthenticatedScope(userId: 'A'),
          );
          env.audit.gate!.complete();
          env.audit.gate = null;
          await tester.pumpAndSettle();
          expect(env.wire.mutations, hasLength(change == 'unchanged' ? 1 : 0));
          if (change == 'unchanged') {
            expect(
              env.wire.mutations.single.headers['Authorization'],
              'Bearer original-A',
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final action in [
    _Action.finished,
    _Action.arrival,
    _Action.preStock,
    _Action.reverseArrival,
  ]) {
    testWidgets(
      '${action.name} confirmation cannot acquire a later same-account login',
      (tester) async {
        final env = await _open(tester, action);
        await _begin(tester, action);
        _replaceIdentity('same-login', env.session, env.credentials);
        await _confirm(tester, action);
        await tester.pumpAndSettle();
        expect(env.wire.mutations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
