import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/production_draw_discovery_row.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_draw_task.dart';
import 'package:uten_imp/features/warehouse/pages/production_draw_batch_issue_page.dart';
import 'package:uten_imp/features/warehouse/repositories/production_draw_task_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/production_material_discovery_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/production_draw_detail_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/models/production_material_discovery.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import 'outbound_weight_fakes.dart';
import '../../support/audit_screenshot_support.dart';

const _plastic = <String, dynamic>{
  'goodsId': 'plastic',
  'goodsName': '塑料颗粒',
  'goodsCode': 'P01',
  'colorId': 'white',
  'colorName': '白色',
  'unitId': 'kg',
  'unitName': '千克',
  'spec': 'PC-ABS',
  'stockPlace': 'A-01',
  'qty': null,
};

ProductionMaterialDiscoveryDetail _request(
  String id, {
  List<Map<String, dynamic>>? items,
  String status = 'PENDING',
}) => ProductionMaterialDiscoveryDetail.fromJson({
  'requestId': id,
  'requestNo': 'LQ-$id',
  'segmentId': 'segment-$id',
  'segmentCode': 'ZX-$id',
  'planNo': 'SJ-$id',
  'productCode': 'SHELL',
  'productName': '外壳',
  'plannedQty': 3000,
  'productUnitName': '个',
  'workshopName': '注塑车间',
  'status': status,
  'version': 7,
  'suggestedItems': items ?? [_plastic],
});

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '常规原料';
  @override
  String warehouse(String? id) => '常规仓';
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'w1', name: '原料仓一'),
    WarehouseDictEntry(id: 'w2', name: '原料仓二'),
  ];
}

class _StockRepository extends StockDocRepository {
  _StockRepository() : super(ApiClient(Dio()), StockDocType.draw);
  bool allIssued = false;
  Future<void>? gate;
  @override
  Future<StockDocDetail> detail(String id) async {
    await gate;
    return StockDocDetail(
      id: id,
      docType: 'DRAW',
      billNo: 'SL-$id',
      materialRequestNo: 'LQ-normal-source',
      status: 1,
      warehouseId: 'normal-warehouse',
      departmentId: 'workshop',
      planNo: 'SJ-normal',
      items: [
        StockDocItem(
          id: 'item-$id',
          goodsId: 'normal',
          unitId: 'kg',
          qty: 10,
          requestedQty: 8,
          issuedQty: allIssued ? 8 : 3,
        ),
      ],
    );
  }
}

final _scope = StateProvider<AuthenticatedScope?>((ref) => null);
final _server = StateProvider<String>((ref) => 'https://batch.example/api');
final _permissions = StateProvider<Set<String>>((ref) => {});

class _Storage implements FormDraftStorage {
  final records = <String, String>{};
  Future<void>? gate;
  bool failWrites = false;
  bool failCompletions = false;
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async => records[key] = value;
  @override
  Future<void> remove(String key) async => records.remove(key);
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    await gate;
    if (failWrites) throw StateError('storage full');
    if (failCompletions &&
        value != null &&
        (jsonDecode(value) as Map)['completed'] == true) {
      throw StateError('completion storage failed');
    }
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }

  Map<String, dynamic> get draft => records.values
      .map((value) => jsonDecode(value) as Map<String, dynamic>)
      .where((value) => value['completed'] != true)
      .single;
}

class _DiscoveryRepository extends ProductionMaterialDiscoveryRepository {
  _DiscoveryRepository() : super(ApiClient(Dio()));
  final values = <String, ProductionMaterialDiscoveryDetail>{};
  @override
  Future<ProductionMaterialDiscoveryDetail> detail(String id) async =>
      values[id] ?? _request(id);
}

class _Tasks extends ProductionDrawTaskRepository {
  _Tasks() : super(ApiClient(Dio()));
  final submissions = <Map<String, dynamic>>[];
  int ordinaryCalls = 0;
  Object? failure;
  WarehouseDrawBatchIssueResult? ordinaryResult;
  WarehouseDrawBatchIssueResult? mixedResult;
  Future<void>? sendGate;
  VoidCallback? onSend;
  @override
  Future<WarehouseDrawBatchIssueResult> issueDiscoveryBatch({
    required String idempotencyKey,
    required List<String> docIds,
    required List<Map<String, dynamic>> discoveries,
    List<Map<String, dynamic>> weights = const [],
    String? reason,
  }) async {
    submissions.add(
      Map<String, dynamic>.from(
        jsonDecode(
              jsonEncode({
                'key': idempotencyKey,
                'docIds': docIds,
                'discoveries': discoveries,
                'weights': weights,
                'reason': reason,
              }),
            )
            as Map,
      ),
    );
    onSend?.call();
    await sendGate;
    if (failure != null) throw failure!;
    return mixedResult ??
        WarehouseDrawBatchIssueResult(
          issuedCount: docIds.length + discoveries.length,
          skippedCount: 0,
          replayedCount: 0,
          replayed: false,
          issuedDocNos: const [],
        );
  }

  final fullBatchWeights = <List<Map<String, dynamic>>>[];
  final ordinarySubmissions = <Map<String, dynamic>>[];

  @override
  Future<WarehouseDrawBatchIssueResult> issueFullBatch({
    required String idempotencyKey,
    required List<String> docIds,
    List<Map<String, dynamic>> weights = const [],
    String? reason,
  }) async {
    ordinaryCalls++;
    fullBatchWeights.add(weights);
    ordinarySubmissions.add(
      Map<String, dynamic>.from(
        jsonDecode(
              jsonEncode({
                'key': idempotencyKey,
                'docIds': docIds,
                'weights': weights,
                'reason': reason,
              }),
            )
            as Map,
      ),
    );
    onSend?.call();
    await sendGate;
    if (failure != null) throw failure!;
    return ordinaryResult ??
        WarehouseDrawBatchIssueResult(
          issuedCount: docIds.length,
          skippedCount: 0,
          replayedCount: 0,
          replayed: false,
          issuedDocNos: const [],
        );
  }
}

Future<({GoRouter router, ProviderContainer container})> _pump(
  WidgetTester tester,
  _Tasks tasks, {
  List<String> docs = const ['normal'],
  List<String> requests = const ['request'],
  _DiscoveryRepository? discoveryRepository,
  _StockRepository? stockRepository,
  _Storage? storage,
  AuthenticatedScope? scope,
  String? draftId,
  bool denyExit = false,
  bool realRoute = false,
  bool draftGuard = false,
  bool realTheme = false,
  bool dark = false,
  GlobalKey? capture,
  FakeWeightRepository? weights,
  bool approve = true,
  bool issue = true,
  Size size = const Size(1900, 1000),
  double scale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => context.push(
              Uri(
                path: RouteName.warehouseProductionDrawBatchIssue,
                queryParameters: {
                  'documentIds': docs.join(','),
                  'discoveryRequestIds': requests.join(','),
                  'draftId': ?draftId,
                },
              ).toString(),
            ),
            child: const Text('打开批量'),
          ),
        ),
      ),
      if (draftGuard)
        DraftAwareGoRoute(
          path: RouteName.warehouseProductionDrawBatchIssue,
          builder: ProductionDrawBatchIssuePage.route,
        )
      else
        GoRoute(
          path: RouteName.warehouseProductionDrawBatchIssue,
          onExit: (_, _) => !denyExit,
          builder: realRoute
              ? ProductionDrawBatchIssuePage.route
              : (_, state) => ProductionDrawBatchIssuePage(
                  documentIds: (state.uri.queryParameters['documentIds'] ?? '')
                      .split(',')
                      .where((id) => id.isNotEmpty)
                      .toList(),
                  discoveryRequestIds:
                      (state.uri.queryParameters['discoveryRequestIds'] ?? '')
                          .split(',')
                          .where((id) => id.isNotEmpty)
                          .toList(),
                ),
        ),
      GoRoute(
        path: '/other',
        builder: (_, _) => const Scaffold(body: Text('另一个页面')),
      ),
    ],
  );
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      _scope.overrideWith((ref) => scope),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      if (storage != null) formDraftStorageProvider.overrideWithValue(storage),
      isSuperAdminProvider.overrideWithValue(false),
      _permissions.overrideWith(
        (ref) => {
          Perm.stockDocView,
          if (approve) Perm.stockDocApprove,
          if (issue) Perm.stockDocIssue,
        },
      ),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      masterNameServiceProvider.overrideWithValue(_Names()),
      productionDrawTaskRepositoryProvider.overrideWithValue(tasks),
      productionMaterialDiscoveryRepositoryProvider.overrideWithValue(
        discoveryRepository ?? _DiscoveryRepository(),
      ),
      stockDocRepositoryProvider(
        StockDocType.draw,
      ).overrideWithValue(stockRepository ?? _StockRepository()),
      fakeWeightRepositoryOverride(weights),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: realTheme
            ? (capture == null
                  ? (dark ? buildDarkTheme() : buildLightTheme())
                  : _batchScreenshotTheme(
                      dark ? buildDarkTheme() : buildLightTheme(),
                    ))
            : null,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          final content = MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: Stack(
              children: [
                child!,
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AppNotificationHost(useSafeArea: false),
                ),
              ],
            ),
          );
          return capture == null
              ? content
              : RepaintBoundary(key: capture, child: content);
        },
      ),
    ),
  );
  await tester.tap(find.text('打开批量'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
  return (router: router, container: container);
}

ThemeData _batchScreenshotTheme(ThemeData theme) {
  final screenshot = auditScreenshotTheme(theme);
  return screenshot.copyWith(
    dialogTheme: screenshot.dialogTheme.copyWith(
      titleTextStyle:
          (theme.dialogTheme.titleTextStyle ?? theme.textTheme.headlineSmall)
              ?.copyWith(fontFamily: 'NotoSansSC'),
      contentTextStyle:
          (theme.dialogTheme.contentTextStyle ?? theme.textTheme.bodyMedium)
              ?.copyWith(fontFamily: 'NotoSansSC'),
    ),
  );
}

ProductionDrawDetailTable _table(WidgetTester tester) => tester
    .widget<ProductionDrawDetailTable>(find.byType(ProductionDrawDetailTable));
Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  for (final change in ['account', 'server']) {
    Future<void> aba(WidgetTester tester, ProviderContainer container) async {
      final owner = container.read(_scope);
      final server = container.read(_server);
      if (change == 'account') {
        container.read(_scope.notifier).state = const AuthenticatedScope(
          userId: 'other',
        );
      } else {
        container.read(_server.notifier).state = 'https://other.example/api';
      }
      await tester.pump();
      if (change == 'account') {
        container.read(_scope.notifier).state = owner;
      } else {
        container.read(_server.notifier).state = server;
      }
      await tester.pump();
    }

    testWidgets('ABA batch $change initial read cannot revive the old view', (
      tester,
    ) async {
      final gate = Completer<void>();
      final env = await _pump(
        tester,
        _Tasks(),
        requests: [],
        scope: const AuthenticatedScope(userId: 'one'),
        stockRepository: _StockRepository()..gate = gate.future,
        settle: false,
        draftGuard: true,
      );
      await aba(tester, env.container);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
      expect(
        find.byKey(const Key('warehouse-draw-batch-confirm')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
    for (final mixed in [false, true]) {
      for (final beforeSend in [false, true]) {
        testWidgets(
          'ABA batch $change mixed=$mixed beforeSend=$beforeSend preserves original command without publication',
          (tester) async {
            final gate = Completer<void>();
            final storage = _Storage();
            final tasks = _Tasks();
            final env = await _pump(
              tester,
              tasks,
              requests: mixed ? ['request'] : [],
              storage: storage,
              scope: const AuthenticatedScope(userId: 'one'),
              draftGuard: true,
            );
            if (mixed) {
              final row = _table(tester).discoveryRows.single;
              row.quantity.text = '12.5';
              row.values['warehouseId'] = 'w1';
            }
            await tester.pumpAndSettle();
            if (beforeSend) {
              storage.gate = gate.future;
            } else {
              tasks.sendGate = gate.future;
            }
            final location = env.router.routerDelegate.currentConfiguration.uri;
            await tester.tap(
              find.byKey(const Key('warehouse-draw-batch-confirm')),
            );
            await tester.pump(const Duration(milliseconds: 400));
            final frozen = beforeSend
                ? null
                : Map<String, String>.of(storage.records);
            await aba(tester, env.container);
            gate.complete();
            await tester.pumpAndSettle();
            expect(
              tasks.ordinaryCalls + tasks.submissions.length,
              beforeSend ? 0 : 1,
            );
            expect(
              env.container
                  .read(appNotificationProvider)
                  .where(
                    (notice) => notice.kind == AppNotificationKind.success,
                  ),
              isEmpty,
            );
            expect(
              env.router.routerDelegate.currentConfiguration.uri,
              location,
            );
            if (frozen != null) expect(storage.records, frozen);
            expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  for (final variant in [
    'unified-only',
    'contradictory-receipt',
    'invalid-restored-selection',
  ]) {
    testWidgets(
      'restore boundary $variant cannot clear original evidence or imply success',
      (tester) async {
        final storage = _Storage();
        final tasks = _Tasks()..failure = NetworkTimeoutException();
        await _pump(
          tester,
          tasks,
          requests: [],
          storage: storage,
          scope: const AuthenticatedScope(userId: 'one'),
        );
        await _submit(tester);
        final id = storage.draft['id'] as String;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final entry = storage.records.entries.single;
        final saved = jsonDecode(entry.value) as Map<String, dynamic>;
        final data = saved['data'] as Map;
        data['_formDraftSubmissionPending'] = false;
        data['_formDraftHasUnknownSubmission'] = variant == 'unified-only';
        data['uncertain'] = variant == 'contradictory-receipt';
        if (variant != 'unified-only') {
          data['confirmedResult'] = {
            'issuedCount': 1,
            'skippedCount': 0,
            'replayedCount': 0,
            'replayed': false,
            'issuedDocNos': ['SL-normal'],
          };
        }
        if (variant == 'invalid-restored-selection') {
          data['submittedDocIds'] = ['some-other-document'];
        }
        storage.records[entry.key] = jsonEncode(saved);
        final before = Map<String, String>.of(storage.records);
        final env = await _pump(
          tester,
          tasks,
          requests: [],
          storage: storage,
          scope: const AuthenticatedScope(userId: 'one', epoch: 2),
          draftId: id,
          draftGuard: true,
        );
        expect(storage.records, before);
        expect(tasks.ordinaryCalls, 1);
        expect(
          env.container
              .read(appNotificationProvider)
              .where((notice) => notice.kind == AppNotificationKind.success),
          isEmpty,
        );
        if (variant != 'invalid-restored-selection') {
          expect(_table(tester).issueSaving, isTrue);
        }
        env.router.go('/other');
        await tester.pumpAndSettle();
        if (variant != 'invalid-restored-selection') {
          expect(find.text('不保存'), findsNothing);
          await tester.tap(find.text('保存原提交后离开'));
          await tester.pumpAndSettle();
        }
        expect(find.text('另一个页面'), findsOneWidget);
        expect(
          storage.records.values.single,
          isNot(contains('"completed":true')),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final mixed in [false, true]) {
    for (final revoked in [false, true]) {
      testWidgets(
        'unknown exit saves ${mixed ? 'mixed' : 'ordinary'} original and resumes key revoked=$revoked',
        (tester) async {
          final storage = _Storage();
          final tasks = _Tasks()..failure = NetworkTimeoutException();
          final env = await _pump(
            tester,
            tasks,
            requests: mixed ? ['request'] : [],
            storage: storage,
            scope: const AuthenticatedScope(userId: 'one'),
            realRoute: true,
            draftGuard: true,
          );
          if (mixed) {
            final row = _table(tester).discoveryRows.single;
            row.quantity.text = '12.5';
            row.values['warehouseId'] = 'w1';
          }
          await _submit(tester);
          final calls = mixed ? tasks.submissions : tasks.ordinarySubmissions;
          final original = jsonEncode(calls.single);
          final id = storage.draft['id'] as String;
          if (revoked) {
            env.container.read(_permissions.notifier).state = {
              Perm.stockDocView,
            };
          }
          await tester.pumpAndSettle();
          env.router.go('/');
          await tester.pumpAndSettle();
          expect(find.text('不保存'), findsNothing);
          expect(find.text('继续核对'), findsOneWidget);
          await tester.tap(find.text('保存原提交后离开'));
          await tester.pumpAndSettle();
          expect(find.text('打开批量'), findsOneWidget);
          expect(storage.draft['id'], id);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          tasks.failure = null;
          await _pump(
            tester,
            tasks,
            requests: mixed ? ['request'] : [],
            storage: storage,
            scope: const AuthenticatedScope(userId: 'one', epoch: 2),
            draftId: id,
            realRoute: true,
            draftGuard: true,
            approve: mixed,
          );
          await _submit(tester);
          expect(calls, hasLength(2));
          expect(jsonEncode(calls.last), original);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('ordinary receipt must account for every selected document', (
    tester,
  ) async {
    final tasks = _Tasks()
      ..ordinaryResult = const WarehouseDrawBatchIssueResult(
        issuedCount: 1,
        skippedCount: 0,
        replayedCount: 0,
        replayed: false,
        issuedDocNos: ['SL-normal'],
      );
    await _pump(tester, tasks, docs: ['normal', 'second'], requests: []);
    await _submit(tester);
    expect(_table(tester).issueSaving, isTrue);
    final original = jsonEncode(tasks.ordinarySubmissions.single);
    tasks.ordinaryResult = const WarehouseDrawBatchIssueResult(
      issuedCount: 0,
      skippedCount: 0,
      replayedCount: 2,
      replayed: true,
      issuedDocNos: [],
    );
    await _submit(tester);
    expect(tasks.ordinarySubmissions, hasLength(2));
    expect(jsonEncode(tasks.ordinarySubmissions.last), original);
    expect(tester.takeException(), isNull);
  });
  for (final mixed in [false, true]) {
    testWidgets(
      'receipt completeness cannot confirm empty ${mixed ? 'mixed' : 'ordinary'} result',
      (tester) async {
        const empty = WarehouseDrawBatchIssueResult(
          issuedCount: 0,
          skippedCount: 0,
          replayedCount: 0,
          replayed: false,
          issuedDocNos: [],
        );
        final tasks = _Tasks()
          ..ordinaryResult = empty
          ..mixedResult = empty;
        await _pump(tester, tasks, requests: mixed ? ['request'] : []);
        if (mixed) {
          final row = _table(tester).discoveryRows.single;
          row.quantity.text = '12.5';
          row.values['warehouseId'] = 'w1';
        }
        await _submit(tester);
        expect(find.byType(ProductionDrawBatchIssuePage), findsOneWidget);
        expect(_table(tester).issueSaving, isTrue);
        expect(find.textContaining('出库结果待确认，当前信息已锁定'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'shared pending marker cannot be downgraded by an older page flag',
    (tester) async {
      final storage = _Storage();
      final tasks = _Tasks()..failure = NetworkTimeoutException();
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one'),
      );
      await _submit(tester);
      final id = storage.draft['id'] as String;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final entry = storage.records.entries.single;
      final saved = jsonDecode(entry.value) as Map<String, dynamic>;
      (saved['data'] as Map)['uncertain'] = false;
      (saved['data'] as Map)['_formDraftSubmissionPending'] = true;
      (saved['data'] as Map).remove('_formDraftHasUnknownSubmission');
      storage.records[entry.key] = jsonEncode(saved);
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one', epoch: 2),
        draftId: id,
      );
      expect(_table(tester).issueSaving, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('warehouse-draw-batch-remark')),
            )
            .readOnly,
        isTrue,
      );
      expect(tasks.ordinaryCalls, 1);
    },
  );
  test(
    'actual batch route delegates to its stable selection and draft builder',
    () {
      final router = File('lib/core/router/app_router.dart').readAsStringSync();
      expect(router, contains('builder: ProductionDrawBatchIssuePage.route'));
    },
  );

  testWidgets('actual route selection change replaces the old batch editor', (
    tester,
  ) async {
    final tasks = _Tasks();
    final harness = await _pump(tester, tasks, requests: [], realRoute: true);
    harness.router.go(
      '${RouteName.warehouseProductionDrawBatchIssue}?documentIds=normal',
    );
    await tester.pumpAndSettle();
    final oldState = tester.state(find.byType(ProductionDrawBatchIssuePage));
    await tester.enterText(
      find.byKey(const Key('warehouse-draw-batch-remark')),
      '只属于原批',
    );
    harness.router.go(
      '${RouteName.warehouseProductionDrawBatchIssue}?documentIds=second',
    );
    await tester.pumpAndSettle();
    expect(
      tester.state(find.byType(ProductionDrawBatchIssuePage)),
      isNot(same(oldState)),
    );
    expect(_table(tester).documents.single.id, 'second');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('warehouse-draw-batch-remark')),
          )
          .controller!
          .text,
      isEmpty,
    );
    expect(tasks.ordinaryCalls, 0);
  });

  testWidgets(
    'actual route ordering alone keeps the same editor but draft identity does not',
    (tester) async {
      final tasks = _Tasks();
      final harness = await _pump(
        tester,
        tasks,
        docs: ['second', 'normal'],
        requests: [],
        realRoute: true,
      );
      harness.router.go(
        '${RouteName.warehouseProductionDrawBatchIssue}?documentIds=second,normal',
      );
      await tester.pumpAndSettle();
      final oldState = tester.state(find.byType(ProductionDrawBatchIssuePage));
      await tester.enterText(
        find.byKey(const Key('warehouse-draw-batch-remark')),
        '同批保留',
      );
      harness.router.go(
        '${RouteName.warehouseProductionDrawBatchIssue}?documentIds=normal,second',
      );
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(ProductionDrawBatchIssuePage)),
        same(oldState),
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('warehouse-draw-batch-remark')),
            )
            .controller!
            .text,
        '同批保留',
      );
      harness.router.go(
        '${RouteName.warehouseProductionDrawBatchIssue}?documentIds=normal,second&draftId=another',
      );
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(ProductionDrawBatchIssuePage)),
        isNot(same(oldState)),
      );
      expect(tasks.ordinaryCalls, 0);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'unknown rejection visual remains frozen and retryable dark=$dark',
      (tester) async {
        final capture =
            Platform.environment['UTEN_CAPTURE_DRAW_BATCH_BOUNDARY'] == 'true'
            ? GlobalKey()
            : null;
        if (capture != null) await loadAuditScreenshotFonts(tester);
        final tasks = _Tasks()..failure = NetworkTimeoutException();
        final env = await _pump(
          tester,
          tasks,
          realTheme: true,
          storage: _Storage(),
          scope: const AuthenticatedScope(userId: 'visual'),
          draftGuard: true,
          dark: dark,
          capture: capture,
          size: dark ? const Size(1440, 1000) : const Size(375, 844),
          scale: 1.5,
        );
        final row = _table(tester).discoveryRows.single;
        row.quantity.text = '12.5';
        row.values['warehouseId'] = 'w1';
        await _submit(tester);
        tasks.failure = ApiException(
          'FORBIDDEN',
          '当前暂时无法核对，请保留原批',
          httpStatus: 403,
        );
        await _submit(tester);
        expect(_table(tester).issueSaving, isTrue);
        final retry = find.byKey(const Key('warehouse-draw-batch-confirm'));
        expect(tester.widget<UtenButton>(retry).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        if (capture != null) {
          await saveAuditScreenshot(
            tester,
            capture,
            'draw-batch-unknown-${dark ? '1440-dark' : '375-light'}',
          );
        }
        env.router.go('/other');
        await tester.pumpAndSettle();
        expect(find.text('不保存'), findsNothing);
        expect(find.text('保存原提交后离开'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capture != null) {
          await saveAuditScreenshot(
            tester,
            capture,
            'draw-batch-unknown-exit-${dark ? '1440-dark' : '375-light'}',
          );
        }
        await tester.tap(find.text('继续核对'));
        await tester.pumpAndSettle();
      },
    );
  }
  testWidgets(
    'submission boundary never dispatches when durable checkpoint fails',
    (tester) async {
      final storage = _Storage();
      final tasks = _Tasks();
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one'),
      );
      storage.failWrites = true;
      await _submit(tester);
      expect(tasks.ordinaryCalls, 0);
      expect(_table(tester).issueSaving, isFalse);
      expect(find.textContaining('出库结果待确认，当前信息已锁定'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'submission boundary persists exact key and payload before dispatch',
    (tester) async {
      final storage = _Storage();
      final tasks = _Tasks();
      tasks.onSend = () {
        final data = storage.draft['data'] as Map;
        expect(data['uncertain'], isTrue);
        expect(data['submittedDocIds'], ['normal']);
        expect(data['requestKey'], tasks.ordinarySubmissions.single['key']);
      };
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one'),
      );
      await _submit(tester);
      expect(tasks.ordinaryCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['account', 'server', 'route', 'selection']) {
    testWidgets(
      'submission boundary fences $change change while checkpoint is pending',
      (tester) async {
        final storage = _Storage();
        final tasks = _Tasks();
        final harness = await _pump(
          tester,
          tasks,
          requests: [],
          storage: storage,
          scope: const AuthenticatedScope(userId: 'one'),
        );
        final gate = Completer<void>();
        storage.gate = gate.future;
        await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
        await tester.pump();
        expect(tasks.ordinaryCalls, 0);
        switch (change) {
          case 'account':
            harness.container.read(_scope.notifier).state =
                const AuthenticatedScope(userId: 'two');
          case 'server':
            harness.container.read(_server.notifier).state =
                'https://other.example/api';
          case 'route':
            unawaited(harness.router.push('/other'));
          case 'selection':
            harness.router.go(
              '${RouteName.warehouseProductionDrawBatchIssue}?documentIds=second',
            );
        }
        await tester.pump();
        gate.complete();
        await tester.pumpAndSettle();
        expect(tasks.ordinaryCalls, 0);
        if (change == 'route') expect(find.text('另一个页面'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'submission boundary late success cannot pop a page opened during the command',
    (tester) async {
      final gate = Completer<void>();
      final tasks = _Tasks()..sendGate = gate.future;
      final harness = await _pump(tester, tasks, requests: []);
      await tester.tap(find.byKey(const Key('warehouse-draw-batch-confirm')));
      await tester.pump();
      unawaited(harness.router.push('/other'));
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('另一个页面'), findsOneWidget);
      expect(tasks.ordinaryCalls, 1);
      expect(find.textContaining('已出库 1 张领料单'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mixed in [false, true]) {
    testWidgets(
      'submission boundary restores ${mixed ? 'mixed' : 'ordinary'} unknown across login epochs without trusting completed GET',
      (tester) async {
        final storage = _Storage();
        final tasks = _Tasks()..failure = NetworkTimeoutException();
        await _pump(
          tester,
          tasks,
          requests: mixed ? ['request'] : [],
          storage: storage,
          scope: const AuthenticatedScope(userId: 'one'),
        );
        if (mixed) {
          final row = _table(tester).discoveryRows.single;
          row.quantity.text = '12.5';
          row.values['warehouseId'] = 'w1';
        }
        await _submit(tester);
        tasks.failure = ApiException('FORBIDDEN', '暂时没有权限', httpStatus: 403);
        await _submit(tester);
        final calls = mixed ? tasks.submissions : tasks.ordinarySubmissions;
        final original = jsonEncode(calls.first);
        final id = storage.draft['id'] as String;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final discovery = _DiscoveryRepository()
          ..values['request'] = _request('request', status: 'CONFIGURED');
        final stock = _StockRepository()..allIssued = true;
        await _pump(
          tester,
          tasks,
          requests: mixed ? ['request'] : [],
          storage: storage,
          scope: const AuthenticatedScope(userId: 'one', epoch: 2),
          draftId: id,
          stockRepository: stock,
          discoveryRepository: discovery,
          approve: false,
        );
        expect(
          calls,
          hasLength(2),
          reason: 'GET status alone never confirms this original batch',
        );
        expect(_table(tester).issueSaving, isTrue);
        expect(
          tester
              .widget<UtenButton>(
                find.byKey(const Key('warehouse-draw-batch-confirm')),
              )
              .onPressed,
          isNotNull,
        );
        tasks.failure = null;
        tasks.ordinaryResult = const WarehouseDrawBatchIssueResult(
          issuedCount: 0,
          skippedCount: 1,
          replayedCount: 0,
          replayed: true,
          issuedDocNos: [],
        );
        await _submit(tester);
        expect(calls, hasLength(3));
        expect(jsonEncode(calls.last), original);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'submission boundary permission restoration permits issuer-only replay of the original approved batch',
    (tester) async {
      final tasks = _Tasks()..failure = NetworkTimeoutException();
      final harness = await _pump(tester, tasks, requests: [], approve: false);
      await _submit(tester);
      final original = jsonEncode(tasks.ordinarySubmissions.single);
      harness.container.read(_permissions.notifier).state = {Perm.stockDocView};
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-draw-batch-confirm')),
        findsNothing,
      );
      harness.container.read(_permissions.notifier).state = {
        Perm.stockDocView,
        Perm.stockDocIssue,
      };
      await tester.pumpAndSettle();
      tasks.failure = null;
      await _submit(tester);
      expect(tasks.ordinarySubmissions, hasLength(2));
      expect(jsonEncode(tasks.ordinarySubmissions.last), original);
    },
  );

  testWidgets(
    'submission boundary confirmed success stays terminal if cleanup and navigation fail',
    (tester) async {
      final storage = _Storage();
      final tasks = _Tasks()..onSend = () => storage.failWrites = true;
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one'),
        denyExit: true,
      );
      await _submit(tester);
      final button = find.byKey(const Key('warehouse-draw-batch-confirm'));
      expect(tester.widget<UtenButton>(button).onPressed, isNull);
      expect(find.textContaining('出库结果待确认，当前信息已锁定'), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(tasks.ordinaryCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'submission boundary persisted confirmation recovers without posting again',
    (tester) async {
      final storage = _Storage()..failCompletions = true;
      final tasks = _Tasks();
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one'),
        denyExit: true,
      );
      await _submit(tester);
      expect(storage.draft['data'], contains('confirmedResult'));
      final id = storage.draft['id'] as String;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      storage.failCompletions = false;
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one', epoch: 2),
        draftId: id,
      );
      expect(tasks.ordinaryCalls, 1);
      expect(
        (jsonDecode(storage.records.values.single) as Map)['completed'],
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final mixed in [false, true]) {
    for (final rejection in [
      (403, 'FORBIDDEN'),
      (400, 'VALIDATION_FAILED'),
      (422, 'VALIDATION_FAILED'),
    ]) {
      testWidgets(
        'unknown ${mixed ? 'mixed' : 'ordinary'} followed by ${rejection.$1} keeps its original command frozen',
        (tester) async {
          final tasks = _Tasks()..failure = NetworkTimeoutException();
          await _pump(
            tester,
            tasks,
            requests: mixed ? const ['request'] : const [],
          );
          if (mixed) {
            final row = _table(tester).discoveryRows.single;
            row.quantity.text = '12.5';
            row.values['warehouseId'] = 'w1';
          }
          final remark = find.byKey(const Key('warehouse-draw-batch-remark'));
          await tester.enterText(remark, '原批交接备注');
          await _submit(tester);
          final submissions = mixed
              ? tasks.submissions
              : tasks.ordinarySubmissions;
          final original = jsonEncode(submissions.single);
          tasks.failure = ApiException(
            rejection.$2,
            '本次访问被拒绝',
            httpStatus: rejection.$1,
          );
          await _submit(tester);
          expect(_table(tester).issueSaving, isTrue);
          expect(tester.widget<TextField>(remark).readOnly, isTrue);
          // Even an external controller change must not mutate a pending payload.
          tester.widget<TextField>(remark).controller!.text = '不能替换原批';
          if (mixed) _table(tester).discoveryRows.single.quantity.text = '99';
          tasks.failure = null;
          await _submit(tester);
          expect(submissions, hasLength(3));
          expect(submissions.map(jsonEncode), everyElement(original));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final replayed in [0, 1]) {
    testWidgets(
      'ordinary receipt replay explains $replayed issued and one skipped document',
      (tester) async {
        final tasks = _Tasks()
          ..ordinaryResult = WarehouseDrawBatchIssueResult(
            issuedCount: 0,
            skippedCount: 1,
            replayedCount: replayed,
            replayed: true,
            issuedDocNos: const [],
          );
        await _pump(
          tester,
          tasks,
          docs: replayed == 0 ? const ['normal'] : const ['normal', 'second'],
          requests: const [],
        );
        await _submit(tester);
        expect(tasks.ordinaryCalls, 1);
        expect(find.textContaining('1 张领料单此前已出完'), findsOneWidget);
        expect(find.textContaining('未重复出库'), findsOneWidget);
        expect(find.textContaining('已完成(0 张'), findsNothing);
        if (replayed > 0) {
          expect(find.textContaining('此前已出库 1 张'), findsOneWidget);
        }
        expect(find.text('打开批量'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'stock detail keeps the material request number separate from the formal document and legacy source',
    () {
      final detail = StockDocDetail.fromJson({
        'id': 'draw',
        'docType': 'DRAW',
        'billNo': 'SL000001',
        'materialRequestNo': 'LQ000001',
        'sourceDocNo': 'ZX000001',
      });
      expect(detail.billNo, 'SL000001');
      expect(detail.materialRequestNo, 'LQ000001');
      expect(detail.sourceDocNo, 'ZX000001');
      expect(
        StockDocDetail.fromJson({'id': 'legacy'}).materialRequestNo,
        isNull,
      );
    },
  );
  test(
    'discovery rows require exact positive quantities and a physical warehouse',
    () {
      final row = ProductionDrawDiscoveryRow(
        request: _request('r'),
        index: 0,
        initial: _plastic,
      );
      addTearDown(row.dispose);
      for (final input in ['', '0', '-1', 'NaN', '1.00001', '1e3']) {
        row.quantity.text = input;
        expect(row.quantityError, isNotNull, reason: input);
      }
      row.quantity.text = '12.7500';
      expect(row.quantityError, isNull);
      row.values['warehouseId'] = '  ';
      expect(row.warehouseError, isNotNull);
      row.values['warehouseId'] = 'w1';
      expect(row.validationError, isNull);
      expect(row.toJson()['qty'], '12.7500');
    },
  );
  test(
    'normal DRAW quantity guard still uses remaining requested quantity',
    () {
      const item = StockDocItem(
        id: 'line',
        qty: 10,
        requestedQty: 8,
        issuedQty: 3,
      );
      const row = ProductionDrawDetailRow(StockDocDetail(id: 'normal'), item);
      expect(drawIssueQtyError(row, '5'), isNull);
      expect(drawIssueQtyError(row, '5.1'), '不能超过待出库 5.0');
      expect(drawIssueQtyError(row, '0'), '出库数量需大于 0');
    },
  );
  testWidgets(
    'mixed batch reads one shared table without inventing quantity from the parent production plan',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks);
      final shared = _table(tester);
      expect(shared.documents.single.items.single.remainingQty, 5);
      expect(shared.discoveryRows.single.quantity.text, isEmpty);
      final table = tester.widget<MasterDataTableView<ProductionDrawDetailRow>>(
        find.byKey(const Key('production-draw-detail-table')),
      );
      expect(table.items, hasLength(2));
      expect(table.items.last.document, isNull);
      final billNo = table.columns.firstWhere(
        (column) => column.key == 'billNo',
      );
      final requestNo = table.columns.firstWhere(
        (column) => column.key == 'materialRequestNo',
      );
      expect(billNo.value(table.items.first), 'SL-normal');
      expect(requestNo.value(table.items.first), 'LQ-normal-source');
      expect(billNo.value(table.items.last), '—');
      expect(requestNo.value(table.items.last), 'LQ-request');
      expect(find.text('待生成领料单'), findsNothing);
      final qty = tester.widget<TextField>(
        find.byKey(
          ValueKey('draw-discovery-qty-${shared.discoveryRows.single.id}'),
        ),
      );
      expect(qty.decoration!.enabledBorder, isA<OutlineInputBorder>());
      expect(shared.discoveryRows.single.values['warehouseId'], isNull);
      expect(tasks.submissions, isEmpty);
      expect(tasks.ordinaryCalls, 0);
      await _submit(tester);
      expect(tasks.submissions, isEmpty);
      expect(find.textContaining('请填写本次领料数量'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'warehouse fills missing quantity and actual leaf warehouse then submits a single atomic mixed payload',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks);
      final row = _table(tester).discoveryRows.single;
      await tester.enterText(
        find.byKey(ValueKey('draw-discovery-qty-${row.id}')),
        '12.7500',
      );
      await tester.tap(
        find.byKey(ValueKey('draw-discovery-warehouse-${row.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('原料仓二'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('warehouse-draw-batch-remark')),
        '夜班发料',
      );
      await _submit(tester);
      expect(tasks.ordinaryCalls, 0);
      expect(tasks.submissions.single['docIds'], ['normal']);
      expect(tasks.submissions.single['reason'], '夜班发料');
      expect(tasks.submissions.single['discoveries'], [
        {
          'requestId': 'request',
          'expectedVersion': 7,
          'items': [
            {
              'goodsId': 'plastic',
              'colorId': 'white',
              'unitId': 'kg',
              'warehouseId': 'w2',
              'qty': '12.7500',
            },
          ],
        },
      ]);
      expect(find.text('打开批量'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'known requests can issue without any existing DRAW and can split a material across physical warehouses',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks, docs: []);
      final first = _table(tester).discoveryRows.single;
      first.quantity.text = '10';
      first.values.addAll({'warehouseId': 'w1', 'warehouseName': '原料仓一'});
      _table(tester).onSplitDiscoveryRow!(first);
      await tester.pumpAndSettle();
      final second = _table(tester).discoveryRows.last;
      expect(second.quantity.text, isEmpty);
      expect(second.values['warehouseId'], isNull);
      expect(second.values['colorId'], 'white');
      second.quantity.text = '2.5';
      second.values.addAll({'warehouseId': 'w2', 'warehouseName': '原料仓二'});
      await _submit(tester);
      final items =
          ((tasks.submissions.single['discoveries'] as List).single
                  as Map)['items']
              as List;
      expect(items.map((item) => (item as Map)['warehouseId']), ['w1', 'w2']);
      expect(tasks.submissions.single['docIds'], isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'duplicate physical source is blocked and each original material retains at least one row',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks);
      final first = _table(tester).discoveryRows.single;
      expect(_table(tester).canRemoveDiscoveryRow!(first), isFalse);
      _table(tester).onSplitDiscoveryRow!(first);
      await tester.pumpAndSettle();
      for (final row in _table(tester).discoveryRows) {
        row.quantity.text = '2';
        row.values['warehouseId'] = 'w1';
      }
      await _submit(tester);
      expect(tasks.submissions, isEmpty);
      expect(find.textContaining('同材料同仓重复'), findsOneWidget);
      _table(tester).onRemoveDiscoveryRow!(_table(tester).discoveryRows.last);
      await tester.pumpAndSettle();
      expect(_table(tester).discoveryRows, hasLength(1));
      expect(first.quantity.text, '2');
      expect(_table(tester).canRemoveDiscoveryRow!(first), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ambiguous mixed response freezes edits and retries the exact original batch',
    (tester) async {
      final tasks = _Tasks()..failure = NetworkTimeoutException();
      await _pump(tester, tasks);
      final row = _table(tester).discoveryRows.single;
      row.quantity.text = '12.5';
      row.values['warehouseId'] = 'w1';
      await _submit(tester);
      expect(_table(tester).issueSaving, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('warehouse-draw-batch-remark')),
            )
            .readOnly,
        isTrue,
      );
      final first = jsonEncode(tasks.submissions.single);
      row.quantity.text = '99';
      row.values['warehouseId'] = 'w2';
      tasks.failure = null;
      await _submit(tester);
      expect(tasks.submissions, hasLength(2));
      expect(jsonEncode(tasks.submissions.last), first);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit mixed rejection preserves values and corrected intent receives a new key',
    (tester) async {
      final tasks = _Tasks()
        ..failure = ApiException('SHORTAGE', '库存不足', httpStatus: 409);
      await _pump(tester, tasks);
      final row = _table(tester).discoveryRows.single;
      row.quantity.text = '12.5';
      row.values['warehouseId'] = 'w1';
      await _submit(tester);
      expect(_table(tester).issueSaving, isFalse);
      expect(row.quantity.text, '12.5');
      row.quantity.text = '11';
      tasks.failure = null;
      await _submit(tester);
      expect(tasks.submissions[0]['key'], isNot(tasks.submissions[1]['key']));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown or completed material requests cannot be issued through the known-material batch',
    (tester) async {
      final tasks = _Tasks();
      final requests = _DiscoveryRepository()
        ..values['request'] = _request('request', items: []);
      await _pump(tester, tasks, discoveryRepository: requests);
      expect(find.textContaining('尚未确定材料'), findsOneWidget);
      expect(
        find.byKey(const Key('warehouse-draw-batch-confirm')),
        findsNothing,
      );
      expect(tasks.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mixed requests require approve permission while existing approved DRAW remains unchanged',
    (tester) async {
      final tasks = _Tasks();
      await _pump(tester, tasks, approve: false);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('warehouse-draw-batch-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(_table(tester).issueSaving, isTrue);
      expect(tasks.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(760, 900)]) {
    testWidgets('mixed table remains usable with large text at $size', (
      tester,
    ) async {
      await _pump(tester, _Tasks(), size: size, scale: 1.4);
      expect(find.byType(ProductionDrawDetailTable), findsOneWidget);
      expect(
        find.byKey(const Key('warehouse-draw-batch-confirm')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'existing batch weight survives an unknown result and draft reopen',
    (tester) async {
      final storage = _Storage();
      final tasks = _Tasks()..failure = NetworkTimeoutException();
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one'),
        draftGuard: true,
      );
      _table(tester).issueWeights!['item-normal']!.weight.setKg(1.25);
      await _submit(tester);
      final saved = storage.draft;
      final data = saved['data'] as Map;
      expect((data['weights'] as Map)['item-normal'], {
        'kg': 1.25,
        'qtyFromWeight': false,
        'qtyNote': null,
      });
      expect(tasks.ordinarySubmissions.single['weights'], [
        {'itemId': 'item-normal', 'weightKg': 1.25, 'qtyFromWeight': false},
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await _pump(
        tester,
        tasks,
        requests: [],
        storage: storage,
        scope: const AuthenticatedScope(userId: 'one', epoch: 2),
        draftId: saved['id'] as String,
        draftGuard: true,
      );
      expect(_table(tester).issueWeights!['item-normal']!.weight.kg, 1.25);
      expect(_table(tester).issueSaving, isTrue);
      expect(tasks.ordinaryCalls, 1, reason: 'reopening must not submit again');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch weights ride with the request: existing lines in weights, discovery rows in discoveries[].weights',
    (tester) async {
      final tasks = _Tasks()
        ..failure = ApiException('SHORTAGE', '库存不足', httpStatus: 409);
      await _pump(tester, tasks);
      final table = tester.widget<MasterDataTableView<ProductionDrawDetailRow>>(
        find.byKey(const Key('production-draw-detail-table')),
      );
      final keys = table.columns.map((column) => column.key).toList();
      // 批量整单出库: 本次重量紧跟「待出库」, 已出库重量紧跟「已出库」。
      expect(keys.indexOf('issueWeight'), keys.indexOf('remainingQty') + 1);
      expect(keys.indexOf('issuedWeight'), keys.indexOf('issuedQty') + 1);
      expect(table.columns.map((column) => column.label), contains('本次重量(kg)'));

      final row = _table(tester).discoveryRows.single;
      row.quantity.text = '12.5';
      row.values['warehouseId'] = 'w1';
      final existing = _table(tester).issueWeights!['item-normal']!;
      existing.weight.setKg(1.25);
      // 带单位后缀的输入换成千克 (850g -> 0.85 kg)。
      await tester.enterText(
        find.byKey(const ValueKey('weight-cell-input')).last,
        '850g',
      );
      await tester.pump();
      expect(row.weight.kg, 0.85);
      await _submit(tester);
      final first = tasks.submissions.single;
      expect(first['weights'], [
        {'itemId': 'item-normal', 'weightKg': 1.25, 'qtyFromWeight': false},
      ]);
      expect(((first['discoveries'] as List).single as Map)['weights'], [
        {
          'goodsId': 'plastic',
          'colorId': 'white',
          'warehouseId': 'w1',
          'weightKg': 0.85,
          'qtyFromWeight': false,
        },
      ]);
      // 被明确拒绝后只改重量: 另一笔请求, 换新幂等键。
      existing.weight.setKg(1.3);
      tasks.failure = null;
      await _submit(tester);
      expect(tasks.submissions, hasLength(2));
      expect(tasks.submissions[1]['key'], isNot(first['key']));
      expect(
        ((tasks.submissions[1]['weights'] as List).single as Map)['weightKg'],
        1.3,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty discovery quantity is estimated from the weighed amount and marked qtyFromWeight',
    (tester) async {
      final tasks = _Tasks();
      final weights = FakeWeightRepository(
        byGoods: {'plastic': learnedWeightParams('plastic')},
      );
      await _pump(tester, tasks, docs: [], weights: weights);
      expect(weights.requests.single, ['plastic']);
      final row = _table(tester).discoveryRows.single;
      row.values['warehouseId'] = 'w1';
      // Emulate the warehouse picker's scoped refresh; never reuse another
      // physical source's balance when changing the selected warehouse.
      await _table(tester).weightParams!.ensure([row.weight.paramsLine!]);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('weight-cell-input')),
        '2',
      );
      await tester.pump();
      expect(row.quantity.autofilled, isTrue);
      expect(double.parse(row.quantity.text), closeTo(1000, 30));
      expect(row.weight.qtyFromWeight, isTrue);
      await _submit(tester);
      final discovery =
          (tasks.submissions.single['discoveries'] as List).single as Map;
      expect(
        ((discovery['weights'] as List).single as Map)['qtyFromWeight'],
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'mixed repository preserves independent request versions, warehouses and exact decimal input',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'issuedCount': 2,
                    'skippedCount': 0,
                    'replayedCount': 0,
                    'replayed': false,
                    'issuedDocNos': ['LL-1', 'LL-2'],
                  },
                ),
              );
            },
          ),
        );
      const discoveries = [
        {
          'requestId': 'r',
          'expectedVersion': 7,
          'items': [
            {
              'goodsId': 'plastic',
              'colorId': 'white',
              'unitId': 'kg',
              'warehouseId': 'w1',
              'qty': '12.7500',
            },
          ],
        },
      ];
      final result = await ProductionDrawTaskRepository(ApiClient(dio))
          .issueDiscoveryBatch(
            idempotencyKey: 'key',
            docIds: ['normal'],
            discoveries: discoveries,
            reason: '发料',
          );
      expect(requests.single.path, '/stock/docs/issue-discovery-batch');
      expect(requests.single.data, {
        'idempotencyKey': 'key',
        'docIds': ['normal'],
        'discoveries': discoveries,
        'reason': '发料',
      });
      expect(result.issuedCount, 2);
    },
  );
}
