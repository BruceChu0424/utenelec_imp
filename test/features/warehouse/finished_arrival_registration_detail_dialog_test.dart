import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_physical_detail_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

const _registrationA = '10000000-0000-0000-0000-000000000001';
const _registrationB = '10000000-0000-0000-0000-000000000002';
const _report = 'report-with-registered-A-and-pending-B';
const _serverUrl = 'https://warehouse.test/api';
const _scope = WarehouseTaskScope.warehouse('warehouse-a');
const _nativePermissions = {Perm.stockDocView, Perm.stockDocApprove};
final _actor = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'keeper-a'),
);
final _server = StateProvider<String>((ref) => _serverUrl);
final _warehouse = StateProvider<WarehouseTaskScope>((ref) => _scope);
final _permissions = StateProvider<Set<String>>((ref) => _nativePermissions);

Map<String, dynamic> _rowJson() => {
  'rowKey':
      'FINISHED:FINISHED_REGISTRATION:$_registrationA:registration-item-a',
  'id': _registrationA,
  'sourceType': 'FINISHED',
  'recordType': 'FINISHED_REGISTRATION',
  'status': 'FINISHED_WAITING_FQC',
  'statusLabel': '已登记 A · 等待品质',
  'billNo': 'REPORT-SAME',
  'sourceDocNo': 'FQC-A',
  'warehouseName': '原登记仓',
  'lineCount': 1,
  'action': 'FINISHED_ARRIVAL_DETAIL',
  'targetId': _registrationA,
  'canHandle': true,
  'actionData': {
    'registrationId': _registrationA,
    'registrationItemId': 'registration-item-a',
    'sourceReportItemId': 'report-item-a',
    'reportId': _report,
    'reversible': true,
  },
  'line': {'key': 'registration-item-a', 'itemId': 'registration-item-a'},
};

Map<String, dynamic> _detail() => {
  'row': _rowJson(),
  'total': 1,
  'page': 1,
  'totalPages': 1,
  'items': <Map<String, dynamic>>[
    {
      'id': 'registration-item-a',
      'registrationId': _registrationA,
      'sourceReportItemId': 'report-item-a',
      'lotId': 'lot-a',
      'goodsCode': 'REGISTERED-A',
      'goodsName': '已登记 A 实物',
      'quantity': 3,
    },
  ],
};

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: _serverUrl)));
  Map<String, dynamic> detail = _detail();
  Completer<Map<String, dynamic>>? pendingDetail;
  Object? firstPostError;
  Object? captureError;
  Map<String, dynamic>? postResponse;
  final reads = <String>[];
  final queries = <Map<String, dynamic>>[];
  final posts = <({String path, Map<String, dynamic> body})>[];

  @override
  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) async {
    if (captureError case final error?) throw error;
    return super.captureRequestScope(isCurrent: isCurrent);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (!path.startsWith('/warehouse/task-center/inbound/')) return {};
    queries.add({...?query});
    return pendingDetail?.future ?? Future.value(detail);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    // The same report really has another pending lot. A report-level read
    // would expose it, but registration history must never make this request.
    return [
      {
        'reportId': _report,
        'registered': false,
        'lots': [
          {
            'lotId': 'unselected-lot-b',
            'goodsName': '未选 B 实物',
            'reportedQty': 7,
          },
        ],
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((path: path, body: Map<String, dynamic>.from(body! as Map)));
    final error = firstPostError;
    firstPostError = null;
    if (error != null) throw error;
    return postResponse ??
        {
          'registrationId': _registrationA,
          'registered': true,
          'reportId': _report,
          'reportNo': 'REPORT-SAME',
          'reportDate': '2026-10-21',
          'reversedAt': '2026-10-21T10:30:00Z',
          'reversible': false,
          'lots': <Map<String, dynamic>>[],
          'batches': <Map<String, dynamic>>[],
        };
  }
}

class _Harness {
  _Harness({
    this.allow = true,
    this.initialPermissions = _nativePermissions,
    WarehouseTaskCenterRecord? row,
  }) : row = row ?? WarehouseTaskCenterRecord.fromJson(_rowJson());
  final bool allow;
  final Set<String> initialPermissions;
  final WarehouseTaskCenterRecord row;
  final api = _Api();
  bool? changed;

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          _permissions.overrideWith((ref) => initialPermissions),
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(_actor)),
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
          warehouseTaskScopeProvider.overrideWith(
            (ref) => ref.watch(_warehouse),
          ),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(_permissions),
          ),
          isSuperAdminProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  changed = await showWarehouseTaskPhysicalDetailDialog(
                    context,
                    row: row,
                    warehouseScope: _scope,
                    allowFinishedRegistrationReversal: allow,
                  );
                },
                child: const Text('打开登记 A'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开登记 A'));
    await tester.pump();
    if (api.pendingDetail == null) await tester.pumpAndSettle();
  }

  ProviderContainer container(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(WarehouseTaskPhysicalDetailDialog)),
  );

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const Key('finished-registration-detail-reverse')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('production-finished-arrival-reverse-reason')),
      '原登记仓库选择错误',
    );
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-reverse-confirm')),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'registered A opens only its exact detail and reverses A without pending sibling B',
    (tester) async {
      final harness = _Harness();
      await harness.open(tester);
      expect(harness.api.reads.where((path) => path.startsWith('/warehouse/')), [
        '/warehouse/task-center/inbound/FINISHED%3AFINISHED_REGISTRATION%3A$_registrationA/detail',
      ]);
      expect(harness.api.queries.single['scopeWarehouseId'], 'warehouse-a');
      expect(find.text('已登记 A 实物'), findsOneWidget);
      expect(find.textContaining('未选 B'), findsNothing);
      expect(find.text('登记并送检'), findsNothing);
      await harness.confirm(tester);
      expect(harness.changed, isTrue);
      expect(
        harness.api.posts.single.path,
        '/warehouse/production-finished-in/arrival-registrations/$_registrationA/reverse',
      );
      expect(harness.api.posts.single.body['reason'], '原登记仓库选择错误');
      expect(harness.api.posts.single.body.keys, {'reason', 'idempotencyKey'});
      expect(
        harness.api.reads.any(
          (path) => path.contains('arrival-registrations/batch'),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'default historical dialog remains read-only even with native approval',
    (tester) async {
      final harness = _Harness(allow: false);
      await harness.open(tester);
      expect(find.text('撤回本登记批'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(harness.changed, isFalse);
      expect(harness.api.posts, isEmpty);
    },
  );

  testWidgets('reason cancellation performs no mutation', (tester) async {
    final harness = _Harness();
    final items = harness.api.detail['items'] as List<Object?>;
    items.add({
      ...items.first! as Map<String, dynamic>,
      'id': 'registration-item-a2',
      'sourceReportItemId': 'report-item-a2',
      'lotId': 'lot-a2',
      'goodsName': '已登记 A 第二行',
    });
    harness.api.detail['total'] = 2;
    await harness.open(tester);
    await tester.tap(find.text('撤回本登记批'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('撤回整个原登记批（包含当前未显示的明细），当前可见 2 行'),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(harness.api.posts, isEmpty);
    expect(find.text('已登记 A 实物'), findsOneWidget);
    expect(harness.changed, isNull);
  });

  for (final invalid in [
    'missing-row',
    'other-registration',
    'wrong-type',
    'missing-identity',
    'missing-report-identity',
    'foreign-line',
    'not-handleable',
    'not-reversible',
  ]) {
    testWidgets('$invalid cannot grant a reversal or fall back to the report', (
      tester,
    ) async {
      final harness = _Harness();
      final data = harness.api.detail;
      final row = data['row'] as Map<String, dynamic>;
      final action = row['actionData'] as Map<String, dynamic>;
      switch (invalid) {
        case 'missing-row':
          data.remove('row');
        case 'other-registration':
          row['id'] = _registrationB;
        case 'wrong-type':
          row['recordType'] = 'FINISHED_REGISTER';
        case 'missing-identity':
          action.remove('registrationId');
        case 'missing-report-identity':
          action.remove('reportId');
        case 'foreign-line':
          final items = data['items'] as List<Object?>;
          final line = items.first! as Map<String, dynamic>;
          line['registrationId'] = _registrationB;
        case 'not-handleable':
          row['canHandle'] = false;
        case 'not-reversible':
          action['reversible'] = false;
      }
      await harness.open(tester);
      expect(find.text('撤回本登记批'), findsNothing);
      expect(harness.api.posts, isEmpty);
      expect(
        harness.api.reads.where((path) => path.startsWith('/warehouse/')),
        hasLength(1),
      );
      expect(find.textContaining('未选 B'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a superadmin flag cannot replace the native stock approval permission',
    (tester) async {
      final harness = _Harness(initialPermissions: {Perm.stockDocView});
      await harness.open(tester);
      expect(find.text('撤回本登记批'), findsNothing);
      expect(harness.api.posts, isEmpty);
    },
  );

  for (final phase in ['loading', 'confirmation']) {
    for (final change in ['actor', 'server', 'warehouse', 'permissions']) {
      testWidgets(
        '$change change during $phase permanently invalidates the operation',
        (tester) async {
          final harness = _Harness();
          final pending = Completer<Map<String, dynamic>>();
          if (phase == 'loading') harness.api.pendingDetail = pending;
          await harness.open(tester);
          final container = harness.container(tester);
          if (phase == 'confirmation') {
            await tester.tap(find.text('撤回本登记批'));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(
                const Key('production-finished-arrival-reverse-reason'),
              ),
              '核对原登记',
            );
          }
          switch (change) {
            case 'actor':
              container.read(_actor.notifier).state = const AuthenticatedScope(
                userId: 'keeper-b',
              );
            case 'server':
              container.read(_server.notifier).state = 'https://other.test/api';
            case 'warehouse':
              container.read(_warehouse.notifier).state =
                  const WarehouseTaskScope.warehouse('warehouse-b');
            case 'permissions':
              container.read(_permissions.notifier).state = {Perm.stockDocView};
          }
          await tester.pump();
          if (phase == 'loading') {
            pending.complete(harness.api.detail);
          } else {
            await tester.tap(
              find.byKey(
                const Key('production-finished-arrival-reverse-confirm'),
              ),
            );
          }
          await tester.pumpAndSettle();
          expect(harness.api.posts, isEmpty);
          expect(find.text('已登记 A 实物'), findsNothing);
          expect(find.textContaining('已变化'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'a capture failure sends nothing and does not claim a retained unknown request',
    (tester) async {
      final harness = _Harness();
      harness.api.captureError = AuthenticatedRequestScope.unavailable();
      await harness.open(tester);
      await tester.tap(find.text('撤回本登记批'));
      await tester.pumpAndSettle();
      expect(harness.api.posts, isEmpty);
      expect(find.textContaining('尚未发送撤回请求'), findsOneWidget);
      expect(find.textContaining('原原因和请求标识已保留'), findsNothing);
      expect(find.text('使用原请求恢复结果'), findsNothing);
      expect(
        find.byKey(const Key('production-finished-arrival-reverse-reason')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'an uncertain result retains reason and key and only manually replays the same request',
    (tester) async {
      final harness = _Harness();
      harness.api.firstPostError = NetworkTimeoutException();
      await harness.open(tester);
      await harness.confirm(tester);
      expect(harness.changed, isNull);
      expect(harness.api.posts, hasLength(1));
      expect(find.textContaining('原撤回原因：原登记仓库选择错误'), findsOneWidget);
      expect(find.text('使用原请求恢复结果'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(
        harness.api.posts,
        hasLength(1),
        reason: 'No automatic write retry',
      );
      await tester.tap(find.text('使用原请求恢复结果'));
      await tester.pumpAndSettle();
      expect(harness.api.posts, hasLength(2));
      expect(harness.api.posts.last.path, harness.api.posts.first.path);
      expect(harness.api.posts.last.body, harness.api.posts.first.body);
      expect(harness.changed, isTrue);
    },
  );

  testWidgets(
    'a mismatched response is uncertain and never reported as success',
    (tester) async {
      final harness = _Harness();
      harness.api.postResponse = {
        'registrationId': _registrationB,
        'reversedAt': '2026-10-21T10:30:00Z',
      };
      await harness.open(tester);
      await harness.confirm(tester);
      expect(harness.changed, isNull);
      expect(harness.api.posts, hasLength(1));
      expect(find.text('使用原请求恢复结果'), findsOneWidget);
      final notices = harness.container(tester).read(appNotificationProvider);
      expect(
        notices.where((notice) => notice.kind == AppNotificationKind.success),
        isEmpty,
      );
    },
  );
}
