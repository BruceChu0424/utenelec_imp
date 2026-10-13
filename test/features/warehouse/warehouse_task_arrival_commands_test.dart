import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_task_center_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_records_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

import '../../helpers/badge_summary_fixture.dart';
import 'warehouse_task_records_view_test.dart';

const _baseUrl = 'https://unit.test/api';
final _actor = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'warehouse-a'),
);
final _server = StateProvider<String>((_) => _baseUrl);
final _warehouse = StateProvider<WarehouseTaskScope>(
  (_) => const WarehouseTaskScope.warehouse('warehouse-a'),
);
final _permissions = StateProvider<Set<String>>(
  (_) => {Perm.warehouseInboundView, Perm.warehouseInboundStockIn},
);

class _Post {
  _Post(this.path, this.body, this.identity);
  final String path;
  final Map<String, dynamic> body;
  final AuthenticatedRequestIdentity identity;
}

/// Token bootstrap keeps the production token record implementation. This
/// fixture has no concurrent impersonation writes, so its actual raw read can
/// avoid the process-wide write queue crossing separate FakeAsync test zones.
class _TestSecureStorage extends SecureStorage {
  _TestSecureStorage(this.rawStorage) : super(rawStorage);
  final FlutterSecureStorage rawStorage;

  @override
  Future<ImpersonationRecord?> getImpersonationRecord() async =>
      ImpersonationRecord.tryParse(
        await rawStorage.read(key: 'auth.impersonation_record.v1'),
      );
}

/// Keep the real repository, request scope, storage records and response parser.
/// Only the HTTP boundary is replaced, and it verifies the retained binding
/// before recording a command as sent.
class _Api extends ApiClient {
  _Api(this.storage, {this.loseFirstExceptionResponse = false}) : super(Dio());
  final SecureStorage storage;
  final bool loseFirstExceptionResponse;
  final posts = <_Post>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.authMe) {
      return const {
        'session': {
          'delegableSurfaceKeys': <String>[],
          'documentScopes': <String, dynamic>{},
          'preferences': <String, Object?>{},
        },
      };
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final options = RequestOptions(path: path, baseUrl: _baseUrl, data: body);
    final scope = AuthenticatedRequestScope.attach(options);
    expect(
      scope,
      isNotNull,
      reason: 'Direct commands must retain the captured credential scope',
    );
    await scope!.verify();
    scope.checkEndpoint(options);
    final tokens = await storage.getAuthTokenSnapshot();
    expect(tokens.hasTokens, isTrue);
    expect(scope.identity.lineage, tokens.sessionLineage);
    expect(scope.identity.intent, tokens.intentGeneration);
    posts.add(
      _Post(
        path,
        Map<String, dynamic>.from(body! as Map<String, dynamic>),
        scope.identity,
      ),
    );
    if (path == ApiEndpoints.warehouseArrivalExceptionBatchStockIn) {
      if (loseFirstExceptionResponse && posts.length == 1) {
        throw NetworkTimeoutException();
      }
      return {'processedCount': 2, 'replay': loseFirstExceptionResponse};
    }
    expect(path, ApiEndpoints.warehouseInboundArrivalBatchComplete);
    return const {
      'processedCount': 2,
      'items': <Map<String, dynamic>>[
        {
          'receiptId': 'receipt-a',
          'outcome': 'SUBMITTED_FOR_INSPECTION',
          'alreadyCompleted': true,
        },
        {'receiptId': 'receipt-b', 'outcome': 'EXCESS_QUARANTINED'},
      ],
    };
  }
}

class _Drafts extends FormDraftsNotifier {
  @override
  List<FormDraft> build() => const [];
}

// The test has an already authenticated session; it must not start a parallel
// cold-login restore against the deliberately physical-only fake HTTP API.
class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: ref.watch(_actor)?.userId ?? 'warehouse-a',
      code: 'WH',
      name: '测试仓管',
    ),
  );
}

class _Harness {
  _Harness(this.container, this.api);
  final ProviderContainer container;
  final _Api api;
}

WarehouseTaskCenterRecord _continue() => warehouseTestRecord(
  source: 'PURCHASE',
  record: 'EXPECTATION',
  id: 'expectation-original',
  billNo: 'ARRIVAL-ORIGINAL',
  status: 'PURCHASE_ARRIVAL_CONTINUE',
  action: 'ARRIVAL_CONTINUE',
  canHandle: true,
  data: {
    'draftReceiptIds': ['receipt-b', 'receipt-a'],
  },
);

List<WarehouseTaskCenterRecord> _exceptions() => [
  for (var index = 1; index <= 2; index++)
    warehouseTestRecord(
      source: 'PURCHASE',
      record: 'ARRIVAL_EXCEPTION',
      id: 'exception-$index',
      billNo: 'EXCEPTION-$index',
      status: 'PURCHASE_EXCEPTION_APPROVED',
      action: 'ARRIVAL_EXCEPTION',
      canHandle: true,
      data: {'expectedVersion': index + 4, 'acceptedQty': 12},
    ),
];

Future<_Harness> _pump(
  WidgetTester tester,
  List<WarehouseTaskCenterRecord> rows, {
  bool loseFirstExceptionResponse = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  late _TestSecureStorage storage;
  await tester.runAsync(() async {
    storage = _TestSecureStorage(const FlutterSecureStorage());
    await storage.saveTokens(
      accessToken: 'fixture-access',
      refreshToken: 'fixture-refresh',
    );
  });
  final api = _Api(
    storage,
    loseFirstExceptionResponse: loseFirstExceptionResponse,
  );
  final preferences = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      secureStorageProvider.overrideWithValue(storage),
      sessionProvider.overrideWith(_Session.new),
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_actor)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      warehouseTaskScopeProvider.overrideWith((ref) => ref.watch(_warehouse)),
      warehouseTaskCenterRepositoryProvider.overrideWithValue(
        WarehouseTaskRecordsFakeGateway(rows),
      ),
      isSuperAdminProvider.overrideWithValue(false),
      formDraftsProvider.overrideWith(_Drafts.new),
      sharedPreferencesProvider.overrideWithValue(preferences),
      fixedBadgeSummaryOverride(badgeSummaryFixture()),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/commands',
    routes: [
      GoRoute(
        path: '/commands',
        builder: (_, _) => Consumer(
          builder: (context, ref, _) => Scaffold(
            body: WarehouseListScope(
              scope: ref.watch(warehouseTaskScopeProvider),
              child: const WarehouseTaskRecordsView(
                direction: WarehouseTaskDirection.inbound,
                source: 'PURCHASE',
                sources: warehouseTestInboundSources,
              ),
            ),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container, api);
}

MasterDataTableView<WarehouseTaskCenterRecord> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<WarehouseTaskCenterRecord>));

Future<void> _openConfirmation(
  WidgetTester tester,
  List<WarehouseTaskCenterRecord> rows,
) async {
  if (rows.singleOrNull?.action == 'ARRIVAL_CONTINUE') {
    await tester.tap(find.text('ARRIVAL-ORIGINAL'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('ARRIVAL-ORIGINAL'));
  } else {
    _table(tester).onSelectedIdsChanged!({for (final row in rows) row.rowKey});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('warehouse-task-record-batch')));
  }
  await tester.pumpAndSettle();
  expect(find.widgetWithText(FilledButton, '确认处理'), findsOneWidget);
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '确认处理'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('继续送检按全部原收货单批量提交，展示实际办理数与隔离及已处理反馈', (tester) async {
    final rows = [_continue()];
    final harness = await _pump(tester, rows);
    await _openConfirmation(tester, rows);
    expect(find.textContaining('2 张原收货单'), findsOneWidget);
    expect(harness.api.posts, isEmpty);
    await _confirm(tester);
    final command = harness.api.posts.single;
    expect(command.path, ApiEndpoints.warehouseInboundArrivalBatchComplete);
    expect(command.body['receiptIds'], ['receipt-a', 'receipt-b']);
    expect(command.body['idempotencyKey'], isNotEmpty);
    expect(command.identity.lineage, isNotEmpty);
    final feedback = harness.container.read(appNotificationProvider).last;
    expect(feedback.kind, AppNotificationKind.warning);
    expect(feedback.message, contains('已处理 2 张原收货单'));
    expect(feedback.message, contains('1 张此前已处理'));
    expect(feedback.message, contains('1 张超量隔离待审核'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('异常批量携带每条版本，响应丢失重试沿用同幂等键并展示replay办理数', (tester) async {
    final rows = _exceptions();
    final harness = await _pump(tester, rows, loseFirstExceptionResponse: true);
    await _openConfirmation(tester, rows);
    await _confirm(tester);
    expect(harness.api.posts, hasLength(1));
    expect(
      harness.container.read(appNotificationProvider).last.kind,
      AppNotificationKind.error,
    );
    await _openConfirmation(tester, rows);
    await _confirm(tester);
    expect(harness.api.posts, hasLength(2));
    final first = harness.api.posts.first;
    final retry = harness.api.posts.last;
    expect(first.path, ApiEndpoints.warehouseArrivalExceptionBatchStockIn);
    expect(first.body['items'], [
      {'exceptionId': 'exception-1', 'expectedVersion': 5},
      {'exceptionId': 'exception-2', 'expectedVersion': 6},
    ]);
    expect(first.body['idempotencyKey'], isNotEmpty);
    expect(retry.body, first.body);
    expect(retry.identity, first.identity);
    final feedback = harness.container.read(appNotificationProvider).last;
    expect(feedback.kind, AppNotificationKind.success);
    expect(feedback.message, contains('这批 2 条异常此前已办理'));
    expect(feedback.message, contains('没有重复处理'));
    expect(tester.takeException(), isNull);
  });

  for (final action in ['ARRIVAL_CONTINUE', 'ARRIVAL_EXCEPTION']) {
    for (final change in ['actor', 'server', 'warehouse', 'permissions']) {
      testWidgets('$action 确认框打开后 $change 变化不能发送POST', (tester) async {
        final rows = action == 'ARRIVAL_CONTINUE'
            ? [_continue()]
            : _exceptions();
        final harness = await _pump(tester, rows);
        await _openConfirmation(tester, rows);
        switch (change) {
          case 'actor':
            harness.container.read(_actor.notifier).state =
                const AuthenticatedScope(userId: 'warehouse-b');
          case 'server':
            harness.container.read(_server.notifier).state =
                'https://other.test/api';
          case 'warehouse':
            harness.container.read(_warehouse.notifier).state =
                const WarehouseTaskScope.warehouse('warehouse-b');
          case 'permissions':
            harness.container.read(_permissions.notifier).state = {
              Perm.warehouseInboundView,
            };
        }
        await tester.pumpAndSettle();
        await _confirm(tester);
        expect(harness.api.posts, isEmpty);
        expect(
          harness.container
              .read(appNotificationProvider)
              .where((notice) => notice.kind == AppNotificationKind.success),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
