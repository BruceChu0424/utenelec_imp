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
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/device_audit_interceptor.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/auth_token_issuer.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/inbound_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_batch_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_pre_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_material_return_batch_receive_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'inbound_arrival_test_support.dart';
import 'outbound_weight_fakes.dart';

const _base = 'https://quality-request.invalid/api';
final _issuer = AuthBackendRealmPolicy().issuerFor(_base);

enum _Action {
  arrival,
  preStock,
  quality,
  batch,
  sales,
  salesBatch,
  materialReturn,
}

const _allPermissions = {
  Perm.warehouseInboundView,
  Perm.warehouseInboundStockIn,
  Perm.warehouseIqcStockInView,
  Perm.warehouseIqcStockInConfirm,
  Perm.warehouseIqcStockInBeforeInspection,
  Perm.warehouseSalesOutboundView,
  Perm.warehouseSalesOutboundExecute,
  Perm.stockDocView,
  Perm.stockDocApprove,
};
final _permissions = StateProvider<Set<String>>((ref) => _allPermissions);

class _Session extends SessionNotifier {
  int intent = 0;
  @override
  int get requestIntentEpoch => intent;
  @override
  SessionState build() => const SessionState(
    user: AppUser(id: 'A', code: 'A', name: '仓管', employeeId: 'employee'),
  );
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
  Completer<void>? captureGate;
  int gatedReads = 0;
  @override
  Future<AuthTokenSnapshot> getAuthTokenSnapshot() async {
    if (captureGate case final gate?) {
      gatedReads++;
      await gate.future;
    }
    return auth;
  }

  @override
  Future<ImpersonationRecord?> getImpersonationRecord() async => null;
}

class _Audit implements DeviceAuditStore {
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<DeviceAuditProfile> profile() async {
    if (gate case final waiting?) {
      if (!entered.isCompleted) entered.complete();
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
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'main', name: '主仓', isAccountable: false),
    WarehouseDictEntry(
      id: 'leaf',
      parentId: 'main',
      name: '原料仓',
      selectableForNew: true,
    ),
  ];
}

Map<String, dynamic> _quality(_Action action) => {
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt',
  'billNo': 'PR-1',
  'workStatus': action == _Action.preStock
      ? 'WAITING_INSPECTION'
      : 'ALL_PASSED',
  'warehouseId': 'leaf',
  'warehouseName': '原料仓',
  'qualityStatus': action == _Action.preStock ? 'IN_PROGRESS' : 'RESOLVED',
  'goodsLineCount': 1,
  'pendingSliceCount': action == _Action.preStock ? 0 : 1,
  'completed': false,
  'allowedActions': [action == _Action.preStock ? 'PRE_STOCK_IN' : 'CONFIRM'],
  'lines': [
    {
      'inspectionItemId': 'inspection',
      'goodsId': 'goods',
      'goodsCode': 'G1',
      'goodsName': '实物件',
      'unitId': 'unit',
      'unitName': '件',
      'warehouseId': 'leaf',
      'warehouseName': '原料仓',
      'placeHint': 'A-01',
      'lineStatus': action == _Action.preStock ? 'PENDING' : 'RESOLVED',
      'receivedBaseQty': 5,
      'passedBaseQty': action == _Action.preStock ? 0 : 5,
      'failedBaseQty': 0,
      'warehouseStockedBaseQty': 0,
      'pendingStockBaseQty': action == _Action.preStock ? 0 : 5,
    },
  ],
  'items': [
    if (action != _Action.preStock)
      {
        'passEventId': 'pass',
        'inspectionItemId': 'inspection',
        'goodsId': 'goods',
        'goodsCode': 'G1',
        'goodsName': '实物件',
        'unitId': 'unit',
        'unitName': '件',
        'warehouseId': 'leaf',
        'warehouseName': '原料仓',
        'receivedBaseQty': 5,
        'qualityPassedBaseQty': 5,
        'warehouseStockedBaseQty': 0,
        'releasedBaseQty': 5,
        'stockedForReleaseBaseQty': 0,
        'remainingBaseQty': 5,
        'placeHint': 'A-01',
      },
  ],
};

Map<String, dynamic> _sales() => {
  'id': 'shipment',
  'billNo': 'SH-1',
  'billDate': '2026-10-22',
  'status': 0,
  'financeAudit': 1,
  'warehouseWorkStatus': 'PENDING_PICK',
  'allowedWarehouseTargets': ['SHIPPED'],
  'warehouseId': 'leaf',
  'warehouseName': '原料仓',
  'lines': [
    {
      'id': 'line',
      'goodsId': 'goods',
      'goodsCode': 'G1',
      'goodsName': '实物件',
      'quantity': '5',
      'unitId': 'unit',
      'unitName': '件',
      'warehouseId': 'leaf',
      'warehouseName': '原料仓',
      'stockPlace': 'A-01',
    },
  ],
};

class _Wire implements HttpClientAdapter {
  _Wire(this.action);
  final _Action action;
  final mutations = <RequestOptions>[];
  final reads = <RequestOptions>[];
  String rejection = 'CONFLICT';
  int rejectionStatus = 409;
  bool loseFirst = false;
  bool succeed = false;
  bool completed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = request.path;
    if (request.method == 'GET') reads.add(request);
    final command =
        request.method != 'GET' &&
        (path == arrivalBatchPath ||
            path.endsWith('/pre-stock-in') ||
            path.endsWith('/confirm') ||
            path.endsWith('/batch-confirm') ||
            path.endsWith('/warehouse-work'));
    Object value = <String, dynamic>{};
    var status = 200;
    if (command) {
      mutations.add(request);
      if (loseFirst && mutations.length == 1) {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.connectionTimeout,
        );
      }
      if (succeed) {
        completed = true;
        value = {
          'batchId': 'batch',
          'replayed': true,
          'confirmedCount': 1,
          'requestedLineCount': 1,
          'stockedLineCount': 1,
          'replayedLineCount': 1,
          'confirmedReceipts': 1,
          'confirmedItemCount': 1,
          'results': [
            {
              'receiptType': 'PURCHASE',
              'receiptId': 'receipt',
              'batchId': 'batch',
              'replayed': true,
              'confirmedCount': 1,
            },
          ],
        };
      } else {
        status = rejectionStatus;
        value = {
          'code': rejection,
          'message': rejection == 'ARRIVAL_SOURCE_AMBIGUOUS'
              ? '请明确选择到货来源'
              : '测试固定拒绝，不写业务数据',
        };
      }
    } else if (path == arrivalExpectationsByIdsPath) {
      value = [
        expectationJsonOf(
          const ProcurementReceiptPrefill(
            expectationId: 'expectation',
            orderType: ProcurementInboundOrderType.purchase,
            orderBillNo: 'PO-1',
            supplierId: 'supplier',
            warehouseId: 'leaf',
            purchaserId: 'employee',
            suggestedWarehouseId: 'leaf',
            suggestedWarehouseName: '原料仓',
            items: [
              ProcurementReceiptPrefillItem(
                orderItemId: 'order-line',
                goodsId: 'goods',
                goodsCode: 'G1',
                goodsName: '实物件',
                unitId: 'unit',
                unitName: '件',
                unitRate: 1,
                approvedRemainingQty: 5,
              ),
            ],
          ),
        ),
      ];
    } else if (path.startsWith('/warehouse/quality-results/')) {
      value = _quality(action);
      if (completed) {
        value = {
          ..._quality(action),
          'completed': action != _Action.preStock,
          'workStatus': action == _Action.preStock
              ? 'WAITING_INSPECTION'
              : 'COMPLETED',
          'allowedActions': <String>[],
          'items': <Object>[],
          'lines': [
            {
              ...((_quality(action)['lines'] as List).single
                  as Map<String, dynamic>),
              if (action == _Action.preStock)
                'preStocked': {
                  'warehouseId': 'leaf',
                  'warehouseName': '原料仓',
                  'place': 'A-01',
                },
            },
          ],
        };
      }
    } else if (path == '/warehouse/sales-outbound/shipment') {
      value = _sales();
    } else if (path == '/stock/docs/return') {
      value = {
        'id': 'return',
        'docType': 'WDRAW',
        'billNo': 'RT-1',
        'status': 0,
        'warehouseId': 'leaf',
        'materialReturnMainWarehouseId': 'main',
        'productionMaterialReturn': true,
        'items': [
          {'id': 'return-line', 'goodsId': 'goods', 'qty': 5, 'unitId': 'unit'},
        ],
      };
    } else if (path.contains('warehouses')) {
      value = [
        {'id': 'leaf', 'name': '原料仓', 'status': '使用', 'selectableForNew': true},
      ];
    } else if (path == '/warehouse/place-suggestions') {
      value = {
        'items': [
          {
            'goodsId': 'goods',
            'warehouseId': 'leaf',
            'place': 'A-01',
            'source': 'GOODS_MASTER',
          },
        ],
      };
    } else if (path.endsWith('/employee')) {
      value = {'id': 'employee', 'name': '仓管', 'code': 'E1'};
    }
    return ResponseBody.fromString(
      jsonEncode(value),
      status,
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
  tester.view.physicalSize = const Size(1800, 1400);
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
    _Action.arrival => const InboundArrivalRegistrationPage(
      expectationIds: ['expectation'],
      canRegister: true,
      route: InboundRoute.inspectFirst,
    ),
    _Action.preStock => const WarehouseQualityPreStockInPage(
      receiptType: 'PURCHASE',
      receiptId: 'receipt',
    ),
    _Action.quality => const WarehouseQualityResultDetailPage(
      receiptType: 'PURCHASE',
      receiptId: 'receipt',
    ),
    _Action.batch => const WarehouseQualityBatchStockInPage(
      receipts: [(receiptType: 'PURCHASE', receiptId: 'receipt')],
    ),
    _Action.sales => const WarehouseSalesOutboundDetailPage(id: 'shipment'),
    _Action.salesBatch => const WarehouseSalesOutboundBatchPage(
      shipmentIds: ['shipment'],
      selectedItemIds: ['line'],
      action: WarehouseSalesOutboundAction.confirmShipment,
    ),
    _Action.materialReturn => const WarehouseMaterialReturnBatchReceivePage(
      documentIds: ['return'],
      selectedItemIds: ['return-line'],
    ),
  };
  final router = GoRouter(
    initialLocation: '/operation',
    routes: [GoRoute(path: '/operation', builder: (_, _) => page())],
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
  expect(tester.takeException(), isNull);
  return (
    container: container,
    session: container.read(sessionProvider.notifier) as _Session,
    credentials: credentials,
    audit: audit,
    wire: wire,
  );
}

Finder _entry(_Action action) => find.byKey(
  Key(switch (action) {
    _Action.arrival => 'inbound-route-submit-inspectFirst',
    _Action.preStock => 'warehouse-quality-pre-stock-confirm',
    _Action.quality => 'warehouse-quality-detail-confirm',
    _Action.batch => 'warehouse-quality-batch-confirm',
    _Action.sales => 'warehouse-sales-outbound-action-SHIPPED',
    _Action.salesBatch => 'warehouse-sales-outbound-batch-submit',
    _Action.materialReturn => 'material-return-batch-confirm',
  }),
);

Future<void> _confirm(WidgetTester tester, _Action action) async {
  final label = switch (action) {
    _Action.arrival => '确认登记送检',
    _Action.quality => '确认入库',
    _Action.sales || _Action.salesBatch => '确认',
    _ => null,
  };
  if (label != null) {
    final dialog = find.byType(AlertDialog);
    final confirm = find.descendant(
      of: dialog,
      matching: find.widgetWithText(UtenButton, label),
    );
    await tester.tap(confirm);
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _replace(_Session session, _Credentials credentials) {
  session.intent++;
  credentials.auth = AuthTokenSnapshot(
    accessToken: 'replacement-B',
    refreshToken: null,
    generation: 2,
    intentGeneration: 2,
    sessionLineage: 'replacement-B-login',
    issuer: _issuer,
  );
}

Finder _retry(_Action action) {
  final label = switch (action) {
    _Action.preStock => '核对原上架提交',
    _Action.quality => '核对原入库提交',
    _Action.batch => '核对原批量入库提交',
    _Action.sales || _Action.salesBatch => '核对出库结果',
    _Action.materialReturn => '原样核对待确认收料',
    _ => '',
  };
  return find
      .ancestor(of: find.text(label), matching: find.byType(UtenButton))
      .last
      .hitTestable();
}

void main() {
  for (final action in [_Action.preStock, _Action.quality, _Action.batch]) {
    for (final rejection in [400, 403, 409]) {
      testWidgets(
        '${action.name} unknown replay rejection $rejection preserves original command until successful proof',
        (tester) async {
          final env = await _open(tester, action);
          env.wire.loseFirst = true;
          await tester.tap(_entry(action));
          await tester.pumpAndSettle();
          await _confirm(tester, action);
          await tester.pumpAndSettle();
          if (action == _Action.batch) {
            await tester.tap(find.text('知道了'));
            await tester.pumpAndSettle();
          }
          expect(env.wire.mutations, hasLength(1));
          final original = jsonEncode(env.wire.mutations.single.data);
          env.wire.rejectionStatus = rejection;
          env.wire.rejection = rejection == 403
              ? 'FORBIDDEN'
              : rejection == 400
              ? 'VALIDATION_ERROR'
              : 'CONFLICT';
          await tester.tap(_retry(action));
          await tester.pumpAndSettle();
          if (action == _Action.batch) {
            await tester.tap(find.text('知道了'));
            await tester.pumpAndSettle();
          }
          expect(env.wire.mutations, hasLength(2));
          expect(jsonEncode(env.wire.mutations.last.data), original);
          expect(
            env.container.read(formDraftsProvider).single.hasUnknownSubmission,
            isTrue,
            reason: '后次拒绝不是原次未提交证明',
          );
          env.wire.succeed = true;
          await tester.tap(_retry(action));
          await tester.pumpAndSettle();
          expect(env.wire.mutations, hasLength(3));
          expect(jsonEncode(env.wire.mutations.last.data), original);
          expect(
            env.container
                .read(formDraftsProvider)
                .any((draft) => draft.hasUnknownSubmission),
            isFalse,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'quality batch conflict dialog does not reload old source with new identity',
    (tester) async {
      final env = await _open(tester, _Action.batch);
      await tester.tap(_entry(_Action.batch));
      await tester.pumpAndSettle();
      expect(find.text('批量入库失败'), findsOneWidget);
      final reads = env.wire.reads.length;
      _replace(env.session, env.credentials);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(env.wire.reads, hasLength(reads));
      expect(env.wire.mutations, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  for (final action in _Action.values) {
    testWidgets(
      '${action.name} permission withdrawal in audit queue blocks write and restored permission cannot revive editor',
      (tester) async {
        final env = await _open(tester, action);
        env.audit.gate = Completer<void>();
        await tester.tap(_entry(action));
        await tester.pump(const Duration(milliseconds: 200));
        await _confirm(tester, action);
        for (
          var frame = 0;
          frame < 40 && !env.audit.entered.isCompleted;
          frame++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(env.audit.entered.isCompleted, isTrue);
        final writePermission = switch (action) {
          _Action.arrival => Perm.warehouseInboundStockIn,
          _Action.preStock => Perm.warehouseIqcStockInBeforeInspection,
          _Action.quality || _Action.batch => Perm.warehouseIqcStockInConfirm,
          _Action.sales ||
          _Action.salesBatch => Perm.warehouseSalesOutboundExecute,
          _Action.materialReturn => Perm.stockDocApprove,
        };
        env.container.read(_permissions.notifier).state = {..._allPermissions}
          ..remove(writePermission);
        await tester.pump();
        env.audit.gate!.complete();
        env.audit.gate = null;
        await tester.pumpAndSettle();
        expect(env.wire.mutations, isEmpty);
        env.container.read(_permissions.notifier).state = _allPermissions;
        await tester.pumpAndSettle();
        expect(_entry(action), findsNothing, reason: '恢复授权不能复活捕获旧权限的编辑器');
        expect(env.wire.mutations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final action in _Action.values) {
    for (final change in [false, true]) {
      testWidgets(
        '${action.name} original unknown recovery retains body across real auth queue change=$change',
        (tester) async {
          final env = await _open(tester, action);
          env.wire.loseFirst = true;
          await tester.tap(_entry(action));
          await tester.pumpAndSettle();
          await _confirm(tester, action);
          await tester.pumpAndSettle();
          if (action == _Action.batch) {
            await tester.tap(find.text('知道了'));
            await tester.pumpAndSettle();
          }
          expect(env.wire.mutations, hasLength(1));
          final originalBody = jsonEncode(env.wire.mutations.single.data);
          final readCount = env.wire.reads.length;
          env.audit.gate = Completer<void>();
          final Finder retry;
          if (action == _Action.arrival) {
            retry = _entry(action);
          } else {
            final label = switch (action) {
              _Action.preStock => '核对原上架提交',
              _Action.quality => '核对原入库提交',
              _Action.batch => '核对原批量入库提交',
              _Action.sales || _Action.salesBatch => '核对出库结果',
              _Action.materialReturn => '原样核对待确认收料',
              _ => '',
            };
            retry = find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(UtenButton),
                )
                .last;
          }
          await tester.tap(retry.hitTestable());
          await tester.pump(const Duration(milliseconds: 200));
          if (action == _Action.arrival) await _confirm(tester, action);
          for (
            var frame = 0;
            frame < 40 && !env.audit.entered.isCompleted;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(env.audit.entered.isCompleted, isTrue);
          if (change) _replace(env.session, env.credentials);
          env.audit.gate!.complete();
          env.audit.gate = null;
          await tester.pumpAndSettle();
          expect(
            env.wire.mutations,
            hasLength(
              !change && action != _Action.sales && action != _Action.salesBatch
                  ? 2
                  : 1,
            ),
          );
          if (change) {
            expect(env.wire.reads, hasLength(readCount));
          } else if (action != _Action.sales && action != _Action.salesBatch) {
            expect(jsonEncode(env.wire.mutations.last.data), originalBody);
            expect(
              env.wire.mutations.last.headers['Authorization'],
              'Bearer original-A',
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final rejection in [
    'SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED',
    'ARRIVAL_SOURCE_AMBIGUOUS',
  ]) {
    testWidgets(
      'arrival keeps original identity through secondary confirmation $rejection',
      (tester) async {
        final env = await _open(tester, _Action.arrival);
        env.wire.rejection = rejection;
        await tester.tap(_entry(_Action.arrival));
        await tester.pumpAndSettle();
        await _confirm(tester, _Action.arrival);
        await tester.pumpAndSettle();
        expect(env.wire.mutations, hasLength(1));
        _replace(env.session, env.credentials);
        if (rejection == 'ARRIVAL_SOURCE_AMBIGUOUS') {
          await tester.tap(
            find.byKey(const Key('warehouse-arrival-source-ambiguity-normal')),
          );
        } else {
          await tester.tap(find.text('继续登记并通知委外'));
        }
        await tester.pumpAndSettle();
        expect(env.wire.mutations, hasLength(1), reason: '二次确认不得用新身份重发原登记');
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final action in _Action.values) {
    for (final change in [false, true]) {
      testWidgets(
        '${action.name} real DeviceAudit to Auth queue keeps original identity change=$change',
        (tester) async {
          final env = await _open(tester, action);
          env.audit.gate = Completer<void>();
          await tester.tap(_entry(action));
          await tester.pump(const Duration(milliseconds: 200));
          await _confirm(tester, action);
          for (
            var frame = 0;
            frame < 40 && !env.audit.entered.isCompleted;
            frame++
          ) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(
            env.audit.entered.isCompleted,
            isTrue,
            reason: '必须到达真实设备审计等待，不能靠前置夹具错误得到零写',
          );
          if (change) _replace(env.session, env.credentials);
          expect(
            env.container.read(authenticatedScopeProvider),
            const AuthenticatedScope(userId: 'A'),
          );
          env.audit.gate!.complete();
          env.audit.gate = null;
          await tester.pumpAndSettle();
          expect(env.wire.mutations, hasLength(change ? 0 : 1));
          if (!change) {
            expect(
              env.wire.mutations.single.headers['Authorization'],
              'Bearer original-A',
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      '${action.name} captures intent before late secure read and locks repeated entry',
      (tester) async {
        final env = await _open(tester, action);
        final gate = Completer<void>();
        env.credentials.captureGate = gate;
        await tester.tap(_entry(action));
        await tester.tap(_entry(action));
        await tester.pump(const Duration(milliseconds: 100));
        expect(env.credentials.gatedReads, 1);
        _replace(env.session, env.credentials);
        gate.complete();
        env.credentials.captureGate = null;
        await tester.pumpAndSettle();
        expect(env.wire.mutations, isEmpty);
        expect(
          env.container
              .read(formDraftsProvider)
              .any((draft) => draft.hasUnknownSubmission),
          isFalse,
          reason: '捕获身份未完成时没有派发命令，不得凭空冻结未知提交',
        );
        if (action != _Action.batch) {
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final action in [
    _Action.arrival,
    _Action.quality,
    _Action.sales,
    _Action.salesBatch,
  ]) {
    testWidgets(
      '${action.name} intent change during confirmation cannot use new credentials',
      (tester) async {
        final env = await _open(tester, action);
        await tester.tap(_entry(action));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        _replace(env.session, env.credentials);
        await _confirm(tester, action);
        await tester.pumpAndSettle();
        expect(env.wire.mutations, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
