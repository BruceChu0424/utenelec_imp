import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  materialUsageEntryTests();
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
      await _rightClick(tester, find.text('产品 C'));
      await tester.tap(find.text('为什么不能开工'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionWorkshopTasksPage)),
      );
      expect(
        container.read(appNotificationProvider).single.message,
        contains('子件还没全部备齐'),
      );

      await _rightClick(tester, find.text('产品 C'));
      await tester.tap(find.text('重新核对备料'));
      await tester.pumpAndSettle();
      expect(planRepository.recheckedSegmentIds, ['segment-c']);
      expect(
        container.read(appNotificationProvider).last.message,
        contains('按实际子仓生成领料单'),
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
      await tester.tap(find.text('查看物料进度'));
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
      expect(find.text('物料齐套 · 待仓库发料'), findsOneWidget);
      await _rightClick(tester, find.text('产品 A'));
      await tester.tap(find.text('为什么不能开工'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionWorkshopTasksPage)),
      );
      expect(
        container.read(appNotificationProvider).last.message,
        contains('等待仓库发料'),
      );
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
    await tester.tap(find.text('生产中'));
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
      await tester.tap(find.text('生产中'));
      await tester.pumpAndSettle();

      // 2026-09-06 用户口径：报工按钮统一=多选后右下角悬浮执行；
      // 行内按钮/行菜单报工下线，行菜单只保留查看生产计划。
      await _rightClick(tester, find.text('产品 A'));
      expect(find.text('查看生产计划'), findsOneWidget);
      expect(find.text('报工'), findsNothing);

      await _selectRow(tester, '产品 A');
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
    await tester.tap(find.text('生产中'));
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
    await tester.tap(find.text('生产中'));
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
    'without production_plan:view the plan entry is hidden and double-click warns',
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
      await tester.tap(find.text('生产中'));
      await tester.pumpAndSettle();

      // 行菜单不再提供计划详情入口（菜单为空时不弹）。
      await _rightClick(tester, find.text('产品 A'));
      expect(find.text('查看生产计划'), findsNothing);
      expect(find.text('查看生产计划（可单独开工）'), findsNothing);

      // 双击不落到 /access-denied：留在本页并给出明确提示。
      await tester.tap(find.text('产品 A'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('产品 A'));
      await tester.pumpAndSettle();
      expect(find.textContaining('计划 plan-'), findsNothing);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProductionWorkshopTasksPage)),
      );
      expect(
        container.read(appNotificationProvider).last.message,
        contains('无生产计划查看权限'),
      );

      // 等待物料分类：未齐行仍能问「为什么不能开工」，但没有「查看物料进度」。
      await tester.tap(find.text('等待物料'));
      await tester.pumpAndSettle();
      await _rightClick(tester, find.text('产品 C'));
      expect(find.text('为什么不能开工'), findsOneWidget);
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
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(repository.calls, hasLength(1));
    expect(repository.calls.single.status, 'COMPLETED');
    expect(repository.calls.single.dateFrom, isNull);
    expect(repository.calls.single.dateTo, isNull);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('已红冲'), findsOneWidget);

    // 切回活动分类：时间门控行消失，请求不带日期。
    await tester.tap(find.text('生产中'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workshop-history-time')), findsNothing);
    expect(repository.calls.last.status, 'IN_PROGRESS');
    expect(repository.calls.last.dateFrom, isNull);
    expect(tester.takeException(), isNull);
  });
}

void materialUsageEntryTests() {
  for (final (activity, pending, issued, permission, label) in [
    (false, false, true, true, null),
    (true, false, true, true, '查看用料记录'),
    (true, true, false, true, '登记实际用料'),
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
        final entry = find.byKey(
          const ValueKey('workshop-material-usage-segment-a'),
        );
        expect(entry, label == null ? findsNothing : findsOneWidget);
        if (label != null) {
          expect(
            find.descendant(of: entry, matching: find.text(label)),
            findsOneWidget,
          );
        }
        await _rightClick(tester, find.text('产品 A'));
        expect(
          find.text('登记实际用料'),
          label == '登记实际用料' ? findsNWidgets(2) : findsNothing,
        );
        expect(
          find.text('查看用料记录'),
          label == '查看用料记录' ? findsNWidgets(2) : findsNothing,
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
        await tester.tap(find.text('生产中'));
        await tester.pumpAndSettle();
        await _rightClick(tester, find.text('产品 A'));
        await tester.tap(find.text(canSettle ? '登记实际用料' : '查看用料记录').last);
        await tester.pumpAndSettle();
        expect(find.text('本工单原料'), findsOneWidget);
        expect(reads.length, 3);
        expect(
          reads.every(
            (request) =>
                request.queryParameters['executionSegmentId'] == 'segment-a',
          ),
          isTrue,
        );
        expect(find.text('检查并完成任务'), findsNothing, reason: '单段任务权限不能关闭整个计划');
        expect(find.text('余料退库'), findsNothing, reason: '任务入口不能跳入未过滤的全计划退料选择器');
        if (canSettle && serverAllows) {
          await tester.tap(find.text('将待登记量填入实耗'));
          await tester.pumpAndSettle();
          final field = tester.widget<TextField>(
            find.byKey(const ValueKey('material-consume-demand-a')),
          );
          expect(field.controller!.text, '10');
          expect(field.decoration!.filled, isTrue);
          expect(
            find.byWidgetPredicate(
              (widget) => widget is UtenFieldHintIcon && widget.autofilled,
            ),
            findsOneWidget,
          );
          expect(writes, isEmpty, reason: '建议量必须人工提交后才入账');
          await tester.ensureVisible(find.text('提交用料登记'));
          await tester.tap(find.text('提交用料登记'));
          await tester.pumpAndSettle();
          expect(writes.length, 1);
          final payload = writes.single.data as Map<String, dynamic>;
          expect(payload['executionSegmentId'], 'segment-a');
          expect(
            (payload['lines'] as List).single,
            containsPair('demandId', 'demand-a'),
          );
        } else {
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
        }
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
  bool materialActivity = false,
  bool unregisteredMaterial = false,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/production/workshop-tasks' => {
            'items': [
              _task(
                'segment-a',
                '产品 A',
                request.queryParameters['status'] == 'IN_PROGRESS'
                    ? 'IN_PROGRESS'
                    : 'READY',
                issued: readyIssued,
                materialActivity: materialActivity,
                unregisteredMaterial: unregisteredMaterial,
              ),
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
                  canReport: false,
                  canBatchReport: false,
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
  bool issued = true,
  bool canReport = true,
  bool canBatchReport = true,
  bool materialActivity = false,
  bool unregisteredMaterial = false,
}) => {
  'segmentId': id,
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
  'canReport': canReport,
  'canBatchReport': canBatchReport,
  'lockVersion': 1,
  'canRecheckMaterial': status == 'WAITING',
  'hasMaterialActivity': materialActivity,
  'hasUnregisteredMaterial': unregisteredMaterial,
};

/// 只记录批量开工调用的计划仓库桩（等待物料分类的「批量开工」链路）。
class _FakePlanRepository extends ProductionPlanRepository {
  _FakePlanRepository()
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))));

  final List<String> startedPlanIds = [];
  final List<String> recheckedSegmentIds = [];

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
