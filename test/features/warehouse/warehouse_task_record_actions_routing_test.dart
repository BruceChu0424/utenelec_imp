import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_record_actions.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_physical_detail_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

const _source =
    '/warehouse/tasks?kind=inbound&source=FINISHED'
    '&status=FINISHED_REGISTER&warehouseId=warehouse-original&page=3'
    '&returnTo=%2Fwarehouse';

enum _Mount { page, imperative, dialog }

WarehouseTaskCenterRecord _record({
  String action = 'FINISHED_REGISTER',
  String id = 'projection-id',
  String reportId = 'report-original',
  String? lotId,
  bool physical = false,
  bool canHandle = true,
}) => WarehouseTaskCenterRecord(
  rowKey:
      'FINISHED:${action == 'FINISHED_ARRIVAL_DETAIL' ? 'REGISTRATION' : 'REPORT'}:$id',
  id: id,
  targetId: action == 'FINISHED_ARRIVAL_DETAIL' ? id : 'target-$id',
  sourceType: 'FINISHED',
  recordType: action == 'FINISHED_ARRIVAL_DETAIL'
      ? 'FINISHED_REGISTRATION'
      : 'PRODUCTION_REPORT',
  status: 'FINISHED_REGISTER',
  statusLabel: '待登记',
  action: action,
  canHandle: canHandle,
  actionData: {
    'reportId': reportId,
    if (action == 'FINISHED_ARRIVAL_DETAIL') 'registrationId': id,
    'lotId': ?lotId,
    if (physical) 'sourceReportItemId': 'item-$id',
  },
  line: physical
      ? WarehouseTaskLine(key: 'item-$id', itemId: 'item-$id')
      : null,
);

class _PhysicalDetailApi extends ApiClient {
  _PhysicalDetailApi(this.row) : super(Dio());

  final WarehouseTaskCenterRecord row;
  final calls = <({String path, Map<String, dynamic> query})>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.startsWith('/warehouse/task-center/')) return {};
    calls.add((path: path, query: {...?query}));
    return {
      'row': {
        'rowKey': row.rowKey,
        'id': row.id,
        'targetId': row.targetId,
        'sourceType': row.sourceType,
        'recordType': row.recordType,
        'status': row.status,
        'statusLabel': row.statusLabel,
        'action': row.action,
        'canHandle': false,
        'actionData': row.actionData,
      },
      'lines': [
        {
          'registrationId': row.id,
          'goodsCode': 'REGISTERED-ONLY',
          'quantity': 3,
        },
      ],
      'page': 1,
      'totalPages': 1,
      'total': 1,
    };
  }
}

class _ActionButton extends ConsumerStatefulWidget {
  const _ActionButton({
    required this.rows,
    required this.errors,
    required this.onMount,
    this.batch = false,
    this.preStock,
  });

  final List<WarehouseTaskCenterRecord> rows;
  final List<Object> errors;
  final VoidCallback onMount;
  final bool batch;
  final bool? preStock;

  @override
  ConsumerState<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends ConsumerState<_ActionButton> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => FilledButton(
    key: const Key('open-record'),
    onPressed: () {
      final future = widget.batch
          ? openWarehouseTaskRecordBatch(
              context,
              ref,
              widget.rows,
              preStock: widget.preStock,
            )
          : openWarehouseTaskRecord(context, ref, widget.rows.single);
      future.catchError((Object error) => widget.errors.add(error));
    },
    child: const Text('打开原报工'),
  );
}

class _RouterHarness {
  _RouterHarness({
    required this.rows,
    this.mount = _Mount.page,
    this.batch = false,
    this.preStock,
  }) {
    detailApi = _PhysicalDetailApi(rows.first);
    router = GoRouter(
      initialLocation: _source,
      redirect: (_, state) =>
          employeePermissionRedirect(user, state.matchedLocation),
      routes: [
        GoRoute(
          path: RouteName.warehouseTasks,
          builder: (context, _) => Scaffold(
            body: mount == _Mount.page
                ? actionButton()
                : FilledButton(
                    key: const Key('mount-child'),
                    onPressed: () {
                      if (mount == _Mount.dialog) {
                        showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(content: actionButton()),
                        );
                      } else {
                        Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => Scaffold(body: actionButton()),
                          ),
                        );
                      }
                    },
                    child: const Text('打开任务操作'),
                  ),
          ),
        ),
        GoRoute(
          path: RouteName.warehouseProductionFinishedArrivalRegistration,
          builder: (context, state) {
            arrivals.add(state.uri);
            return Scaffold(
              body: FilledButton(
                key: const Key('return-to-source'),
                onPressed: () =>
                    backTo(context, defaultPath: RouteName.warehouseTasks),
                child: const Text('返回原中心'),
              ),
            );
          },
        ),
        GoRoute(
          path: RouteName.accessDenied,
          builder: (_, _) => const Scaffold(body: Text('permission-denied')),
        ),
      ],
    );
  }

  final List<WarehouseTaskCenterRecord> rows;
  final _Mount mount;
  final bool batch;
  final bool? preStock;
  final errors = <Object>[];
  final arrivals = <Uri>[];
  int actionMounts = 0;
  AppUser user = const AppUser(
    id: 'warehouse-actor',
    code: 'warehouse-actor',
    name: '仓管',
    permissions: [Perm.stockDocView],
  );
  late final GoRouter router;
  late final _PhysicalDetailApi detailApi;

  Widget actionButton() => WarehouseListScope(
    scope: const WarehouseTaskScope.warehouse('warehouse-original'),
    child: _ActionButton(
      rows: rows,
      errors: errors,
      onMount: () => actionMounts++,
      batch: batch,
      preStock: preStock,
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(detailApi),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'warehouse-actor'),
          ),
          currentPermissionsProvider.overrideWithValue({Perm.stockDocView}),
          warehouseTaskScopeProvider.overrideWithValue(
            const WarehouseTaskScope.warehouse('warehouse-original'),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (mount != _Mount.page) {
      await tester.tap(find.byKey(const Key('mount-child')));
      await tester.pumpAndSettle();
    }
  }
}

void main() {
  for (final actionAndPath in <(String, String)>[
    ('PRODUCTION_DRAW', RouteName.warehouseProductionDrawBatchIssue),
    ('SUBCONTRACT_OUTBOUND', '/warehouse/subcontract-outbound/batch'),
    ('SALES_OUTBOUND', '/warehouse/sales-outbound/batch'),
    ('RETURN_RECEIVE', '/warehouse/material-returns/batch-receive'),
  ]) {
    testWidgets(
      '${actionAndPath.$1} keeps both physical identities from one source',
      (tester) async {
        final captured = <Uri>[];
        final errors = <Object>[];
        final rows = [
          for (final id in ['first', 'second'])
            WarehouseTaskCenterRecord(
              rowKey: '${actionAndPath.$1}:doc:$id',
              id: 'doc',
              targetId: 'doc',
              sourceType: 'TEST',
              recordType: 'DOCUMENT',
              status: 'PENDING',
              statusLabel: '待办',
              action: actionAndPath.$1,
              canHandle: true,
              actionData: const {'documentId': 'doc'},
              line: WarehouseTaskLine(key: id, itemId: id),
            ),
        ];
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(
                body: _ActionButton(
                  rows: rows,
                  errors: errors,
                  onMount: () {},
                  batch: true,
                ),
              ),
            ),
            GoRoute(
              path: actionAndPath.$2,
              builder: (_, state) {
                captured.add(state.uri);
                return const Scaffold(body: Text('已进入所选范围'));
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open-record')));
        await tester.pumpAndSettle();
        expect(errors, isEmpty);
        expect(captured.single.queryParameters['itemIds'], 'first,second');
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final mount in _Mount.values) {
    testWidgets(
      'physical finished row from ${mount.name} retains only its selected lot',
      (tester) async {
        final harness = _RouterHarness(
          rows: [_record(physical: true, lotId: 'lot-selected')],
          mount: mount,
        );
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('open-record')));
        await tester.pumpAndSettle();

        expect(harness.errors, isEmpty);
        expect(harness.arrivals.last.queryParameters, {
          'reportIds': 'report-original',
          'lotIds': 'lot-selected',
          'returnTo': _source,
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final batch in [false, true]) {
    testWidgets(
      'physical finished row without a lot cannot open with batch=$batch',
      (tester) async {
        final harness = _RouterHarness(
          rows: [_record(physical: true)],
          batch: batch,
        );
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('open-record')));
        await tester.pumpAndSettle();

        expect(harness.arrivals, isEmpty);
        expect(harness.router.state.uri.toString(), _source);
        expect(harness.errors, isEmpty);
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('open-record'))),
        );
        final notice = container.read(appNotificationProvider).single;
        expect(notice.kind, AppNotificationKind.warning);
        expect(notice.message, '所选任务已变化，请刷新后重新选择');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final physical in [false, true]) {
    testWidgets(
      'finished batch cannot mix scoped and unscoped rows with physical=$physical',
      (tester) async {
        final harness = _RouterHarness(
          rows: [
            _record(id: 'selected', physical: true, lotId: 'lot-selected'),
            _record(id: 'missing-lot', physical: physical),
          ],
          batch: true,
          mount: _Mount.imperative,
        );
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('open-record')));
        await tester.pumpAndSettle();

        expect(harness.arrivals, isEmpty);
        expect(harness.router.state.uri.toString(), _source);
        expect(harness.errors, isEmpty);
        final container = ProviderScope.containerOf(
          tester.element(find.byKey(const Key('open-record'))),
        );
        final notice = container.read(appNotificationProvider).single;
        expect(notice.kind, AppNotificationKind.warning);
        expect(notice.message, '所选任务已变化，请刷新后重新选择');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final action in ['FINISHED_REGISTER']) {
    for (final mount in _Mount.values) {
      testWidgets(
        '$action from ${mount.name} retains original report and center query',
        (tester) async {
          final harness = _RouterHarness(
            rows: [
              _record(action: action, canHandle: action == 'FINISHED_REGISTER'),
            ],
            mount: mount,
          );
          await harness.pump(tester);
          await tester.tap(find.byKey(const Key('open-record')));
          await tester.pumpAndSettle();

          expect(harness.errors, isEmpty);
          expect(harness.arrivals, isNotEmpty);
          final location = harness.arrivals.last;
          expect(
            location.path,
            RouteName.warehouseProductionFinishedArrivalRegistration,
          );
          expect(location.queryParameters['reportIds'], 'report-original');
          expect(location.queryParameters['returnTo'], _source);
          expect(location.queryParameters.containsKey('preStock'), isFalse);
          expect(harness.actionMounts, 1);
          expect(tester.takeException(), isNull);

          await tester.tap(find.byKey(const Key('return-to-source')));
          await tester.pumpAndSettle();
          expect(harness.router.state.uri.toString(), _source);
          expect(harness.actionMounts, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final mount in _Mount.values) {
    testWidgets(
      'registered arrival detail from ${mount.name} reads only its exact batch and preserves the source',
      (tester) async {
        final harness = _RouterHarness(
          rows: [_record(action: 'FINISHED_ARRIVAL_DETAIL', canHandle: false)],
          mount: mount,
        );
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('open-record')));
        await tester.pumpAndSettle();

        expect(harness.errors, isEmpty);
        expect(harness.arrivals, isEmpty);
        expect(harness.router.state.uri.toString(), _source);
        expect(
          harness.detailApi.calls.single.path,
          '/warehouse/task-center/inbound/FINISHED%3AFINISHED_REGISTRATION%3Aprojection-id/detail',
        );
        expect(harness.detailApi.calls.single.query, {
          'scopeWarehouseId': 'warehouse-original',
          'linePage': 1,
          'lineSize': 100,
        });
        expect(find.text('REGISTERED-ONLY'), findsOneWidget);
        expect(find.text('撤回本登记批'), findsNothing);
        expect(harness.actionMounts, 1);

        final dialog = find.byType(WarehouseTaskPhysicalDetailDialog);
        await tester.tap(
          find.descendant(of: dialog, matching: find.text('关闭')),
        );
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(harness.router.state.uri.toString(), _source);
        expect(harness.actionMounts, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final preStock in [false, true]) {
    testWidgets(
      'batch from imperative page preserves sources and preStock=$preStock',
      (tester) async {
        final harness = _RouterHarness(
          rows: [
            _record(id: 'row-b', reportId: 'report-b'),
            _record(id: 'row-a', reportId: 'report-a'),
            _record(id: 'row-a2', reportId: 'report-a'),
          ],
          mount: _Mount.imperative,
          batch: true,
          preStock: preStock,
        );
        await harness.pump(tester);
        await tester.tap(find.byKey(const Key('open-record')));
        await tester.pumpAndSettle();

        expect(harness.errors, isEmpty);
        expect(harness.arrivals.last.queryParameters, {
          'reportIds': 'report-a,report-b',
          'preStock': preStock ? '1' : '0',
          'returnTo': _source,
        });
        expect(harness.actionMounts, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final mount in [_Mount.imperative, _Mount.dialog]) {
    testWidgets('revoked view permission denies target from ${mount.name}', (
      tester,
    ) async {
      final harness = _RouterHarness(rows: [_record()], mount: mount);
      await harness.pump(tester);
      harness.user = const AppUser(
        id: 'replacement-actor',
        code: 'replacement-actor',
        name: '另一个当前用户',
        permissions: [Perm.warehouseInboundView],
      );
      await tester.tap(find.byKey(const Key('open-record')));
      await tester.pumpAndSettle();

      expect(harness.arrivals, isEmpty);
      expect(find.text('permission-denied'), findsOneWidget);
      expect(harness.errors, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('non-handleable row cannot become a registration batch', (
    tester,
  ) async {
    final harness = _RouterHarness(
      rows: [_record(canHandle: false)],
      batch: true,
    );
    await harness.pump(tester);
    await tester.tap(find.byKey(const Key('open-record')));
    await tester.pumpAndSettle();

    expect(harness.arrivals, isEmpty);
    expect(harness.router.state.uri.toString(), _source);
    expect(harness.errors, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final action in ['FINISHED_REGISTER']) {
    testWidgets(
      '$action without a router fails closed with an actionable notice',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final errors = <Object>[];
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: _ActionButton(
                  rows: [_record(action: action)],
                  errors: errors,
                  onMount: () {},
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('open-record')));
        await tester.pump();

        expect(errors, isEmpty);
        final notice = container.read(appNotificationProvider).single;
        expect(notice.kind, AppNotificationKind.warning);
        expect(notice.message, contains('任务中心'));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'registered arrival detail uses its modal without requiring a router',
    (tester) async {
      final row = _record(action: 'FINISHED_ARRIVAL_DETAIL', canHandle: false);
      final api = _PhysicalDetailApi(row);
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'warehouse-actor'),
          ),
          currentPermissionsProvider.overrideWithValue({Perm.stockDocView}),
          warehouseTaskScopeProvider.overrideWithValue(
            const WarehouseTaskScope.all(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final errors = <Object>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            home: Scaffold(
              body: _ActionButton(rows: [row], errors: errors, onMount: () {}),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-record')));
      await tester.pumpAndSettle();
      expect(
        api.calls.single.path,
        '/warehouse/task-center/inbound/FINISHED%3AFINISHED_REGISTRATION%3Aprojection-id/detail',
      );
      expect(api.calls.single.query, {'linePage': 1, 'lineSize': 100});
      expect(find.text('REGISTERED-ONLY'), findsOneWidget);
      expect(errors, isEmpty);
      expect(container.read(appNotificationProvider), isEmpty);
      await tester.tap(
        find.descendant(
          of: find.byType(WarehouseTaskPhysicalDetailDialog),
          matching: find.text('关闭'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WarehouseTaskPhysicalDetailDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // This scope is externally owned; release its session retry timer before
      // the widget binding checks for pending timers at the end of the test.
      container.dispose();
    },
  );
}
