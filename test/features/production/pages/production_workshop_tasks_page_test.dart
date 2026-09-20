import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/filter_segment_tap.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  materialUsageEntryTests();
  routeConfirmationTests();
  testWidgets(
    'shared batch material usage writes the real original issue task',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = _router();
      addTearDown(router.dispose);
      final requests = <RequestOptions>[];
      var posted = false;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            Object response;
            if (request.path.endsWith('/material-usage-sources')) {
              response = [
                {
                  'executionSegmentId': 'original-issued',
                  'executionSegmentCode': 'GD-原领料',
                  'shared': true,
                  'canOpen': true,
                  'canSettle': true,
                },
              ];
            } else if (request.path.endsWith('/capabilities')) {
              response = {
                'canSettle': true,
                'canReverse': false,
                'canClose': false,
              };
            } else if (request.path.endsWith('/clearance')) {
              response = [
                {
                  'planId': 'plan-segment-a',
                  'demandId': 'original-demand',
                  'goodsId': 'material-a',
                  'goodsName': '前批原领物料',
                  'unitName': '千克',
                  'executionSegmentId': 'original-issued',
                  'requiredQty': 10,
                  'issuedQty': 10,
                  'unclearedQty': posted ? 0 : 10,
                  'consumedQty': posted ? 10 : 0,
                  'canClose': posted,
                },
              ];
            } else {
              if (request.method == 'POST') posted = true;
              response = <Object>[];
            }
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: response,
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionMaterialSettle,
            }),
            productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
              _repository(sharedMaterial: true),
            ),
            productionMaterialRepositoryProvider.overrideWithValue(
              ProductionMaterialRepository(ApiClient(dio)),
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
      await selectFilterSegment(tester, '生产中');
      await tester.pumpAndSettle();
      // 2026-09-18：「生产中」不再有「下一步」列——查看用料走双击行的详情弹窗
      // (行右键菜单同款条目)，不再经过格子里的下拉框。
      expect(
        find.byKey(const ValueKey('workshop-route-cell-segment-a')),
        findsNothing,
      );
      await tester.tap(find.text('产品 A'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('产品 A'));
      await tester.pumpAndSettle();
      expect(find.text('车间任务详情'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('查看用料记录'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择原领料任务'), findsOneWidget);
      expect(
        requests.single.queryParameters['executionSegmentId'],
        'segment-a',
      );
      await tester.tap(
        find.byKey(const ValueKey('material-usage-source-original-issued')),
      );
      await tester.pumpAndSettle();
      expect(find.text('前批原领物料'), findsOneWidget);
      expect(
        requests
            .skip(1)
            .every(
              (request) =>
                  request.queryParameters['executionSegmentId'] ==
                  'original-issued',
            ),
        isTrue,
      );
      // V583：本页只剩只读台账——实耗随报工在生产日报页一起填，这里不再有任何
      // 记账入口，也不发 POST。沿用前批的来源选择本身保留(只读也要选看哪一段)。
      expect(find.text('将待登记量填入实耗'), findsNothing);
      expect(find.text('提交用料登记'), findsNothing);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('material-consume-original-demand')),
            )
            .enabled,
        isFalse,
      );
      expect(
        requests.any((request) => request.method == 'POST'),
        isFalse,
        reason: '只读台账不得写任何材料事实',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'eligible waiting task opens partial batch review without plan permission',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionExecutionStart,
            }),
            productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
              // 2026-09-18：详情弹窗的「分批领料」按钮按 V599 加了路线门——
              // 只有已确认 BATCH 路线的工单才出现。
              _repository(
                withWaitingRow: true,
                canSplitBatch: true,
                startRoute: 'BATCH',
              ),
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
      await tester.tap(find.text('产品 C'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('产品 C'));
      await tester.pumpAndSettle();
      expect(find.text('车间任务详情'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('workshop-detail-batch-segment-c')),
      );
      await tester.pumpAndSettle();
      expect(find.text('分批领料 segment-c 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final requested in [false, true]) {
    testWidgets(
      'manual draw state $requested has distinct color and server filter',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final requests = <RequestOptions>[];
        final router = _router();
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isSuperAdminProvider.overrideWithValue(false),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.productionExecutionView,
                Perm.productionExecutionStart,
              }),
              productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
                _repository(
                  readyIssued: false,
                  drawRequested: requested,
                  withWaitingRow: true,
                  onRequest: requests.add,
                ),
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
        final label = requested ? '已提交领料 · 待仓库发料' : '物料齐套 · 去领料';
        final badge = tester.widget<UtenStatusBadge>(
          find.byWidgetPredicate(
            (widget) => widget is UtenStatusBadge && widget.label == label,
          ),
        );
        expect(
          badge.type,
          requested ? UtenStatusBadgeType.neutral : UtenStatusBadgeType.accent,
        );
        expect(
          find.byKey(const ValueKey('workshop-request-draw-segment-a')),
          requested ? findsNothing : findsOneWidget,
        );
        await tester.tap(find.text('状态'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        final query = requests
            .lastWhere((r) => r.path == '/production/workshop-tasks')
            .queryParameters;
        expect(
          query['preparationFilter'],
          requested ? 'DRAW_REQUESTED' : 'DRAW_NOT_REQUESTED',
        );
        expect(query['page'], 1);
        if (!requested) {
          await tester.tap(find.text('产品 A'));
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tap(find.text('产品 A'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('workshop-detail-draw-segment-a')),
          );
          await tester.pumpAndSettle();
          expect(find.text('领料汇总 segment-a 1'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'fully received task shows material settlement instead of reporting lock',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionDailyReportView,
              Perm.productionDailyReportCreate,
              Perm.productionMaterialSettle,
            }),
            productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
              _repository(
                materialActivity: true,
                unregisteredMaterial: true,
                fullyReceived: true,
              ),
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
      await selectFilterSegment(tester, '生产中');
      await tester.pumpAndSettle();
      expect(find.text('已入库 · 待登记实际用料'), findsOneWidget);
      // 2026-09-18：「生产中」不再有「下一步」列——状态列直接说明下一步，
      // 用料入口在行右键菜单与双击详情弹窗里。
      expect(
        find.byKey(const ValueKey('workshop-route-cell-segment-a')),
        findsNothing,
      );
      expect(find.byIcon(Icons.info_outline_rounded), findsWidgets);
      expect(find.byTooltip('物料已齐，请到仓库领料；领料完成后即可开工'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'preparing segment: ready rows batch start, waiting rows explain the block',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = _router();
      addTearDown(router.dispose);
      final planRepository = _FakePlanRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionExecutionStart,
              // 计划详情入口（查看物料进度/查看生产计划）2026-09-10 起按
              // production_plan:view 门控；无码用例见下方专项测试。
              Perm.productionPlanView,
            }),
            productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
              _repository(withWaitingRow: true),
            ),
            productionPlanRepositoryProvider.overrideWithValue(planRepository),
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
      // 分类默认不选：先给引导占位，点分类才加载列表。
      expect(find.text('在上方选择分类后查看任务'), findsOneWidget);
      // 2026-09-06 改版：「可报工」分类退役——等待物料（等料+齐套可开工）、
      // 生产中（正在生产·可报工）、历史任务三段。
      expect(find.text('可报工'), findsNothing);
      await tester.tap(find.text('等待物料'));
      await tester.pumpAndSettle();

      // 齐套行状态徽章 + 未齐行锁位（带原因提示；mock 不过滤状态，
      // 生产中行出现在等待物料分类时同样锁位不可开工）。
      expect(find.text('物料齐套 · 可开工'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline_rounded), findsWidgets);
      // 等待物料分类不显示进度列（只有生产中显示）。
      expect(find.text('进度'), findsNothing);

      // 未齐行右键菜单 = 「为什么不能开工」，点了给出明确原因。
      // 菜单条目必须用 _menuEntry 限定：行内「生产路线」格的主操作按钮可能显示
      // 同一条文案（这里是生产中行落进等待物料分类后显示「为什么不能开工」），
      // 裸 find.text 会同时命中行内标签与菜单条目。
      await _rightClick(tester, find.text('产品 C'));
      await tester.tap(_menuEntry('为什么不能开工'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionWorkshopTasksPage)),
      );
      expect(
        container.read(appNotificationProvider).single.message,
        contains('子件还没全部备齐'),
      );

      await _rightClick(tester, find.text('产品 C'));
      await tester.tap(_menuEntry('重新核对备料'));
      await tester.pumpAndSettle();
      expect(planRepository.recheckedSegmentIds, ['segment-c']);
      expect(
        container.read(appNotificationProvider).last.message,
        contains('勾选并提交领料'),
      );

      // 齐套行勾选 → 右下角「批量开工」，按计划分组提交。
      await _selectRow(tester, '产品 A');
      await tester.tap(find.text('批量开工(1)'));
      await tester.pumpAndSettle();
      expect(planRepository.startedPlanIds, ['plan-segment-a']);
      expect(
        container.read(appNotificationProvider).last.message,
        contains('已开工 1 个工单'),
      );
      await _rightClick(tester, find.text('产品 C'));
      await tester.tap(_menuEntry('查看物料进度'));
      await tester.pumpAndSettle();
      expect(find.text('计划 plan-segment-c'), findsOneWidget);
    },
  );

  testWidgets(
    'a ready kit still requires actual warehouse issue before start',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = _router();
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionExecutionStart,
            }),
            productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
              _repository(readyIssued: false),
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
      // 2026-09-11 用户口径：这一步是车间自己去仓库领，不是干等仓库送。
      expect(find.text('物料齐套 · 去领料'), findsOneWidget);
      expect(find.text('物料齐套 · 待仓库发料'), findsNothing);
      // 同上：行内「生产路线」格的主操作与菜单条目同名，只认弹出层里的那条。
      await _rightClick(tester, find.text('产品 A'));
      await tester.tap(_menuEntry('为什么不能开工'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionWorkshopTasksPage)),
      );
      expect(
        container.read(appNotificationProvider).last.message,
        contains('批量领料'),
      );
      await _selectRow(tester, '产品 A');
      expect(find.text('批量领料(1)'), findsOneWidget);
      expect(find.text('批量开工(0)'), findsOneWidget);
      await tester.tap(find.text('批量领料(1)'));
      await tester.pumpAndSettle();
      expect(find.text('领料汇总 segment-a 1'), findsOneWidget);
    },
  );

  testWidgets('in-progress segment keeps batch report and progress column', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(),
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
    await selectFilterSegment(tester, '生产中');
    await tester.pumpAndSettle();

    // 生产中显示进度列与「生产中 · 可报工」口径。
    expect(find.text('进度'), findsOneWidget);
    expect(find.text('生产中 · 可报工 20%'), findsNWidgets(2));
    expect(find.text('批量开工(0)'), findsNothing);

    await _selectRow(tester, '产品 A');
    await _selectRow(tester, '产品 B');
    await tester.tap(find.text('批量报工(2)'));
    await tester.pumpAndSettle();

    expect(find.text('批量来源 segment-a,segment-b'), findsOneWidget);
  });

  testWidgets(
    'row menu only opens the plan; single report goes through selection + floating button',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = _router();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionDailyReportView,
              Perm.productionDailyReportCreate,
              Perm.productionPlanView,
            }),
            productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
              _repository(),
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
      // 分类默认不选：点分类后才渲染表格。
      await selectFilterSegment(tester, '生产中');
      await tester.pumpAndSettle();

      // 2026-09-06 用户口径：报工按钮统一=多选后右下角悬浮执行；
      // 行内按钮/行菜单报工下线，行菜单只保留查看生产计划。
      // 2026-09-17 行菜单与「下一步」下拉合并成同一份清单后这条仍然成立：
      // 清单里不放报工，整页任何位置都不该再出现「报工」二字（行内下拉收起时
      // 显示的是清单第一条可执行动作，只剩只读条目就显示「更多操作」）。
      await _rightClick(tester, find.text('产品 A'));
      expect(_menuEntry('查看生产计划'), findsOneWidget);
      expect(find.text('报工'), findsNothing);

      // 本用例真正要守的契约：勾选后右下角「批量报工(1)」仍在，点了进单项报工。
      // 右击已把该行置为选中，这一下点勾选框先被菜单遮罩吃掉（只关菜单、保留选中）。
      await _selectRow(tester, '产品 A');
      expect(find.text('批量报工(1)'), findsOneWidget);
      await tester.tap(find.text('批量报工(1)'));
      await tester.pumpAndSettle();

      expect(find.text('单项来源 segment-a'), findsOneWidget);
    },
  );

  testWidgets('cross-workshop selection is free and blocked only on submit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
            Perm.productionDailyReportView,
            Perm.productionDailyReportCreate,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            _repository(mixedWorkshops: true),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 分类默认不选：点分类后才渲染表格。
    await selectFilterSegment(tester, '生产中');
    await tester.pumpAndSettle();

    final header = find.byWidgetPredicate(
      (widget) => widget is Checkbox && widget.tristate,
    );
    await tester.tap(header);
    await tester.pumpAndSettle();

    // 2026-09-06 用户口径：自由多选，不再对其它车间行上锁；
    // 跨车间选择只在提交时给明确提示（服务端口径：一次报工=同一车间）。
    expect(find.text('批量报工(2)'), findsOneWidget);
    expect(find.byTooltip('已选择其它生产车间；一次批量报工只能包含同一车间'), findsNothing);
    await tester.tap(find.text('批量报工(2)'));
    await tester.pumpAndSettle();
    // 测试树不含通知宿主，直接断言全局通知队列里的业务提示。
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProductionWorkshopTasksPage)),
    );
    expect(
      container.read(appNotificationProvider).single.message,
      contains('一次报工只能包含同一生产车间'),
    );
    expect(find.textContaining('来源 segment'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late response cannot overwrite a newer task filter', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);
    final repository = _DelayedWorkshopRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            repository,
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
    await tester.pump();
    await tester.pump();
    // 分类默认不选：初始不请求列表，点分类才发第一次请求。
    expect(repository.calls, 0);

    await tester.tap(find.text('等待物料'));
    await tester.pump();
    expect(repository.calls, 1);
    await selectFilterSegment(tester, '生产中');
    await tester.pump();
    expect(repository.calls, 2);

    repository.second.complete(_pageWithProduct('新筛选结果'));
    await tester.pump();
    await tester.pump();
    expect(find.text('新筛选结果'), findsOneWidget);

    repository.first.complete(_pageWithProduct('迟到旧结果'));
    await tester.pump();
    await tester.pump();
    expect(find.text('新筛选结果'), findsOneWidget);
    expect(find.text('迟到旧结果'), findsNothing);
  });

  testWidgets(
    'without plan permission double-click still opens the scoped workshop task detail',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = _router();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isSuperAdminProvider.overrideWithValue(false),
            // V541/V543 车间默认包：有车间任务 + 报工三码，没有 production_plan:view。
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionExecutionView,
              Perm.productionExecutionStart,
              Perm.productionDailyReportView,
              Perm.productionDailyReportCreate,
            }),
            productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
              _repository(withWaitingRow: true),
            ),
            productionPlanRepositoryProvider.overrideWithValue(
              _FakePlanRepository(),
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
      await selectFilterSegment(tester, '生产中');
      await tester.pumpAndSettle();

      // 行菜单不再提供计划详情入口（菜单为空时不弹）。
      // 2026-09-17 起菜单与「下一步」下拉共用一份清单，这份清单里没有报工
      // （报工仍只走勾选 + 悬浮按钮），生产中行去掉计划详情后就真的一条不剩——
      // 菜单不弹，下面的双击才不会被菜单遮罩吃掉第一次点击。
      await _rightClick(tester, find.text('产品 A'));
      expect(find.text('查看生产计划'), findsNothing);
      expect(find.text('查看生产计划（可单独开工）'), findsNothing);
      expect(_menuSurface, findsNothing);

      // 双击直接查看已授权的精确任务，不需要额外的计划查看权限。
      await tester.tap(find.text('产品 A'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('产品 A'));
      await tester.pumpAndSettle();
      expect(find.textContaining('计划 plan-'), findsNothing);
      expect(find.text('车间任务详情'), findsOneWidget);
      expect(find.text('查看生产计划'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      // 等待物料分类：未齐行仍能问「为什么不能开工」，但没有「查看物料进度」。
      await tester.tap(find.text('等待物料'));
      await tester.pumpAndSettle();
      await _rightClick(tester, find.text('产品 C'));
      expect(_menuEntry('为什么不能开工'), findsOneWidget);
      expect(find.text('查看物料进度'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history segment loads only after the time gate is chosen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
    addTearDown(router.dispose);
    final repository = _RecordingWorkshopRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.productionExecutionView,
          }),
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            repository,
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
    expect(repository.calls, isEmpty);

    // ADR-066 §1.3：点历史任务只渲染时间门控 + 占位，不发请求。
    await tester.tap(find.text('历史任务'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workshop-history-time')), findsOneWidget);
    expect(find.text('历史数据可能较多，请先在上方选择时间段或「全部」'), findsOneWidget);
    expect(repository.calls, isEmpty);

    // 选「全部」→ 发一次 COMPLETED 请求，不带日期。
    await selectFilterSegment(tester, '全部');
    await tester.pumpAndSettle();
    expect(repository.calls, hasLength(1));
    expect(repository.calls.single.status, 'COMPLETED');
    expect(repository.calls.single.dateFrom, isNull);
    expect(repository.calls.single.dateTo, isNull);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('已红冲'), findsOneWidget);

    // 切回活动分类：时间门控行消失，请求不带日期。
    await selectFilterSegment(tester, '生产中');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workshop-history-time')), findsNothing);
    expect(repository.calls.last.status, 'IN_PROGRESS');
    expect(repository.calls.last.dateFrom, isNull);
    expect(tester.takeException(), isNull);
  });
}

/// 2026-09-17（V599 / ADR-091）：「确认生产路线」是等待物料工单的第一个下一步——
/// 未确认路线时开工侧入口全部隐藏；确认弹窗三选一后按路线过滤清单。
void routeConfirmationTests() {
  Future<void> mount(
    WidgetTester tester, {
    ProductionExecutionWorkbenchRepository? repository,
    _FakePlanRepository? planRepository,
    bool canStart = true,
    String category = '等待物料',
  }) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _router();
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
            repository ??
                _repository(
                  withWaitingRow: true,
                  startRoute: null,
                  canConfirmRoute: true,
                ),
          ),
          if (planRepository != null)
            productionPlanRepositoryProvider.overrideWithValue(planRepository),
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
    await selectFilterSegment(tester, category);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'route confirmation precedes draw, batch and start even when capabilities are stale',
    (tester) async {
      await mount(
        tester,
        repository: _repository(
          withWaitingRow: true,
          startRoute: null,
          canConfirmRoute: true,
          rowCanSplitBatch: true,
          aStartRouteNull: true,
        ),
      );
      expect(find.text('待确认生产路线'), findsNWidgets(2));
      await tester.tap(
        find.byKey(const ValueKey('workshop-next-step-segment-c')),
      );
      await tester.pumpAndSettle();
      expect(_menuEntry('路线确认'), findsOneWidget);
      expect(_menuEntry('分批生产领料'), findsNothing);
      expect(_menuEntry('开工'), findsNothing);
      expect(_menuEntry('去领料(查看领料汇总)'), findsNothing);
      expect(_menuEntry('部分开工 · 持续生产'), findsNothing);
    },
  );

  testWidgets(
    'pure warehouse task can choose continuous and only explicit confirmation submits',
    (tester) async {
      final plans = _FakePlanRepository()..confirmGate = Completer<void>();
      await mount(tester, planRepository: plans);
      await tester.tap(
        find.byKey(const ValueKey('workshop-next-step-segment-c')),
      );
      await tester.pumpAndSettle();
      await tester.tap(_menuEntry('路线确认'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workshop-route-batch-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('持续生产').last);
      await tester.pumpAndSettle();
      expect(plans.confirmedRoutes, isEmpty);
      expect(find.textContaining('每种必需物料共同支持一部分产量'), findsOneWidget);
      await tester.tap(find.byKey(const Key('workshop-route-batch-apply')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const Key('workshop-route-confirm-busy')),
        findsOneWidget,
      );
      plans.confirmGate!.complete();
      await tester.pumpAndSettle();
      expect(plans.confirmedRoutes, [('segment-c', 'CONTINUOUS')]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('view-only employee cannot confirm routes', (tester) async {
    await mount(tester, canStart: false);
    await _rightClick(tester, find.text('产品 C'));
    expect(_menuEntry('路线确认'), findsNothing);
    expect(find.byKey(const Key('workshop-batch-set-routes')), findsNothing);
  });

  for (final oldRoute in ['BATCH', 'CONTINUOUS']) {
    testWidgets(
      'unconfirmed task ignores legacy $oldRoute suggestion from another task',
      (tester) async {
        final plans = _FakePlanRepository();
        await mount(
          tester,
          planRepository: plans,
          repository: _repository(
            withWaitingRow: true,
            startRoute: null,
            canConfirmRoute: true,
            rowCanSplitBatch: true,
            cLegacySuggestedStartRoute: oldRoute,
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('workshop-next-step-segment-c')),
        );
        await tester.pumpAndSettle();
        await tester.tap(_menuEntry('路线确认'));
        await tester.pumpAndSettle();
        final field = tester.widget<UtenDropdownField>(
          find.byKey(const Key('workshop-route-batch-field')),
        );
        expect(field.value, 'FULL_KIT');
        expect(plans.confirmedRoutes, isEmpty);
        await tester.tap(find.byKey(const Key('workshop-route-batch-apply')));
        await tester.pumpAndSettle();
        expect(plans.confirmedRoutes, [('segment-c', 'FULL_KIT')]);
      },
    );
  }

  for (final route in ['FULL_KIT', 'BATCH', 'CONTINUOUS']) {
    testWidgets(
      'route editing keeps this task confirmed $route and ignores old cached suggestion',
      (tester) async {
        await mount(
          tester,
          repository: _repository(
            withWaitingRow: true,
            startRoute: route,
            routeChangeable: true,
            rowCanSplitBatch: true,
            cLegacySuggestedStartRoute: route == 'BATCH'
                ? 'CONTINUOUS'
                : 'BATCH',
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('workshop-next-step-segment-c')),
        );
        await tester.pumpAndSettle();
        await tester.tap(_menuEntry('更改生产路线'));
        await tester.pumpAndSettle();
        final field = tester.widget<UtenDropdownField>(
          find.byKey(const Key('workshop-route-batch-field')),
        );
        expect(field.value, route);
      },
    );
  }

  testWidgets(
    'zero-material task only defaults to its currently valid full-kit route',
    (tester) async {
      await mount(
        tester,
        repository: _repository(aZeroMaterial: true, aStartRouteNull: true),
      );
      await tester.tap(
        find.byKey(const ValueKey('workshop-next-step-segment-a')),
      );
      await tester.pumpAndSettle();
      await tester.tap(_menuEntry('路线确认'));
      await tester.pumpAndSettle();
      final field = tester.widget<UtenDropdownField>(
        find.byKey(const Key('workshop-route-batch-field')),
      );
      expect(field.value, 'FULL_KIT');
      expect(field.items.map((item) => item.value), ['FULL_KIT']);
    },
  );

  testWidgets(
    'route options omit independent batches when the task cannot split',
    (tester) async {
      await mount(
        tester,
        repository: _repository(
          withWaitingRow: true,
          startRoute: null,
          canConfirmRoute: true,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('workshop-next-step-segment-c')),
      );
      await tester.pumpAndSettle();
      await tester.tap(_menuEntry('路线确认'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workshop-route-batch-field')));
      await tester.pumpAndSettle();
      expect(find.text('分批生产'), findsNothing);
      expect(find.text('持续生产'), findsOneWidget);
    },
  );

  testWidgets('route confirmation stays usable on a narrow short screen', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(
      find.byKey(const ValueKey('workshop-next-step-segment-c')),
    );
    await tester.pumpAndSettle();
    await tester.tap(_menuEntry('路线确认'));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(375, 480));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final button = find.byKey(const Key('workshop-route-batch-apply'));
    await tester.ensureVisible(button);
    expect(button.hitTestable(), findsOneWidget);
  });

  for (final (route, label, color) in [
    ('FULL_KIT', '齐套生产', UtenStatusBadgeType.success),
    ('BATCH', '分批生产', UtenStatusBadgeType.info),
    ('CONTINUOUS', '持续生产', UtenStatusBadgeType.fuchsia),
  ]) {
    testWidgets(
      'confirmed $route displays a distinct route badge and only its own actions',
      (tester) async {
        await mount(
          tester,
          repository: _repository(
            withWaitingRow: true,
            startRoute: route,
            rowCanSplitBatch: true,
          ),
        );
        final badge = tester.widget<UtenStatusBadge>(
          find.descendant(
            of: _frozenRowOf('产品 C'),
            matching: find.byWidgetPredicate(
              (widget) => widget is UtenStatusBadge && widget.label == label,
            ),
          ),
        );
        expect(badge.type, color);
        await _rightClick(tester, find.text('产品 C'));
        expect(
          _menuEntry('分批生产领料'),
          route == 'BATCH' ? findsOneWidget : findsNothing,
        );
        expect(_menuEntry('部分开工 · 持续生产'), findsNothing);
      },
    );
  }

  for (final route in ['CONTINUOUS', 'FULL_KIT']) {
    testWidgets(
      'in-progress $route task can replenish when the server allows it without a new task',
      (tester) async {
        await mount(
          tester,
          category: '生产中',
          repository: _repository(
            readyIssued: false,
            aStartRoute: route,
            aContinuousSupply: route == 'CONTINUOUS',
          ),
        );
        await tester.tap(
          find.byKey(const ValueKey('workshop-next-step-segment-a')),
        );
        await tester.pumpAndSettle();
        expect(_menuEntry('继续领料(查看领料汇总)'), findsOneWidget);
        await tester.tap(_menuEntry('继续领料(查看领料汇总)'));
        await tester.pumpAndSettle();
        expect(find.text('领料汇总 segment-a 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('batch route confirmation submits only eligible selected tasks', (
    tester,
  ) async {
    final plans = _FakePlanRepository();
    await mount(
      tester,
      planRepository: plans,
      repository: _repository(
        withWaitingRow: true,
        startRoute: null,
        canConfirmRoute: true,
        rowCanSplitBatch: true,
      ),
    );
    await tester.tap(
      find.byWidgetPredicate((widget) => widget is Checkbox && widget.tristate),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workshop-batch-set-routes')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workshop-route-batch-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分批生产').last);
    await tester.pumpAndSettle();
    expect(plans.confirmedRoutes, isEmpty);
    await tester.tap(find.byKey(const Key('workshop-route-batch-apply')));
    await tester.pumpAndSettle();
    expect(plans.confirmedRoutes, [('segment-c', 'BATCH')]);
  });
}

void materialUsageEntryTests() {
  // 2026-09-12 用户口径：「登记实际用料」只在生产中分类出现；等待物料行一律
  // 只读「查看用料记录」（即便未登记+有权限）。
  for (final (activity, pending, issued, permission, label) in [
    (false, false, true, true, null),
    (true, false, true, true, '查看用料记录'),
    (true, true, false, true, '查看用料记录'),
    (true, true, true, false, '查看用料记录'),
  ]) {
    testWidgets(
      'material entry uses ledger facts activity=$activity pending=$pending issued=$issued permission=$permission',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1700, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final router = _router();
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isSuperAdminProvider.overrideWithValue(false),
              currentPermissionsProvider.overrideWithValue({
                Perm.productionExecutionView,
                if (permission) Perm.productionMaterialSettle,
              }),
              productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
                _repository(
                  readyIssued: issued,
                  materialActivity: activity,
                  unregisteredMaterial: pending,
                ),
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
        // 2026-09-18 二轮：「生产路线」格只剩路线本身（下拉/只读文本），主操作
        // （含用料入口）回到行右键菜单与详情弹窗——这里断言行菜单的用料条目。
        expect(
          find.descendant(
            of: _frozenRowOf('产品 A'),
            matching: find.text('齐套生产'),
          ),
          findsOneWidget,
        );
        await _rightClick(tester, find.text('产品 A'));
        expect(find.text('登记实际用料'), findsNothing);
        expect(
          _menuEntry('查看用料记录'),
          label == '查看用料记录' ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (canSettle, serverAllows) in [
    (true, true),
    (false, true),
    (true, false),
  ]) {
    testWidgets(
      'ordinary workshop user opens exact material task, settle=$canSettle server=$serverAllows',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1700, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final router = _router();
        addTearDown(router.dispose);
        final reads = <RequestOptions>[];
        final writes = <RequestOptions>[];
        var posted = false;
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              final Object data;
              if (request.method == 'POST') {
                writes.add(request);
                posted = true;
                data = <Object>[];
              } else {
                reads.add(request);
                data = request.path.endsWith('/capabilities')
                    ? {
                        'canSettle': serverAllows,
                        'canReverse': false,
                        'canClose': false,
                      }
                    : request.path.endsWith('/clearance')
                    ? [
                        {
                          'planId': 'plan-segment-a',
                          'demandId': 'demand-a',
                          'goodsId': 'goods-material',
                          'goodsName': '本工单原料',
                          'unitName': '件',
                          'executionSegmentId': 'segment-a',
                          'requiredQty': 10,
                          'issuedQty': 10,
                          'unclearedQty': posted ? 0 : 10,
                          'consumedQty': posted ? 10 : 0,
                          'canClose': posted,
                        },
                      ]
                    : <Object>[];
              }
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
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isSuperAdminProvider.overrideWithValue(false),
              currentPermissionsProvider.overrideWithValue({
                Perm.productionExecutionView,
                if (canSettle) Perm.productionMaterialSettle,
                if (canSettle) Perm.productionMaterialClose,
              }),
              productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
                _repository(materialActivity: true, unregisteredMaterial: true),
              ),
              productionMaterialRepositoryProvider.overrideWithValue(
                ProductionMaterialRepository(ApiClient(dio)),
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
        await selectFilterSegment(tester, '生产中');
        await tester.pumpAndSettle();
        await _rightClick(tester, find.text('产品 A'));
        // V583：实耗登记搬到生产日报页(报工时物料子行一起填)，本页任何分类、
        // 任何权限组合都只剩只读台账，入口文案固定为「查看用料记录」。
        expect(find.text('登记实际用料'), findsNothing);
        await tester.tap(find.text('查看用料记录').last);
        await tester.pumpAndSettle();
        expect(find.text('本工单原料'), findsOneWidget);
        expect(reads.length, 4);
        expect(
          reads.any((request) => request.path.endsWith('/return-requests')),
          isTrue,
        );
        expect(
          reads.every(
            (request) =>
                request.queryParameters['executionSegmentId'] == 'segment-a',
          ),
          isTrue,
        );
        expect(find.text('检查并完成任务'), findsNothing, reason: '单段任务权限不能关闭整个计划');
        expect(find.text('余料退库'), findsNothing, reason: '任务入口不能跳入未过滤的全计划退料选择器');
        // 有没有 settle 权限、服务端 capabilities 允不允许，本页一律只读：
        // 两处都能记账会让实耗数字互相打架，实耗的唯一入口是生产日报页。
        expect(find.text('将待登记量填入实耗'), findsNothing);
        expect(find.text('提交用料登记'), findsNothing);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('material-consume-demand-a')),
              )
              .enabled,
          isFalse,
        );
        expect(writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

GoRouter _router() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, _) => const ProductionWorkshopTasksPage()),
    GoRoute(
      path: '/production/workshop-tasks/batch-draw',
      builder: (_, state) => Scaffold(
        body: Text(
          '分批领料 ${state.uri.queryParameters['segmentId']} ${state.uri.queryParameters['version']}',
        ),
      ),
    ),
    GoRoute(
      path: '/production/workshop-tasks/draw-request',
      builder: (_, state) => Scaffold(
        body: Text(
          '领料汇总 ${state.uri.queryParameters['segmentIds']} ${state.uri.queryParameters['versions']}',
        ),
      ),
    ),
    GoRoute(
      path: '/production/daily-reports/new',
      builder: (_, state) {
        final single = state.uri.queryParameters['executionSegmentId'];
        final batch = state.uri.queryParameters['executionSegmentIds'];
        return Scaffold(
          body: Text(single != null ? '单项来源 $single' : '批量来源 ${batch ?? ''}'),
        );
      },
    ),
    GoRoute(
      path: '/production/plans/:id',
      builder: (_, state) =>
          Scaffold(body: Text('计划 ${state.pathParameters['id']}')),
    ),
  ],
);

ProductionExecutionWorkbenchRepository _repository({
  bool mixedWorkshops = false,
  bool withWaitingRow = false,
  bool readyIssued = true,
  bool drawRequested = false,
  bool canSplitBatch = false,
  bool sharedMaterial = false,
  void Function(RequestOptions request)? onRequest,
  bool materialActivity = false,
  bool unregisteredMaterial = false,
  bool fullyReceived = false,
  String? startRoute = 'FULL_KIT',
  bool canConfirmRoute = false,
  bool routeContinuousEligible = false,
  bool rowCanSplitBatch = false,
  bool routeChangeable = false,
  bool rowContinuousSupply = false,
  bool aStartRouteNull = false,
  String aStartRoute = 'FULL_KIT',
  bool aContinuousSupply = false,
  bool aZeroMaterial = false,
  bool aRouteChangeable = false,
  String? cLegacySuggestedStartRoute,
  bool cCanRecheck = true,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        onRequest?.call(request);
        final data = switch (request.path) {
          '/production/workshop-tasks' => {
            'items': [
              {
                ..._task(
                  'segment-a',
                  '产品 A',
                  request.queryParameters['status'] == 'IN_PROGRESS'
                      ? 'IN_PROGRESS'
                      : 'READY',
                  issued: readyIssued,
                  materialActivity: materialActivity,
                  unregisteredMaterial: unregisteredMaterial,
                  startRoute: aStartRouteNull ? null : aStartRoute,
                  continuousSupply: aContinuousSupply,
                  canConfirmRoute: aStartRouteNull,
                  zeroMaterial: aZeroMaterial,
                  routeChangeable: aRouteChangeable,
                ),
                'drawRequested': drawRequested,
                'canRequestDraw': !readyIssued && !drawRequested,
                'hasSharedMaterialActivity': sharedMaterial,
                if (fullyReceived) ...{
                  'plannedQty': 10000,
                  'reportedQty': 10000,
                  'remainingReportQty': 0,
                  'inboundQty': 10000,
                  'canReport': false,
                  'canBatchReport': false,
                },
              },
              _task(
                'segment-b',
                '产品 B',
                'IN_PROGRESS',
                workshopId: mixedWorkshops ? 'workshop-2' : 'workshop-1',
                workshopName: mixedWorkshops ? '装配二车间' : '装配一车间',
              ),
              if (withWaitingRow)
                _task(
                  'segment-c',
                  '产品 C',
                  'WAITING',
                  kitShort: true,
                  canSplitBatch: canSplitBatch || rowCanSplitBatch,
                  canReport: false,
                  canBatchReport: false,
                  startRoute: startRoute,
                  canConfirmRoute: canConfirmRoute,
                  routeContinuousEligible: routeContinuousEligible,
                  routeChangeable: routeChangeable,
                  continuousSupply: rowContinuousSupply,
                  legacySuggestedStartRoute: cLegacySuggestedStartRoute,
                  canRecheck: cCanRecheck,
                ),
            ],
            'page': 1,
            'size': 50,
            'total': withWaitingRow ? 3 : 2,
            'totalPages': 1,
          },
          '/production/workshop-tasks/count' => {'count': 2},
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

Map<String, dynamic> _task(
  String id,
  String product,
  String status, {
  String workshopId = 'workshop-1',
  String workshopName = '装配一车间',
  bool kitShort = false,
  bool canSplitBatch = false,
  bool issued = true,
  bool canReport = true,
  bool canBatchReport = true,
  bool materialActivity = false,
  bool unregisteredMaterial = false,
  bool zeroMaterial = false,
  bool canRecheck = true,
  String? legacySuggestedStartRoute,
  String? startRoute = 'FULL_KIT',
  bool canConfirmRoute = false,
  bool routeChangeable = false,
  bool routeContinuousEligible = false,
  bool continuousSupply = false,
}) => {
  'segmentId': id,
  'canSplitBatch': canSplitBatch,
  'planId': 'plan-$id',
  'planNo': 'SJ-$id',
  'segmentCode': 'GD-$id',
  'salesOrderNos': 'SO-001',
  'workshopDepartmentId': workshopId,
  'workshopName': workshopName,
  'responsibleEmployeeName': '负责人',
  'productCode': 'P-$id',
  'productName': product,
  'productColorName': '本色',
  'productUnitName': '件',
  'plannedQty': 10,
  'reportedQty': status == 'IN_PROGRESS' ? 2 : 0,
  'remainingReportQty': status == 'IN_PROGRESS' ? 8 : 10,
  'segmentStatus': status,
  if (status == 'WAITING' || status == 'READY')
    'blockedReason': '请先在我的车间任务中开工，开工后才能报工',
  'materialStatus': kitShort ? 'KIT_SHORT' : 'KIT_READY',
  'preparationStatus': 'PREPARED',
  'materialReady': !kitShort,
  'warehouseReady': !kitShort,
  'issued': issued,
  'zeroMaterial': zeroMaterial,
  'canStart':
      (status == 'READY' || status == 'DISPATCHED') &&
      issued &&
      startRoute != null,
  'canReport': canReport,
  'canBatchReport': canBatchReport,
  'lockVersion': 1,
  'canRecheckMaterial': status == 'WAITING' && canRecheck,
  'hasMaterialActivity': materialActivity,
  'hasUnregisteredMaterial': unregisteredMaterial,
  'startRoute': startRoute,
  // A cached response from an older server may still carry this retired field.
  'suggestedStartRoute': ?legacySuggestedStartRoute,
  'canConfirmRoute': canConfirmRoute,
  'routeChangeable': routeChangeable,
  'routeContinuousEligible': routeContinuousEligible,
  'continuousSupply': continuousSupply,
};

/// 只记录批量开工调用的计划仓库桩（等待物料分类的「批量开工」链路）。
class _FakePlanRepository extends ProductionPlanRepository {
  _FakePlanRepository()
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))));

  final List<String> startedPlanIds = [];
  final List<String> recheckedSegmentIds = [];
  final List<(String, String)> confirmedRoutes = [];

  /// 挂起确认提交的门（忙遮罩测试用）：非空时 confirm 停在这个 future 上，
  /// 由测试自行 complete 放行。
  Completer<void>? confirmGate;

  @override
  Future<ProductionExecutionSegmentView> confirmExecutionSegmentRoute(
    String planId,
    String segmentId, {
    required int expectedVersion,
    required String route,
  }) async {
    final gate = confirmGate;
    if (gate != null) await gate.future;
    confirmedRoutes.add((segmentId, route));
    return ProductionExecutionSegmentView.fromJson({
      'id': segmentId,
      'packageId': 'package',
      'planId': planId,
      'sourcePlanItemId': 'plan-item',
      'segmentCode': 'SEG-1',
      'productGoodsId': 'goods',
      'plannedQty': 10,
      'reportedQty': 0,
      'remainingQty': 10,
      'lockVersion': expectedVersion + 1,
      'status': route == 'FULL_KIT' ? 'READY' : 'WAITING',
    });
  }

  @override
  Future<ProductionExecutionSegmentView> recheckExecutionSegmentMaterials(
    String planId,
    String segmentId, {
    required int expectedVersion,
  }) async {
    recheckedSegmentIds.add(segmentId);
    return ProductionExecutionSegmentView.fromJson({
      'id': segmentId,
      'packageId': 'package',
      'planId': planId,
      'sourcePlanItemId': 'plan-item',
      'segmentCode': 'SEG-1',
      'productGoodsId': 'goods',
      'plannedQty': 10,
      'reportedQty': 0,
      'remainingQty': 10,
      'lockVersion': expectedVersion + 1,
      'status': 'READY',
    });
  }

  @override
  Future<void> batchStartExecutionSegments(
    String planId, {
    required List<({String segmentId, int expectedVersion})> items,
  }) async {
    startedPlanIds.add(planId);
  }
}

Future<void> _selectRow(WidgetTester tester, String product) async {
  final row = _frozenRowOf(product);
  final checkbox = find
      .descendant(of: row, matching: find.byType(Checkbox))
      .first;
  await tester.tap(checkbox);
  await tester.pump();
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 弹出菜单那张自绘小框本身（UtenContextMenu 用 elevation 8 的 Material 画）。
/// 条目为空时不弹，可用来断言「这一行根本没有菜单」。
final Finder _menuSurface = find.byWidgetPredicate(
  (widget) => widget is Material && widget.elevation == 8,
  description: 'UtenContextMenu surface',
);

/// 弹出菜单里的条目。
///
/// 2026-09-18 起行右键菜单与表格「生产路线」格的主操作共用同一份清单——同一个
/// 字符串会在表格行里再出现一次（多行各出现一次也有可能），裸 find.text 会歧义、
/// tap 直接抛错。断言/点击菜单条目一律限定在弹出层内。
Finder _menuEntry(String label) =>
    find.descendant(of: _menuSurface, matching: find.text(label));

PagedResult<ProductionExecutionWorkbenchSegment> _pageWithProduct(
  String name,
) => PagedResult(
  items: [
    ProductionExecutionWorkbenchSegment.fromJson(
      _task('delayed-segment', name, 'WAITING'),
    ),
  ],
  page: 1,
  size: 50,
  total: 1,
  totalPages: 1,
);

class _DelayedWorkshopRepository
    extends ProductionExecutionWorkbenchRepository {
  _DelayedWorkshopRepository()
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))));

  final Completer<PagedResult<ProductionExecutionWorkbenchSegment>> first =
      Completer();
  final Completer<PagedResult<ProductionExecutionWorkbenchSegment>> second =
      Completer();
  int calls = 0;

  @override
  Future<PagedResult<ProductionExecutionWorkbenchSegment>> workshopTasks({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? status,
    String? preparationFilter,
    String? workshopDepartmentId,
    String? dateFrom,
    String? dateTo,
  }) {
    calls++;
    return calls == 1 ? first.future : second.future;
  }

  @override
  Future<WorkshopTaskCountBreakdown> workshopTaskCount() async =>
      const WorkshopTaskCountBreakdown();
}

/// 记录每次列表请求的分类与时间门控参数；历史段返回一条已取消 + 一条已红冲。
class _RecordingWorkshopRepository
    extends ProductionExecutionWorkbenchRepository {
  _RecordingWorkshopRepository()
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))));

  final List<({String? status, String? dateFrom, String? dateTo})> calls = [];

  @override
  Future<PagedResult<ProductionExecutionWorkbenchSegment>> workshopTasks({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? status,
    String? preparationFilter,
    String? workshopDepartmentId,
    String? dateFrom,
    String? dateTo,
  }) async {
    calls.add((status: status, dateFrom: dateFrom, dateTo: dateTo));
    final items = status == 'COMPLETED'
        ? [
            ProductionExecutionWorkbenchSegment.fromJson(
              _task('segment-x', '产品 X', 'CANCELLED', canReport: false),
            ),
            ProductionExecutionWorkbenchSegment.fromJson(
              _task('segment-y', '产品 Y', 'REVERSED', canReport: false),
            ),
          ]
        : [
            ProductionExecutionWorkbenchSegment.fromJson(
              _task('segment-a', '产品 A', 'IN_PROGRESS'),
            ),
          ];
    return PagedResult(
      items: items,
      page: 1,
      size: 50,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  Future<WorkshopTaskCountBreakdown> workshopTaskCount() async =>
      const WorkshopTaskCountBreakdown();
}

/// 行首勾选格 2026-09-11 起被「冻结」成整行 Stack 的 Positioned 兄弟
/// （横滚时钉在视口左缘，见 UtenFrozenLeadingColumn），不再是数据 Row 的后代。
/// 定位整行时必须取冻结包裹层；没有选择列的表（无冻结层）回落到 Row。
Finder _frozenRowOf(String text) {
  final frozen = find.ancestor(
    of: find.text(text).first,
    matching: find.byType(UtenFrozenLeadingColumn),
  );
  if (frozen.evaluate().isNotEmpty) return frozen.first;
  return find
      .ancestor(of: find.text(text).first, matching: find.byType(Row))
      .first;
}
