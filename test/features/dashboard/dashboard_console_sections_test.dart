// 工作台「今日概览」合并面板的回归网（2026-09-28 合并改版随附；
// 前身是 2026-09-12 控制台改版为 DashboardMetricStrip / DashboardTodoLane
// 写的测试，合并后改为直接泵 DashboardOverviewPanel）。
//
// 锁住的六件事：
// 1. 合并结构成立：一段面板同时承载「今日概览」标题栏、指标区与待办卡片；
//    有待办时隐藏小节头、排序说明和总数徽章，无待办时保留标题与空态；
// 2. 数值与标题真的渲染出来了（不是只剩装饰）；非数字指标值不被当成 0；
// 3. 空态与授权功能及数据范围一致，不把部门名称当作功能准入或数据范围；
// 4. reduced-motion 下不崩、内容照常完整（动效不承载信息）；
// 5. 375px 窄屏不溢出(指标横排换行，待办在下方)；
//    待办最多一行，末尾剩余任务数按 count 求和，点击独立面板查看；
// 6. 截止倒计时芯片只在有 dueAt 的待办上出现，逾期/未逾期两种措辞都对。
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_live_pulse_dot.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
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
    String? route = '/expense/approval',
  }) => DashboardTodo(
    id: id,
    title: title,
    summary: summary,
    count: count,
    urgentCount: urgentCount,
    tone: tone,
    route: route,
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
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: size,
          disableAnimations: reduceMotion,
          textScaler: textScaler,
        ),
        child: child!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
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

  testWidgets('有待办时保留今日概览，隐藏待办小节头、排序说明和总数徽章', (tester) async {
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
    expect(find.text('待办任务'), findsNothing);
    expect(find.text('按紧急度排布'), findsNothing);
    expect(find.text('4'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('指标区渲染标题与数值，副标题不再占行', (tester) async {
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
    // 2026-10-30 用户口径：副标题行删除，未知副标题不再显示（静态口径走「?」悬停）。
    expect(find.text('已审订单未排产'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非数字的指标值原样显示，不被当成 0', (tester) async {
    await tester.pumpWidget(host(panel(metrics: [metric(value: '已锁定')])));
    await tester.pumpAndSettle();

    expect(find.text('已锁定'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('指标空态说明授权范围，不将部门当成功能准入条件', (tester) async {
    await tester.pumpWidget(host(panel()));
    await tester.pumpAndSettle();

    expect(find.text('当前可见范围内暂无概览指标'), findsOneWidget);
    expect(find.text('按已授权功能和数据范围展示'), findsNothing);
    final scopeHint = find.byWidgetPredicate(
      (widget) => widget is UtenFieldHintIcon && widget.info == '按已授权功能和数据范围展示',
    );
    expect(scopeHint, findsOneWidget);
    await tester.tap(scopeHint);
    await tester.pumpAndSettle();
    expect(find.text('按已授权功能和数据范围展示'), findsOneWidget);
    Tooltip.dismissAllToolTips();
    await tester.pumpAndSettle();
    expect(find.textContaining('按本部门范围'), findsNothing);
    expect(find.text('财税部暂无概览指标'), findsNothing);
  });

  for (final width in [375.0, 1200.0]) {
    for (final interaction in ['hover', 'tap']) {
      testWidgets('指标静态口径以标题同行图标通过 $interaction 展示 ($width)', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          host(
            panel(
              metrics: [
                metric(title: '待排产产品', subtitle: '按销售订单需求实时汇总'),
                metric(
                  id: 'sales-active',
                  title: '执行中订单',
                  value: '7',
                  subtitle: '已审核且尚未结案',
                ),
              ],
            ),
            size: Size(width, 900),
            textScaler: const TextScaler.linear(1.5),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('12'), findsOneWidget);
        expect(find.text('7'), findsOneWidget);
        expect(find.textContaining('采样'), findsOneWidget);
        for (final item in const [
          ('待排产产品', '按销售订单需求实时汇总'),
          ('执行中订单', '已审核且尚未结案'),
        ]) {
          expect(find.text(item.$2), findsNothing);
          final hint = find.byWidgetPredicate(
            (widget) => widget is UtenFieldHintIcon && widget.info == item.$2,
          );
          final headingRect = tester.getRect(find.text(item.$1));
          final hintRect = tester.getRect(hint);
          expect(hintRect.left, greaterThanOrEqualTo(headingRect.right));
          expect(
            (hintRect.center.dy - headingRect.center.dy).abs(),
            lessThan(16),
          );
          if (interaction == 'hover') {
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: const Offset(1, 1));
            await mouse.moveTo(hintRect.center);
            await tester.pump(const Duration(milliseconds: 251));
            await tester.pumpAndSettle();
            expect(find.text(item.$2), findsOneWidget);
            await mouse.removePointer();
          } else {
            await tester.tap(hint);
            await tester.pumpAndSettle();
            expect(find.text(item.$2), findsOneWidget);
          }
          Tooltip.dismissAllToolTips();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '提示图标不触发父级指标导航');
        }
      });
    }
  }

  testWidgets('副标题一律不占行：零未读、逾期与未知副标题都不显示', (tester) async {
    await tester.pumpWidget(
      host(
        panel(
          metrics: [
            metric(
              title: '待排产产品',
              value: '5',
              subtitle: '3 个已逾期',
              tone: 'danger',
            ),
            metric(
              id: 'notice-unread',
              title: '未读通知',
              value: '0',
              subtitle: '今天没有未读消息',
            ),
            metric(
              id: 'new-metric',
              title: '新指标',
              value: '2',
              subtitle: '当前需要核对',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final text in ['5', '0', '2']) {
      expect(find.text(text), findsOneWidget);
    }
    // 2026-10-30 用户口径：副标题行删除，即时事实与未知副标题同样不占版面。
    for (final text in ['3 个已逾期', '今天没有未读消息', '当前需要核对']) {
      expect(find.text(text), findsNothing);
    }
    expect(
      find.byWidgetPredicate(
        (widget) => widget is UtenFieldHintIcon && widget.info == '3 个已逾期',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('未读加载、错误和未知值保留原值不显示伪零，原因不占行', (tester) async {
    for (final state in [
      ('…', '正在加载未读通知'),
      ('—', '未读通知统计暂不可用'),
      ('未知', '等待服务器返回未读状态'),
      ('25', '请及时查看新消息'),
    ]) {
      await tester.pumpWidget(
        host(
          panel(
            metrics: [
              metric(
                id: 'notice-unread',
                title: '未读通知',
                value: state.$1,
                subtitle: state.$2,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(state.$1), findsOneWidget);
      // 2026-10-30 用户口径：副标题行删除，加载/异常原因不再占版面。
      expect(find.text(state.$2), findsNothing);
      expect(find.text('0'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('今日概览范围图标同行且可由键盘展开', (tester) async {
    await tester.pumpWidget(host(panel()));
    await tester.pumpAndSettle();
    const message = '按已授权功能和数据范围展示';
    final hint = find.byWidgetPredicate(
      (widget) => widget is UtenFieldHintIcon && widget.info == message,
    );
    final titleRect = tester.getRect(find.text('今日概览'));
    final hintRect = tester.getRect(hint);
    expect(hintRect.left, greaterThanOrEqualTo(titleRect.right));
    expect((hintRect.center.dy - titleRect.center.dy).abs(), lessThan(16));
    expect(find.text(message), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(find.text('当前可见范围内没有待办'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    // 各瓦片仍保留自己的计数徽章。
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办空态不将部门名称当作待办的授权范围', (tester) async {
    await tester.pumpWidget(host(panel()));
    await tester.pumpAndSettle();

    expect(find.text('待办任务'), findsOneWidget);
    expect(find.text('按紧急度排布'), findsNothing);
    expect(find.text('当前可见范围内没有待办'), findsOneWidget);
    expect(find.text('财税部当前没有待办'), findsNothing);
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
            // 紧急和非紧急待办的标题、数量在 reduced-motion 下照常显示。
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

  testWidgets('375px 窄屏大字号：指标横排换行，待办及倒计时不溢出', (tester) async {
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
            todo(dueAt: DateTime.now().subtract(const Duration(hours: 47))),
            todo(id: 'visitor-approval', title: '你有 1 项访客申请待审批', count: 1),
          ],
        ),
        size: const Size(375, 812),
        textScaler: const TextScaler.linear(1.5),
      ),
    );
    await tester.pumpAndSettle();

    // 指标不折叠，三项都在；待办只显示一张，剩余入口仍在同一行。
    expect(find.text('待排产'), findsOneWidget);
    expect(find.text('执行中订单'), findsOneWidget);
    expect(find.text('未读通知'), findsOneWidget);
    expect(find.text('你有 3 项报销申请待审批'), findsOneWidget);
    expect(find.text('你有 1 项访客申请待审批'), findsNothing);
    expect(find.text('还有 1 项任务'), findsOneWidget);
    expect(find.text('待办任务'), findsNothing);
    expect(find.text('按紧急度排布'), findsNothing);
    expect(find.text('已逾期 47 小时'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('dashboard-todo-more'))).dy,
      tester
          .getTopLeft(
            find.byKey(const ValueKey('dashboard-todo-expense-approval')),
          )
          .dy,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('剩余任务按 count 求和，独立面板关闭后主面板仍是一行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      host(
        panel(
          todos: [
            for (var i = 0; i < 6; i++)
              todo(id: 't$i', title: '待办 $i', count: i + 1),
          ],
        ),
        size: const Size(1440, 900),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('dashboard-todo-t0')), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-todo-t1')), findsOneWidget);
    expect(find.byKey(const ValueKey('dashboard-todo-t2')), findsNothing);
    // 四张隐藏卡片各含 3、4、5、6 项，入口应显示 18 项任务。
    expect(find.text('还有 18 项任务'), findsOneWidget);
    expect(find.text('21'), findsNothing);
    final originalHeight = tester
        .getSize(find.byType(DashboardOverviewPanel))
        .height;

    await tester.tap(find.byKey(const ValueKey('dashboard-todo-more')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('dashboard-more-todo-t2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dashboard-more-todo-t5')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('dashboard-more-todo-t0')), findsNothing);
    expect(find.text('收起'), findsNothing);

    await tester.tap(find.byType(UtenCloseButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboard-more-todo-t2')), findsNothing);
    expect(find.byKey(const ValueKey('dashboard-todo-t2')), findsNothing);
    expect(find.text('还有 18 项任务'), findsOneWidget);
    expect(
      tester.getSize(find.byType(DashboardOverviewPanel)).height,
      originalHeight,
    );
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

    expect(find.text('你有 5 项工资批次待复核'), findsNothing);
    expect(find.text('还有 5 项任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('dashboard-todo-more')));
    await tester.pumpAndSettle();
    expect(find.text('你有 5 项工资批次待复核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('桌面待办只一行：前两张与剩余入口并排，第三张不换行', (tester) async {
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
    final more = tester.getTopLeft(
      find.byKey(const ValueKey('dashboard-todo-more')),
    );
    // 2026-10-07 用户口径：主面板最多一行，剩余任务通过末尾入口查看。
    expect(first.dy, second.dy);
    expect(first.dx, lessThan(second.dx));
    expect(second.dy, more.dy);
    expect(second.dx, lessThan(more.dx));
    expect(find.byKey(const ValueKey('dashboard-todo-c')), findsNothing);
    expect(find.text('还有 3 项任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏任务点击后关闭面板，并保留工作台 returnTo 与原路由参数', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: '/dashboard',
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (_, _) => Scaffold(
            body: SingleChildScrollView(
              child: panel(
                todos: [
                  todo(id: 'a'),
                  todo(id: 'b'),
                  todo(
                    id: 'hidden',
                    title: '隐藏报销审批',
                    route: '/expense/approval?status=pending',
                  ),
                ],
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/expense/approval',
          builder: (_, _) => const Scaffold(body: Text('报销审批落点')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // MaterialPage 可能保留透明、不可关闭的 barrier；这里只追踪面板遮罩。
    final panelBarrier = find.byWidgetPredicate(
      (widget) => widget is ModalBarrier && widget.dismissible,
    );
    expect(panelBarrier, findsNothing);
    expect(find.text('隐藏报销审批'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('dashboard-todo-more')));
    await tester.pumpAndSettle();
    expect(find.byType(UtenCloseButton), findsOneWidget);
    expect(panelBarrier, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dashboard-more-todo-hidden')));
    await tester.pumpAndSettle();

    expect(find.text('报销审批落点'), findsOneWidget);
    expect(router.state.uri.path, '/expense/approval');
    expect(router.state.uri.queryParameters, {
      'status': 'pending',
      'returnTo': '/dashboard',
    });
    expect(find.byType(UtenCloseButton), findsNothing);
    expect(panelBarrier, findsNothing);
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
