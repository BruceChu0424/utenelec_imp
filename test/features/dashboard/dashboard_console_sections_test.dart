// 工作台「今日概览」合并面板的回归网（2026-09-28 合并改版随附；
// 前身是 2026-09-12 控制台改版为 DashboardMetricStrip / DashboardTodoLane
// 写的测试，合并后改为直接泵 DashboardOverviewPanel）。
//
// 锁住的六件事：
// 1. 合并结构成立：一段面板同时承载「今日概览」标题栏、指标区与「待办任务」
//    小节头，总数徽章 = 各待办 count 之和；
// 2. 数值与标题真的渲染出来了（不是只剩装饰）；非数字指标值不被当成 0；
// 3. 空态说的是「本部门」而不是旧的「当前权限下」——这是此前改口径的用户可见面；
// 4. reduced-motion 下不崩、内容照常完整（动效不承载信息）；
// 5. 375px 窄屏不溢出（rail 在上瓦片在下纵排，车间用的机器屏幕都不大）；
//    待办超 4 张折叠 + 末尾「查看更多」点开全量可收起；
// 6. 截止倒计时芯片只在有 dueAt 的待办上出现，逾期/未逾期两种措辞都对。
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

  DashboardOverviewPanel panel({
    List<DashboardMetric> metrics = const [],
    List<DashboardTodo> todos = const [],
    String departmentName = '财税部',
  }) => DashboardOverviewPanel(
    metrics: metrics,
    todos: todos,
    departmentName: departmentName,
    generatedAt: DateTime(2026, 9, 28, 9, 41),
  );

  testWidgets('合并面板一段承载今日概览标题栏与待办小节头，总数徽章=各待办之和', (tester) async {
    await tester.pumpWidget(
      host(
        panel(
          metrics: [metric()],
          todos: [
            todo(),
            todo(id: 'visitor-approval', title: '你有 1 项访客申请待审批', count: 1),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今日概览'), findsOneWidget);
    expect(find.text('待办任务'), findsOneWidget);
    // 总数徽章 = 3 + 1 = 4（瓦片上的 3 / 1 是各自计数，只有一枚 4）。
    expect(find.text('4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('指标区渲染标题、数值与副标题', (tester) async {
    await tester.pumpWidget(
      host(
        panel(
          metrics: [
            metric(),
            metric(id: 'sales-active', title: '执行中订单', value: '7'),
          ],
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
    await tester.pumpWidget(host(panel(metrics: [metric(value: '已锁定')])));
    await tester.pumpAndSettle();

    expect(find.text('已锁定'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('指标为空时说的是「本部门」，不是旧的「当前权限下」', (tester) async {
    await tester.pumpWidget(host(panel()));
    await tester.pumpAndSettle();

    expect(find.text('财税部暂无概览指标'), findsOneWidget);
    expect(find.textContaining('当前权限下'), findsNothing);
  });

  testWidgets('待办区渲染标题与计数徽章', (tester) async {
    await tester.pumpWidget(
      host(
        panel(
          todos: [
            todo(),
            todo(id: 'visitor-approval', title: '你有 1 项访客申请待审批', count: 1),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('你有 3 项报销申请待审批'), findsOneWidget);
    expect(find.text('你有 1 项访客申请待审批'), findsOneWidget);
    // 各瓦片一枚计数徽章（总数 4 由合并结构用例单独锁定）。
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办为空时同样说「本部门」', (tester) async {
    await tester.pumpWidget(host(panel()));
    await tester.pumpAndSettle();

    expect(find.text('财税部当前没有待办'), findsOneWidget);
  });

  // 服务端一直在下发 dueAt，改版前模型解析完就扔了——倒计时芯片是它的第一个
  // 用户可见面，逾期/未逾期两种措辞都得对，且不能波及没有截止时间的行。
  testWidgets('有截止时间的待办渲染倒计时芯片，逾期与未逾期措辞各就各位', (tester) async {
    await tester.pumpWidget(
      host(
        panel(
          todos: [
            // 3.5 天而不是整 3 天：构建比夹具晚几毫秒，整天数边界会被 inDays 截断。
            todo(dueAt: DateTime.now().add(const Duration(days: 3, hours: 12))),
            todo(
              id: 'notice-overdue',
              title: '逾期通知',
              dueAt: DateTime.now().subtract(const Duration(hours: 2)),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('剩 3 天'), findsOneWidget);
    expect(find.textContaining('已逾期 2 小时'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无截止时间的待办不渲染倒计时芯片', (tester) async {
    await tester.pumpWidget(host(panel(todos: [todo()])));
    await tester.pumpAndSettle();

    expect(find.textContaining('剩 '), findsNothing);
    expect(find.textContaining('已逾期'), findsNothing);
  });

  // 第一版这里是个 repeat() 的呼吸环：保活的工作台 Tab 上会一直烧帧，也让任何
  // pumpAndSettle 永远停不下来（准则 07 §七）。改成复用 UtenLivePulseDot 的一次性脉冲。
  testWidgets('紧急节点的脉冲是一次性的：settle 能停下来，不是无限呼吸灯', (tester) async {
    await tester.pumpWidget(
      host(panel(todos: [todo(urgentCount: 2, tone: 'danger')])),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenLivePulseDot), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced-motion 下紧急待办照常完整渲染（动效不承载信息）', (tester) async {
    await tester.pumpWidget(
      host(
        panel(
          todos: [
            todo(urgentCount: 2, tone: 'danger'),
            // 第二条非紧急待办把总数徽章顶到 4，避免「3」同时出现在
            // 瓦片徽章与总数徽章、findsOneWidget 误红。
            todo(id: 'visitor-approval', title: '你有 1 项访客申请待审批', count: 1),
          ],
        ),
        reduceMotion: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('你有 3 项报销申请待审批'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('375px 窄屏：指标区退化成单列，瓦片与面板不溢出', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      host(
        panel(
          metrics: [
            metric(),
            metric(id: 'sales-active', title: '执行中订单', value: '7'),
            metric(id: 'notice-unread', title: '未读通知', value: '25'),
          ],
          todos: [
            todo(),
            todo(id: 'visitor-approval', title: '你有 1 项访客申请待审批', count: 1),
          ],
        ),
        size: const Size(375, 812),
      ),
    );
    await tester.pumpAndSettle();

    // 指标 rail 不折叠（竖排全量），三行都在；待办单列纵排。
    expect(find.text('待排产'), findsOneWidget);
    expect(find.text('执行中订单'), findsOneWidget);
    expect(find.text('未读通知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 2026-09-28 用户口径「放不下就最后显示 点击查看更多」：折叠态最多 4 张瓦片，
  // 末尾给「查看更多」，点开全量、可收起。
  testWidgets('待办超过 4 张折叠到 4 张 + 查看更多，点开全量可收起', (tester) async {
    await tester.pumpWidget(
      host(
        panel(
          todos: [
            // id 单字符：瓦片 key = dashboard-todo-{id}，双段拼接易写错。
            for (var i = 0; i < 6; i++)
              todo(id: 't$i', title: '待办 $i', count: 1),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('dashboard-todo-t4')), findsNothing);
    expect(find.textContaining('查看更多（还有 2 项）'), findsOneWidget);

    await tester.tap(find.textContaining('查看更多'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboard-todo-t4')), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-todo-t5')), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);

    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboard-todo-t4')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字号（1.5 档）下不裁切、不溢出', (tester) async {
    await tester.pumpWidget(
      host(
        panel(
          todos: [
            todo(),
            todo(id: 'payroll-review', title: '你有 5 项工资批次待复核', count: 5),
          ],
        ),
        size: const Size(900, 900),
        textScaler: const TextScaler.linear(1.5),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('你有 5 项工资批次待复核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop todos cap at two per row: a/b share a row, c wraps', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      host(
        panel(
          todos: [
            todo(id: 'a'),
            todo(id: 'b'),
            todo(id: 'c'),
          ],
          departmentName: '仓库',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(
      find.byKey(const ValueKey('dashboard-todo-a')),
    );
    final second = tester.getTopLeft(
      find.byKey(const ValueKey('dashboard-todo-b')),
    );
    final third = tester.getTopLeft(
      find.byKey(const ValueKey('dashboard-todo-c')),
    );
    // 大屏两列封顶（2026-09-28 用户口径）：前两张同行并排，第三张换行。
    expect(first.dy, second.dy);
    expect(first.dx, lessThan(second.dx));
    expect(third.dy, greaterThan(second.dy));
    expect(tester.takeException(), isNull);
  });
}
