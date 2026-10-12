import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_record_actions.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';

const _source =
    '/warehouse/tasks?kind=inbound&source=FINISHED'
    '&status=FINISHED_REGISTER&warehouseId=warehouse-original&page=3'
    '&returnTo=%2Fwarehouse';

enum _Mount { page, imperative, dialog }

WarehouseTaskCenterRecord _record({
  String action = 'FINISHED_REGISTER',
  String id = 'projection-id',
  String reportId = 'report-original',
  bool canHandle = true,
}) => WarehouseTaskCenterRecord(
  rowKey: 'FINISHED:REPORT:$id',
  id: id,
  targetId: 'target-$id',
  sourceType: 'FINISHED',
  recordType: 'PRODUCTION_REPORT',
  status: 'FINISHED_REGISTER',
  statusLabel: '待登记',
  action: action,
  canHandle: canHandle,
  actionData: {'reportId': reportId},
);

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

  Widget actionButton() => _ActionButton(
    rows: rows,
    errors: errors,
    onMount: () => actionMounts++,
    batch: batch,
    preStock: preStock,
  );

  Future<void> pump(WidgetTester tester) async {
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();
    if (mount != _Mount.page) {
      await tester.tap(find.byKey(const Key('mount-child')));
      await tester.pumpAndSettle();
    }
  }
}

void main() {
  for (final action in ['FINISHED_REGISTER', 'FINISHED_ARRIVAL_DETAIL']) {
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

  for (final action in ['FINISHED_REGISTER', 'FINISHED_ARRIVAL_DETAIL']) {
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
}
