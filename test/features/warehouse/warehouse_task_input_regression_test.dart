import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_batch_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_pre_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/task_form_drafts.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_form_drafts.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import 'outbound_weight_fakes.dart';

class _Storage implements FormDraftStorage {
  final records = <String, String>{};
  Completer<void>? submissionGate;
  bool submissionBlocked = false;
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    final decoded = value == null ? null : jsonDecode(value);
    if (submissionGate != null &&
        decoded is Map &&
        decoded['data'] is Map &&
        (decoded['data'] as Map)['pendingCommand'] is Map) {
      submissionBlocked = true;
      await submissionGate!.future;
    }
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _InputApi extends ApiClient {
  _InputApi() : super(Dio());
  final posts = <({String path, Map<String, dynamic> body})>[];
  final shipped = <String>{};
  bool timeout = true;
  double remaining = 10;
  String salesQuantity = '10.0000';
  bool salesAllowed = true;
  bool preStockReadback = false;
  Completer<void>? sourceGate;
  bool sourceStarted = false;
  bool includeRejection = false;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.startsWith('/warehouse/sales-outbound/')) {
      sourceStarted = true;
      await sourceGate?.future;
      final id = path.split('/').last;
      return {
        'id': id,
        'billNo': 'SHIP-$id',
        'billDate': '2026-10-11',
        'warehouseWorkStatus': shipped.contains(id)
            ? 'SHIPPED'
            : 'PENDING_PICK',
        'allowedWarehouseTargets': shipped.contains(id) || !salesAllowed
            ? <String>[]
            : ['SHIPPED'],
        'warehouseId': 'warehouse',
        'warehouseName': '成品仓',
        'warehouseWorkUpdatedAt': shipped.contains(id)
            ? '2026-10-11T11:00:00Z'
            : '2026-10-11T10:00:00Z',
        'lines': [
          {
            'id': 'line-$id',
            'goodsId': 'goods-$id',
            'goodsName': '货品$id',
            'lineNumber': 1,
            'quantity': salesQuantity,
            'unitName': '件',
            'warehouseId': 'warehouse',
            'suggestedWarehouseId': 'warehouse',
            'currentStockPlaceHint': '默认库位',
            'warehouseChoices': [
              {
                'warehouseId': 'warehouse',
                'canFulfill': true,
                'availableQty': '10.0000',
                'requiredQty': '10.0000',
              },
            ],
          },
        ],
      };
    }
    return {
      'receiptType': 'PURCHASE',
      'receiptId': 'receipt-a',
      'billNo': 'PR-a',
      'workStatus': remaining > 0 ? 'ALL_PASSED' : 'COMPLETED',
      'qualityStatus': 'RESOLVED',
      'completed': remaining == 0,
      'warehouseId': 'warehouse',
      'warehouseName': '原料仓',
      'allowedActions': remaining > 0 ? ['CONFIRM'] : <String>[],
      'goodsLineCount': 1,
      'passedLineCount': 1,
      'lines': [
        {
          'inspectionItemId': 'inspection-a',
          'goodsId': 'goods-a',
          'goodsName': '材料A',
          'receivedBaseQty': 10,
          'passedBaseQty': 10,
          'lineStatus': 'RESOLVED',
          if (preStockReadback)
            'preStocked': {'warehouseId': 'warehouse', 'place': '原上架库位'},
        },
      ],
      'items': remaining > 0
          ? [
              {
                'passEventId': 'pass-a',
                'inspectionItemId': 'inspection-a',
                'goodsId': 'goods-a',
                'goodsName': '材料A',
                'unitName': '件',
                'warehouseId': 'warehouse',
                'warehouseName': '原料仓',
                'receivedBaseQty': 10,
                'releasedBaseQty': 10,
                'remainingBaseQty': remaining,
                'placeHint': '默认库位',
              },
            ]
          : <Map<String, dynamic>>[],
      'rejections': [
        if (includeRejection)
          {
            'id': 'rejection-a',
            'inspectionItemId': 'inspection-failed',
            'goodsId': 'goods-a',
            'goodsName': '材料A',
            'failedQty': 2,
            'physicalStatus': 'PENDING_RETURN',
            'rowVersion': 7,
            'canRecordReturn': true,
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path: path, body: Map<String, dynamic>.from(body as Map)));
    if (path.endsWith('/record-return')) {
      return {
        'id': 'rejection-a',
        'version': 8,
        'allowedActions': <String>[],
        'physicalReturnStatus': 'RETURN_RECORDED',
      };
    }
    if (path.startsWith('/warehouse/sales-outbound/')) {
      final id = path.split('/')[3];
      shipped.add(id);
      if (id == 'b' && timeout) {
        timeout = false;
        throw NetworkTimeoutException();
      }
      return get('/warehouse/sales-outbound/$id');
    }
    if (timeout) {
      timeout = false;
      remaining = 0;
      throw NetworkTimeoutException();
    }
    return {
      'batchId': 'batch-a',
      'replayed': true,
      'confirmedCount': 1,
      'confirmedReceipts': 1,
      'confirmedItemCount': 1,
      'results': <Object>[],
    };
  }
}

Future<ProviderContainer> _container(
  _InputApi api, {
  _Storage? storage,
  Set<String>? permissions,
  bool superAdmin = false,
  bool readOnly = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      if (permissions != null) _permissions.overrideWith((_) => permissions),
      if (readOnly)
        _owner.overrideWith(
          (_) => const AuthenticatedScope(userId: 'keeper', readOnly: true),
        ),
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      isSuperAdminProvider.overrideWithValue(superAdmin),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftStorageProvider.overrideWithValue(storage ?? _Storage()),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      fixedBadgeSummaryOverride(),
      fakeWeightRepositoryOverride(),
    ],
  );
}

final _owner = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'keeper'),
);
final _server = StateProvider<String>((_) => 'https://input-test.example/api');
final _permissions = StateProvider<Set<String>>(
  (_) => const {
    Perm.warehouseIqcStockInView,
    Perm.warehouseIqcStockInConfirm,
    Perm.warehouseIqcStockInBeforeInspection,
    Perm.warehouseIqcReturnView,
    Perm.procurementIqcRejectionRecordReturn,
    Perm.warehouseSalesOutboundView,
    Perm.warehouseSalesOutboundExecute,
  },
);

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  GoRouter router,
) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final scenario in [
    for (final kind in ['single', 'batch'])
      for (final revoke in [false, true]) (kind: kind, revoke: revoke),
  ]) {
    final kind = scenario.kind;
    testWidgets(
      '$kind confirmation rechecks permission after the real draft checkpoint revoke=${scenario.revoke}',
      (tester) async {
        final api = _InputApi()..timeout = false;
        final storage = _Storage();
        final container = await _container(api, storage: storage);
        addTearDown(container.dispose);
        final location = kind == 'single'
            ? RouteName.warehouseQualityResultDetail('PURCHASE', 'receipt-a')
            : RouteName.warehouseQualityBatchStockIn;
        final router = GoRouter(
          initialLocation: location,
          routes: [
            GoRoute(
              path: location,
              builder: (_, _) => kind == 'single'
                  ? const WarehouseQualityResultDetailPage(
                      receiptType: 'PURCHASE',
                      receiptId: 'receipt-a',
                    )
                  : const WarehouseQualityBatchStockInPage(
                      receipts: [
                        (receiptType: 'PURCHASE', receiptId: 'receipt-a'),
                      ],
                    ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await _pump(tester, container, router);
        if (kind == 'single') {
          await tester.tap(
            find.byKey(const Key('warehouse-quality-detail-confirm')),
          );
          await tester.pumpAndSettle();
        }
        storage.submissionGate = Completer<void>();
        await tester.tap(
          find.byKey(
            Key(
              kind == 'single'
                  ? 'warehouse-inbound-allocation-confirm'
                  : 'warehouse-quality-batch-confirm',
            ),
          ),
        );
        for (var i = 0; i < 30 && !storage.submissionBlocked; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(
          storage.submissionBlocked,
          isTrue,
          reason:
              'The authoritative pre-submit storage checkpoint must really be awaited',
        );
        expect(api.posts, isEmpty);
        if (scenario.revoke) {
          container.read(_permissions.notifier).state = const {
            Perm.warehouseIqcStockInView,
          };
        }
        storage.submissionGate!.complete();
        await tester.pumpAndSettle();
        expect(
          api.posts,
          scenario.revoke ? isEmpty : hasLength(1),
          reason:
              'The unchanged complete grant dispatches; revoke stops dispatch',
        );
        if (!scenario.revoke) {
          final body = api.posts.single.body;
          final actual = kind == 'single'
              ? body
              : (body['batches'] as List).single as Map;
          expect(actual['idempotencyKey'], isNotEmpty);
          expect((actual['items'] as List).single, containsPair('baseQty', 10));
          expect(
            (actual['items'] as List).single,
            containsPair('expectedRemainingBaseQty', 10),
          );
          expect(
            (actual['items'] as List).single,
            containsPair('place', '默认库位'),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (
      name: 'sparse-superadmin-no-view',
      permissions: <String>{
        Perm.warehouseIqcStockInConfirm,
        Perm.warehouseIqcReturnView,
      },
      sa: true,
      readonly: false,
    ),
    (
      name: 'sparse-superadmin-no-confirm',
      permissions: <String>{Perm.warehouseIqcStockInView},
      sa: true,
      readonly: false,
    ),
    (
      name: 'initial-readonly-full-grants',
      permissions: <String>{
        Perm.warehouseIqcStockInView,
        Perm.warehouseIqcStockInConfirm,
      },
      sa: false,
      readonly: true,
    ),
  ]) {
    testWidgets('batch ordinary confirm fails closed ${scenario.name}', (
      tester,
    ) async {
      final api = _InputApi()..timeout = false;
      final container = await _container(
        api,
        permissions: scenario.permissions,
        superAdmin: scenario.sa,
        readOnly: scenario.readonly,
      );
      addTearDown(container.dispose);
      const location = RouteName.warehouseQualityBatchStockIn;
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: location,
            builder: (_, _) => const WarehouseQualityBatchStockInPage(
              receipts: [(receiptType: 'PURCHASE', receiptId: 'receipt-a')],
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, container, router);
      final submit = find.byKey(const Key('warehouse-quality-batch-confirm'));
      if (submit.evaluate().isNotEmpty) {
        await tester.tap(submit);
        await tester.pumpAndSettle();
      }
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final boundary in [
    'permission',
    'actor',
    'epoch',
    'actor-aba',
    'server',
    'readonly',
    'none',
  ]) {
    testWidgets('return dialog keeps original action scope across $boundary', (
      tester,
    ) async {
      final api = _InputApi()
        ..timeout = false
        ..includeRejection = true;
      final container = await _container(api);
      addTearDown(container.dispose);
      final location = RouteName.warehouseQualityResultDetail(
        'PURCHASE',
        'receipt-a',
      );
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: location,
            builder: (_, _) => const WarehouseQualityResultDetailPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-a',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, container, router);
      final open = find.text('登记退回');
      await tester.ensureVisible(open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      final inputs = find.descendant(
        of: dialog,
        matching: find.byType(TextFormField),
      );
      await tester.enterText(inputs.first, ' RET-ORIGINAL ');
      await tester.enterText(inputs.last, '原单实物退回');
      switch (boundary) {
        case 'permission':
          container.read(_permissions.notifier).state = const {
            Perm.warehouseIqcStockInView,
            Perm.warehouseIqcReturnView,
          };
        case 'actor':
          container.read(_owner.notifier).state = const AuthenticatedScope(
            userId: 'new-keeper',
            epoch: 1,
          );
        case 'epoch':
          container.read(_owner.notifier).state = const AuthenticatedScope(
            userId: 'keeper',
            epoch: 1,
          );
        case 'actor-aba':
          container.read(_owner.notifier).state = const AuthenticatedScope(
            userId: 'new-keeper',
          );
          await tester.pump();
          container.read(_owner.notifier).state = const AuthenticatedScope(
            userId: 'keeper',
          );
        case 'server':
          container.read(_server.notifier).state =
              'https://other-input.example/api';
        case 'readonly':
          container.read(_owner.notifier).state = const AuthenticatedScope(
            userId: 'keeper',
            readOnly: true,
          );
      }
      await tester.pump();
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('确认登记')),
      );
      await tester.pumpAndSettle();
      if (boundary == 'none') {
        expect(api.posts, hasLength(1));
        expect(
          api.posts.single.path,
          '/warehouse/iqc-returns/rejection-a/record-return',
        );
        expect(api.posts.single.body['expectedVersion'], 7);
        expect(api.posts.single.body['returnReference'], 'RET-ORIGINAL');
        expect(api.posts.single.body['commandId'], isNotEmpty);
      } else {
        expect(
          api.posts,
          isEmpty,
          reason:
              'An old dialog must never adopt a changed identity or permission',
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
  test(
    'a damaged empty original command cannot be treated as proof of completion',
    () {
      expect(
        () => WarehouseIqcPreStockInCommand.fromDraft({
          'items': <Map<String, dynamic>>[],
        }),
        throwsFormatException,
      );
      expect(
        () => WarehouseIqcStockInConfirmCommand.fromDraft({
          'idempotencyKey': 'original-key',
          'items': <Map<String, dynamic>>[],
        }),
        throwsFormatException,
      );
      expect(
        () => WarehouseQualityBatchConfirmCommand.fromDraft({
          'batches': <Map<String, dynamic>>[],
        }),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'saved pre-stock command verifies recorded coordinates after quality finishes without posting again',
    (tester) async {
      final api = _InputApi()
        ..preStockReadback = true
        ..remaining = 0;
      final container = await _container(api);
      addTearDown(container.dispose);
      final spec = FormDraftCatalog.warehouseQualityPreStockIn.spec(
        route: RouteName.warehouseQualityPreStockIn('PURCHASE', 'receipt-a'),
      );
      final store = container.read(formDraftsProvider.notifier);
      await store.ready;
      final saved = await store.save(
        FormDraft(
          id: 'unknown-pre-stock',
          title: spec.title,
          route: spec.route,
          module: spec.module,
          permission: spec.permission,
          updatedAt: DateTime(2026, 10, 11),
          data: {
            formDraftUnknownSubmissionKey: true,
            'receipts': [
              {'receiptType': 'PURCHASE', 'receiptId': 'receipt-a'},
            ],
            'rows': [
              {
                'inspectionItemId': 'inspection-a',
                'warehouseId': 'warehouse',
                'place': '原上架库位',
                'selected': true,
              },
            ],
            'pendingCommand': {
              'items': [
                {
                  'inspectionItemId': 'inspection-a',
                  'warehouseId': 'warehouse',
                  'place': '原上架库位',
                },
              ],
            },
          },
        ),
      );
      final router = GoRouter(
        initialLocation: saved.resumeLocation,
        routes: [
          GoRoute(
            path: RouteName.warehouseQualityPreStockIn('PURCHASE', 'receipt-a'),
            builder: (_, _) => const WarehouseQualityPreStockInPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-a',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, container, router);
      expect(
        find.byKey(const ValueKey('pre-stock-place-inspection-a')),
        findsNothing,
      );
      final recovery = find.text('核对原上架提交');
      expect(recovery, findsOneWidget);
      await tester.tap(recovery);
      await tester.pumpAndSettle();
      expect(api.posts, isEmpty);
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'withdrawing current shipment capability cannot erase persisted manual weight',
    (tester) async {
      final api = _InputApi();
      final container = await _container(api);
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/warehouse/sales-outbound/a',
        routes: [
          GoRoute(
            path: '/warehouse/sales-outbound/a',
            builder: (_, _) => const WarehouseSalesOutboundDetailPage(id: 'a'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, container, router);
      await tester.enterText(
        find.byKey(const ValueKey('sales-picking-place-line-a')),
        '已称重待放行',
      );
      await tester.enterText(
        find.byKey(const ValueKey('weight-cell-input')),
        '1.2500',
      );
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      final saved = container.read(formDraftsProvider).single;
      api.salesAllowed = false;
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-detail-refresh')),
      );
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      final original = container
          .read(formDraftsProvider)
          .singleWhere((draft) => draft.id == saved.id);
      final inputs = original.data['input'] as Map;
      final rows = (inputs['rows'] as List).cast<Map<String, dynamic>>();
      expect(rows.single['weightKg'], 1.25);
      expect(rows.single['place'], '已称重待放行');
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'task classification and quality matcher agree for lowercase receipt type routes',
    () {
      for (final descriptor in [
        FormDraftCatalog.warehouseQualityStockIn,
        FormDraftCatalog.warehouseQualityPreStockIn,
        FormDraftCatalog.warehouseQualityBatchStockIn,
      ]) {
        final route =
            descriptor == FormDraftCatalog.warehouseQualityBatchStockIn
            ? '${descriptor.route}?receipts=purchase:receipt-a'
            : descriptor.route
                  .replaceFirst(':receiptType', 'purchase')
                  .replaceFirst(':receiptId', 'receipt-a');
        final draft = FormDraft(
          id: 'case-${descriptor.title}',
          title: descriptor.title,
          module: descriptor.module,
          route: route,
          permission: descriptor.permission,
          updatedAt: DateTime(2026, 10, 11),
          data: {
            'receipts': [
              {'receiptType': 'purchase', 'receiptId': 'receipt-a'},
            ],
          },
        );
        expect(isTaskFormDraft(draft), isTrue);
        expect(qualityStockInTaskDrafts([draft], 'PURCHASE', 'receipt-a'), [
          draft,
        ]);
      }
    },
  );
  testWidgets(
    'sales manual place and weight survive refresh; source reload retains old CAS draft and starts new input',
    (tester) async {
      final api = _InputApi();
      final container = await _container(api);
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/warehouse/sales-outbound/a',
        routes: [
          GoRoute(path: '/blank', builder: (_, _) => const Scaffold()),
          GoRoute(
            path: '/warehouse/sales-outbound/a',
            builder: (_, _) => const WarehouseSalesOutboundDetailPage(id: 'a'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, container, router);
      await tester.enterText(
        find.byKey(const ValueKey('sales-picking-place-line-a')),
        '人工库位',
      );
      await tester.enterText(
        find.byKey(const ValueKey('weight-cell-input')),
        '1.2500',
      );
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      final saved = container.read(formDraftsProvider).single;
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-detail-refresh')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('sales-picking-place-line-a')),
            )
            .controller!
            .text,
        '人工库位',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('weight-cell-input')))
            .controller!
            .text,
        '1.25',
      );
      router.go('/blank');
      await tester.pumpAndSettle();
      api.salesQuantity = '12.0000';
      router.go(saved.resumeLocation);
      await tester.pumpAndSettle();
      expect(find.text('保留本机草稿，加载最新单据'), findsOneWidget);
      await tester.tap(find.text('保留本机草稿，加载最新单据'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sales-picking-place-line-a')),
        '最新单据库位',
      );
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      final drafts = container.read(formDraftsProvider);
      expect(drafts.length, 2);
      final original = drafts.singleWhere((draft) => draft.id == saved.id);
      final oldRows = ((original.data['input'] as Map)['rows'] as List)
          .cast<Map<String, dynamic>>();
      expect(oldRows.single['place'], '人工库位');
      expect(oldRows.single['quantity'], '10.0000');
      expect(oldRows.single['weightKg'], 1.25);
      final fresh = drafts.singleWhere((draft) => draft.id != saved.id);
      final rows = ((fresh.data['input'] as Map)['rows'] as List)
          .cast<Map<String, dynamic>>();
      expect(rows.single['place'], '最新单据库位');
      expect(rows.single['quantity'], '12.0000');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity change during first source GET cannot bind old input to new owner',
    (tester) async {
      final api = _InputApi()..sourceGate = Completer<void>();
      final container = await _container(api);
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/warehouse/sales-outbound/a',
        routes: [
          GoRoute(
            path: '/warehouse/sales-outbound/a',
            builder: (_, _) => const WarehouseSalesOutboundDetailPage(id: 'a'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      expect(api.sourceStarted, isTrue);
      container.read(_owner.notifier).state = const AuthenticatedScope(
        userId: 'new-keeper',
      );
      await tester.pump();
      api.sourceGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('sales-picking-place-line-a')),
        findsNothing,
      );
      expect(container.read(formDraftsProvider), isEmpty);
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  for (final batch in [false, true]) {
    testWidgets(
      'quality ${batch ? 'batch' : 'single'} persisted unknown command replays unchanged after all sources finish',
      (tester) async {
        final api = _InputApi();
        final container = await _container(api);
        addTearDown(container.dispose);
        final path = batch
            ? RouteName.warehouseQualityBatchStockIn
            : RouteName.warehouseQualityResultDetail('PURCHASE', 'receipt-a');
        final router = GoRouter(
          initialLocation: path,
          routes: [
            GoRoute(path: '/blank', builder: (_, _) => const Scaffold()),
            GoRoute(
              path: path,
              builder: (_, _) => batch
                  ? const WarehouseQualityBatchStockInPage(
                      receipts: [
                        (receiptType: 'PURCHASE', receiptId: 'receipt-a'),
                      ],
                    )
                  : const WarehouseQualityResultDetailPage(
                      receiptType: 'PURCHASE',
                      receiptId: 'receipt-a',
                    ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await _pump(tester, container, router);
        await tester.enterText(
          find.byKey(const ValueKey('quality-slice-qty-pass-a')),
          '4.2500',
        );
        await tester.enterText(
          find.byKey(const ValueKey('quality-slice-place-pass-a')),
          '原输入库位',
        );
        await tester.tap(
          find.byKey(
            Key(
              batch
                  ? 'warehouse-quality-batch-confirm'
                  : 'warehouse-quality-detail-confirm',
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (!batch) {
          await tester.tap(
            find.byKey(const Key('warehouse-inbound-allocation-confirm')),
          );
          await tester.pumpAndSettle();
        }
        if (batch) {
          await tester.tap(find.text('知道了'));
          await tester.pumpAndSettle();
        }
        expect(api.posts.length, 1);
        final saved = container.read(formDraftsProvider).single;
        expect(saved.hasUnknownSubmission, isTrue);
        expect(saved.data['pendingCommand'], isNotNull);
        router.go('/blank');
        await tester.pumpAndSettle();
        router.go(saved.resumeLocation);
        await tester.pumpAndSettle();
        final recovery = find.text(batch ? '核对原批量入库提交' : '核对原入库提交');
        expect(recovery, findsOneWidget);
        await tester.tap(recovery);
        await tester.pumpAndSettle();
        expect(api.posts.length, 2);
        expect(api.posts.first.body, api.posts.last.body);
        expect(container.read(formDraftsProvider), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'sales batch partial ACK and lost response resumes only unfinished third shipment',
    (tester) async {
      final api = _InputApi();
      final container = await _container(api);
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: '/warehouse/sales-outbound/batch',
        routes: [
          GoRoute(path: '/blank', builder: (_, _) => const Scaffold()),
          GoRoute(
            path: '/warehouse/sales-outbound',
            builder: (_, _) => const Scaffold(),
          ),
          GoRoute(
            path: '/warehouse/sales-outbound/batch',
            builder: (_, _) => const WarehouseSalesOutboundBatchPage(
              shipmentIds: ['a', 'b', 'c'],
              action: WarehouseSalesOutboundAction.confirmShipment,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, container, router);
      for (final id in ['a', 'b', 'c']) {
        await tester.enterText(
          find.byKey(ValueKey('sales-picking-place-line-$id')),
          '原库位-$id',
        );
      }
      Future<void> submit() async {
        await tester.tap(
          find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('warehouse-sales-outbound-batch-confirm')),
        );
        await tester.pumpAndSettle();
      }

      await submit();
      expect(api.posts.length, 2);
      final saved = container.read(formDraftsProvider).single;
      expect(saved.hasUnknownSubmission, isTrue);
      expect(saved.data['completed'], ['a']);
      expect(saved.data['unknownShipment'], 'b');
      router.go('/blank');
      await tester.pumpAndSettle();
      router.go(saved.resumeLocation);
      await tester.pumpAndSettle();
      await submit();
      expect(api.posts.length, 3);
      expect(
        api.posts
            .map((post) => post.path)
            .where((path) => path.contains('/a/'))
            .length,
        1,
      );
      expect(
        api.posts
            .map((post) => post.path)
            .where((path) => path.contains('/b/'))
            .length,
        1,
      );
      expect(api.posts.last.path, contains('/c/'));
      final pickingRows = (api.posts.last.body['stockPlaces'] as List)
          .cast<Map<String, dynamic>>();
      expect(pickingRows.single['stockPlace'], '原库位-c');
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
