// 工作台「今日概览 / 待办任务」控制台形态的回归网（2026-09-12 改版随附）。
//
// 改版前这两块**零 widget 测试**——调研时确认过。既然把卡片堆换成了指标带 + 待办泳道，
// 就得把新形态的行为契约钉住，否则下一个人改回去或改坏都没人拦。
//
// 锁住的五件事：
// 1. 数值与标题真的渲染出来了（不是只剩装饰）；
// 2. 空态说的是「本部门」而不是旧的「当前权限下」——这正是本次改口径的用户可见面；
// 3. reduced-motion 下不崩、内容照常完整（动效不承载信息）；
// 4. 375px 窄屏不溢出（车间用的机器屏幕都不大）；
// 5. 截止倒计时芯片只在有 dueAt 的待办上出现，逾期/未逾期两种措辞都对（2026-09-11 补）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_live_pulse_dot.dart';
import 'package:uten_imp/features/dashboard/models/dashboard_overview.dart';
import 'package:uten_imp/features/dashboard/widgets/dashboard_console_sections.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  // UtenAnimatedNumber 走性能档 provider，而那条链读 sharedPreferences
  //（正式 App 在 main.dart 注入）。这里给个空桩，不然整块直接抛
  //「sharedPreferencesProvider must be overridden in main.dart」。
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });
  DashboardMetric metric({
    String id = 'production-pending',
    String title = '待排产',
    String value = '12',
    String subtitle = '已审订单未排产',
    String tone = 'warning',
    String? route = '/production',
  }) => DashboardMetric(
    id: id,
    title: title,
    value: value,
    subtitle: subtitle,
    tone: tone,
    route: route,
    sensitive: false,
  );

  DashboardTodo todo({
    String id = 'expense-approval',
    String title = '你有 3 项报销申请待审批',
    String summary = '已合并展示，点击进入对应页面统一处理',
    int count = 3,
    int urgentCount = 0,
    String tone = 'warning',
    DateTime? dueAt,
  }) => DashboardTodo(
    id: id,
    title: title,
    summary: summary,
    count: count,
    urgentCount: urgentCount,
    tone: tone,
    route: '/expense/approval',
    sourceType: 'FINANCE',
    sourceId: null,
    dueAt: dueAt,
    completable: false,
  );

  // UtenAnimatedNumber 是 ConsumerWidget（要读性能档 provider），必须套 ProviderScope。
  Widget host(
    Widget child, {
    Size size = const Size(1200, 900),
    bool reduceMotion = false,
    TextScaler textScaler = TextScaler.noScaling,
  }) => ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          disableAnimations: reduceMotion,
          textScaler: textScaler,
        ),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );

  testWidgets('指标带渲染标题、数值与副标题', (tester) async {
    await tester.pumpWidget(
      host(
        DashboardMetricStrip(
          metrics: [
            metric(),
            metric(id: 'sales-active', title: '执行中订单', value: '7'),
          ],
          departmentName: '财税部',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('待排产'), findsOneWidget);
    expect(find.text('执行中订单'), findsOneWidget);
    // 数值由 UtenAnimatedNumber 画；settle 后应停在目标值上。
    expect(find.text('12'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('已审订单未排产'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非数字的指标值原样显示，不被当成 0', (tester) async {
    await tester.pumpWidget(
      host(
        DashboardMetricStrip(
          metrics: [metric(value: '已锁定')],
          departmentName: '财税部',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已锁定'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('指标为空时说的是「本部门」，不是旧的「当前权限下」', (tester) async {
    await tester.pumpWidget(
      host(const DashboardMetricStrip(metrics: [], departmentName: '财税部')),
    );
    await tester.pumpAndSettle();

    expect(find.text('财税部暂无概览指标'), findsOneWidget);
    expect(find.textContaining('当前权限下'), findsNothing);
  });

  testWidgets('待办泳道渲染标题与计数徽章', (tester) async {
    await tester.pumpWidget(
      host(
        DashboardTodoLane(
          todos: [
            todo(),
            todo(id: 'visitor-approval', title: '你有 1 项访客申请待审批', count: 1),
          ],
          departmentName: '财税部',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('你有 3 项报销申请待审批'), findsOneWidget);
    expect(find.text('你有 1 项访客申请待审批'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办为空时同样说「本部门」', (tester) async {
    await tester.pumpWidget(
      host(const DashboardTodoLane(todos: [], departmentName: '财税部')),
    );
    await tester.pumpAndSettle();

    expect(find.text('财税部当前没有待办'), findsOneWidget);
  });

  // 服务端一直在下发 dueAt，改版前模型解析完就扔了——倒计时芯片是它的第一个
  // 用户可见面，逾期/未逾期两种措辞都得对，且不能波及没有截止时间的行。
  testWidgets('有截止时间的待办渲染倒计时芯片，逾期与未逾期措辞各就各位', (tester) async {
    await tester.pumpWidget(
      host(
        DashboardTodoLane(
          todos: [
            // 3.5 天而不是整 3 天：构建比夹具晚几毫秒，整天数边界会被 inDays 截断。
            todo(dueAt: DateTime.now().add(const Duration(days: 3, hours: 12))),
            todo(
              id: 'notice-overdue',
              title: '逾期通知',
              dueAt: DateTime.now().subtract(const Duration(hours: 2)),
            ),
          ],
          departmentName: '财税部',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('剩 3 天'), findsOneWidget);
    expect(find.textContaining('已逾期 2 小时'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无截止时间的待办不渲染倒计时芯片', (tester) async {
    await tester.pumpWidget(
      host(DashboardTodoLane(todos: [todo()], departmentName: '财税部')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('剩 '), findsNothing);
    expect(find.textContaining('已逾期'), findsNothing);
  });

  // 第一版这里是个 repeat() 的呼吸环：保活的工作台 Tab 上会一直烧帧，也让任何
  // pumpAndSettle 永远停不下来（准则 07 §七）。改成复用 UtenLivePulseDot 的一次性脉冲。
  testWidgets('紧急节点的脉冲是一次性的：settle 能停下来，不是无限呼吸灯', (tester) async {
    await tester.pumpWidget(
      host(
        DashboardTodoLane(
          todos: [todo(urgentCount: 2, tone: 'danger')],
          departmentName: '财税部',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenLivePulseDot), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced-motion 下紧急待办照常完整渲染（动效不承载信息）', (tester) async {
    await tester.pumpWidget(
      host(
        DashboardTodoLane(
          todos: [todo(urgentCount: 2, tone: 'danger')],
          departmentName: '财税部',
        ),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('你有 3 项报销申请待审批'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('375px 窄屏：指标带退化成单列且不溢出', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      host(
        DashboardMetricStrip(
          metrics: [
            metric(),
            metric(id: 'sales-active', title: '执行中订单', value: '7'),
            metric(id: 'notice-unread', title: '未读通知', value: '25'),
          ],
          departmentName: '财税部',
        ),
        size: const Size(375, 812),
      ),
    );
    await tester.pumpAndSettle();

    // 窄屏收起态只显示一列一行；展开入口应在。
    expect(find.textContaining('展开其余'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字号（1.5 档）下不裁切、不溢出', (tester) async {
    await tester.pumpWidget(
      host(
        DashboardTodoLane(
          todos: [
            todo(),
            todo(id: 'payroll-review', title: '你有 5 项工资批次待复核', count: 5),
          ],
          departmentName: '财税部',
        ),
        size: const Size(900, 900),
        textScaler: const TextScaler.linear(1.5),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('你有 5 项工资批次待复核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
