// ADR-117 车间侧：缺的料计划还没下单 → 状态列「等计划下单」、物料列点名、
// 详情弹窗里「催计划」，以及冷却、没权限、计划其实已下单(服务端 409)这些边角。
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// 可变的服务端替身：列表按 [urged] / [ordered] 返回当前事实，催计划按 [urgeReply] 回。
class _Server {
  bool urged = false;
  bool ordered = false;
  DateTime? nextUrgeAt;
  bool canUrge = true;

  /// null = 正常受理(第一次 notified=true，之后按 [cooling] 决定)。
  int? urgeStatusCode;
  bool cooling = false;
  final List<String> posts = [];
  int listLoads = 0;

  Map<String, dynamic> task() => {
    'segmentId': 'seg-1',
    'planId': 'plan-1',
    'planNo': 'SJ-1',
    'segmentCode': 'GD-1',
    'workshopDepartmentId': 'ws-1',
    'workshopName': '装配一车间',
    'productCode': 'P-1',
    'productName': '开关面板',
    'productUnitName': '个',
    'plannedQty': 1000,
    'reportedQty': 0,
    'remainingReportQty': 1000,
    'segmentStatus': 'WAITING',
    'materialStatus': 'KIT_SHORT',
    'issued': false,
    'zeroMaterial': false,
    'canStart': false,
    'canRequestDraw': false,
    'lockVersion': 1,
    'startRoute': 'FULL_KIT',
    'materialKindCount': 4,
    'materialIssuedKindCount': 1,
    'materialShortKindCount': 3,
    'materialShortMakeKindCount': 1,
    if (!ordered) ...{
      'materialPlanningGapKindCount': 2,
      'materialPlanningGapSummary': '铜片 800个、弹簧 1000个',
      'canUrgePlanning': canUrge,
      if (urged) ...{
        'planningUrgeCount': 1,
        'planningUrgedAt': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 5))
            .toIso8601String(),
        'planningUrgedByName': '王师傅',
        'planningNextUrgeAt':
            (nextUrgeAt ??
                    DateTime.now().toUtc().add(const Duration(minutes: 25)))
                .toIso8601String(),
      },
    },
  };

  ProductionExecutionWorkbenchRepository repository() {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (request.method == 'POST' &&
              request.path.endsWith('/planning-urge')) {
            posts.add(request.path);
            if (urgeStatusCode != null) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: request,
                    statusCode: urgeStatusCode,
                    data: {
                      'code': 'CONFLICT',
                      'message': '计划已经为缺的料下过单了，正在等到货，不用再催',
                    },
                  ),
                ),
              );
              ordered = true;
              return;
            }
            final notified = !cooling;
            urged = true;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'urgeId': 'urge-1',
                  'segmentId': 'seg-1',
                  'notified': notified,
                  'urgeCount': 1,
                  'nextUrgeAllowedAt': DateTime.now()
                      .toUtc()
                      .add(const Duration(minutes: 30))
                      .toIso8601String(),
                  'gapKindCount': 2,
                  'gapSummary': '铜片 800个、弹簧 1000个',
                },
              ),
            );
            return;
          }
          if (request.path.endsWith('/materials')) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: [
                  {
                    'demandId': 'd-copper',
                    'goodsCode': 'TP-01',
                    'goodsName': '铜片',
                    'unitName': '个',
                    'supplyRoute': 'BUY',
                    'requiredQty': 1000,
                    'shortageQty': 800,
                    'state': 'SHORT',
                    'planningGapQty': ordered ? 0 : 800,
                  },
                  {
                    'demandId': 'd-spring',
                    'goodsCode': 'TH-01',
                    'goodsName': '弹簧',
                    'unitName': '个',
                    'supplyRoute': 'BUY',
                    'requiredQty': 1000,
                    'shortageQty': 1000,
                    'state': 'SHORT',
                    'planningGapQty': ordered ? 0 : 1000,
                    'planningRouteConfirmed': false,
                  },
                  {
                    'demandId': 'd-shell',
                    'goodsCode': 'KT-01',
                    'goodsName': '外壳',
                    'unitName': '个',
                    'supplyRoute': 'BUY',
                    'requiredQty': 1000,
                    'shortageQty': 1000,
                    'state': 'SHORT',
                  },
                ],
              ),
            );
            return;
          }
          if (request.path == '/production/workshop-tasks') listLoads++;
          final data = switch (request.path) {
            '/production/workshop-tasks' => {
              'items': [task()],
              'page': 1,
              'size': 50,
              'total': 1,
              'totalPages': 1,
            },
            _ => <String, dynamic>{},
          };
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
    return ProductionExecutionWorkbenchRepository(ApiClient(dio));
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Server server, {
  bool canStart = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const ProductionWorkshopTasksPage(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionExecutionView,
          if (canStart) Perm.productionExecutionStart,
        }),
        productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
          server.repository(),
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
  await tester.tap(find.text('等待物料'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(ProductionWorkshopTasksPage)),
  );
}

Future<void> _openDetail(WidgetTester tester) async {
  await tester.tap(find.text('开关面板'));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text('开关面板'));
  await tester.pumpAndSettle();
  expect(find.text('车间任务详情'), findsOneWidget);
}

Finder get _urgeButton =>
    find.byKey(const ValueKey('workshop-detail-urge-seg-1'));

void main() {
  testWidgets('计划没下单的缺料：状态列品红「等计划下单」、物料列点名、详情里能催', (tester) async {
    final server = _Server();
    final container = await _pump(tester, server);

    // 状态列：不是笼统的「等待到货」，而是品红的「等计划下单 · 缺 2 种」。
    final status = find.widgetWithText(UtenStatusBadge, '等计划下单 · 缺 2 种');
    expect(status, findsOneWidget);
    expect(
      tester.widget<UtenStatusBadge>(status).type,
      UtenStatusBadgeType.fuchsia,
    );
    // 物料列：缺 3 种里 2 种计划没下单，单独点出来。
    final summary = tester.widget<Text>(
      find.byKey(const ValueKey('workshop-material-summary-seg-1')),
    );
    expect(summary.textSpan!.toPlainText(), contains('计划未下单 2 种'));

    await _openDetail(tester);
    expect(
      find.byKey(const ValueKey('workshop-planning-gap-seg-1')),
      findsOneWidget,
    );
    expect(find.text('还有 2 种料计划没下单'), findsOneWidget);
    expect(find.text('铜片 800个、弹簧 1000个'), findsOneWidget);
    // 逐种物料：计划没下单的品红「等计划下单」；计划没定供应方式的另说；
    // 缺但计划已经下过单的(外壳)照旧「等采购到货」一类。
    await tester.pumpAndSettle();
    final copper = tester.widget<UtenStatusBadge>(
      find.byKey(const ValueKey('workshop-task-material-state-d-copper')),
    );
    expect(copper.label, '等计划下单');
    expect(copper.type, UtenStatusBadgeType.fuchsia);
    expect(
      tester
          .widget<UtenStatusBadge>(
            find.byKey(const ValueKey('workshop-task-material-state-d-spring')),
          )
          .label,
      '等计划定供应方式',
    );
    final shell = tester.widget<UtenStatusBadge>(
      find.byKey(const ValueKey('workshop-task-material-state-d-shell')),
    );
    expect(shell.label, isNot(contains('计划')));

    expect(
      find.descendant(of: _urgeButton, matching: find.text('催计划')),
      findsOneWidget,
    );
    final loadsBefore = server.listLoads;
    await tester.tap(_urgeButton);
    await tester.pumpAndSettle();

    expect(server.posts, ['/production/workshop-tasks/seg-1/planning-urge']);
    expect(
      container.read(appNotificationProvider).last.message,
      contains('已提醒计划员'),
    );
    // 催完整页重拉，状态变成「已催计划」。
    expect(server.listLoads, greaterThan(loadsBefore));
    expect(find.text('已催计划 · 等下单 2 种'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('30 分钟内刚催过：详情按钮灰掉并说几点后能再催，右键菜单也灰', (tester) async {
    final server = _Server()..urged = true;
    await _pump(tester, server);

    await _openDetail(tester);
    final button = tester.widget<ButtonStyleButton>(_urgeButton);
    expect(button.onPressed, isNull);
    expect(
      find.descendant(of: _urgeButton, matching: find.textContaining('后可再催')),
      findsOneWidget,
    );
    expect(find.textContaining('已催 1 次'), findsOneWidget);
    expect(find.textContaining('王师傅'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('开关面板')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    final entry = find.textContaining('刚催过');
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(server.posts, isEmpty, reason: '冷却中的菜单条目不能发请求');
  });

  testWidgets('冷却已过：按钮变「再催一次」，可以再催', (tester) async {
    final server = _Server()
      ..urged = true
      ..nextUrgeAt = DateTime.now().toUtc().subtract(
        const Duration(minutes: 1),
      );
    await _pump(tester, server);
    await _openDetail(tester);
    expect(
      find.descendant(of: _urgeButton, matching: find.text('再催一次')),
      findsOneWidget,
    );
    await tester.tap(_urgeButton);
    await tester.pumpAndSettle();
    expect(server.posts, hasLength(1));
  });

  testWidgets('服务端说刚催过(并发/别人刚催)：如实提示，不报错', (tester) async {
    final server = _Server()..cooling = true;
    final container = await _pump(tester, server);
    await _openDetail(tester);
    await tester.tap(_urgeButton);
    await tester.pumpAndSettle();
    final notice = container.read(appNotificationProvider).last;
    expect(notice.message, contains('刚催过'));
    expect(notice.message, contains('以后可以再催'));
  });

  testWidgets('计划其实刚下完单(服务端 409)：提示原因并刷新，状态不再是等计划下单', (tester) async {
    final server = _Server()..urgeStatusCode = 409;
    final container = await _pump(tester, server);
    await _openDetail(tester);
    await tester.tap(_urgeButton);
    await tester.pumpAndSettle();
    expect(
      container.read(appNotificationProvider).last.message,
      contains('不用再催'),
    );
    expect(find.textContaining('等计划下单'), findsNothing);
    expect(find.textContaining('计划未下单'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有开工权限：看得到缺什么，但没有催计划按钮', (tester) async {
    final server = _Server()..canUrge = false;
    await _pump(tester, server, canStart: false);
    expect(find.text('等计划下单 · 缺 2 种'), findsOneWidget);
    await _openDetail(tester);
    expect(find.text('还有 2 种料计划没下单'), findsOneWidget);
    expect(_urgeButton, findsNothing);
    expect(find.text('找车间负责人催'), findsOneWidget);
  });
}
