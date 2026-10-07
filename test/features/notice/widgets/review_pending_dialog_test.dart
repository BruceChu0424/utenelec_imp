// ReviewPendingDialog（V459 居中审核弹窗）契约测试：
// - 渲染：标题/条数副标题/条目标题/认领状态 chip（待处理 vs XX 正在审核）；
// - 「稍后再看」：全部条目只调 snooze（15 分钟，服务端顺带置已读；前端不再另调
//   markRead）+ 关闭弹窗；
// - 「去工作台处理」（第四轮口径）：单条也去域工作台（不直达详情）；跨域
//   混合去待审收件台；点列表行去该行所属域工作台（仅该条已读）；
// - 新到待办并入已开弹窗（不叠第二层）；高度自适应 + 多条封顶滚动。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/providers/notice_page_clear_events.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/notice/widgets/review_pending_dialog.dart';

class _FakeNoticeRepository implements NoticeRepository {
  final List<String> snoozedIds = [];
  final List<String> readIds = [];
  final List<String> acknowledgedIds = [];
  final Map<String, Notice> noticesById = {};
  List<PendingReviewStatus>? statusResult;
  Object? acknowledgeError;

  @override
  Future<void> snooze(String id, {int minutes = 15}) async {
    snoozedIds.add(id);
  }

  @override
  Future<Notice> acknowledge(String id) async {
    if (acknowledgeError != null) throw acknowledgeError!;
    acknowledgedIds.add(id);
    return noticesById[id]!.copyWith(myAcked: true);
  }

  @override
  Future<List<Notice>> pendingPopups() async => const [];

  @override
  Future<List<PendingReviewStatus>> pendingReviewStatus(
    List<String> ids,
  ) async =>
      statusResult ??
      [
        for (final id in ids)
          PendingReviewStatus(noticeId: id, resolved: false),
      ];

  @override
  Future<List<Notice>> pendingReviews() async => const [];

  @override
  Future<Notice> markRead(String id) async {
    readIds.add(id);
    return noticesById[id]!;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(resetReviewPendingDialogForTest);
  test('expense correction returns to the applicant workbench', () {
    expect(workbenchRouteFor('EXPENSE_CLAIM_REJECTED'), RouteName.expense);
    expect(workbenchRouteFor('EXPENSE_CLAIM_SUBMITTED'), '/expense/approval');
    expect(
      workbenchRouteFor('EXPENSE_CLAIM_PENDING_PAYMENT'),
      '/expense/approval',
    );
  });

  test('production workshop tasks use their dedicated workbench route', () {
    expect(
      workbenchRouteFor('PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'),
      RouteName.productionWorkshopTasks,
    );
  });

  test(
    'production rate and material approvals use their exact queues and read scopes',
    () {
      for (final entry in [
        (
          'PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED',
          RouteName.productionOverproductionRateRequests,
        ),
        (
          'PRODUCTION_MATERIAL_INCREMENT_SUBMITTED',
          RouteName.productionMaterialIncrementRequests,
        ),
      ]) {
        expect(
          workbenchRouteFor(entry.$1, actionRoute: '/dashboard'),
          entry.$2,
        );
        expect(noticeClearEventsForLocation(entry.$2), contains(entry.$1));
        expect(
          noticeClearEventsForLocation('${entry.$2}/request-1'),
          contains(entry.$1),
        );
      }
    },
  );

  test(
    'quote finance review notice lands on the quote review queue (ADR-134)',
    () {
      const event = 'SALES_QUOTE_PENDING_FINANCE_REVIEW';
      expect(
        workbenchRouteFor(event, actionRoute: '/finance/quote-review/q-1'),
        RouteName.financeQuoteReview,
      );
      expect(
        noticeClearEventsForLocation(RouteName.financeQuoteReview),
        contains(event),
      );
      expect(
        noticeClearEventsForLocation('${RouteName.financeQuoteReview}/q-1'),
        contains(event),
      );
    },
  );

  // ADR-117：车间催计划的待办卡直落被催的那一份物料分析；只认物料分析页自己的
  // 深链，别的 actionRoute(被篡改或旧数据)一律回落到物料分析首页。
  test('workshop planning urge lands on the urged material analysis', () {
    expect(
      workbenchRouteFor(
        'PRODUCTION_PLANNING_URGED',
        actionRoute: '${RouteName.productionMaterialAnalysis}?analysisId=a-1',
      ),
      '${RouteName.productionMaterialAnalysis}?analysisId=a-1',
    );
    expect(
      workbenchRouteFor('PRODUCTION_PLANNING_URGED'),
      RouteName.productionMaterialAnalysis,
    );
    expect(
      workbenchRouteFor(
        'PRODUCTION_PLANNING_URGED',
        actionRoute: '/admin/users?x=1',
      ),
      RouteName.productionMaterialAnalysis,
    );
  });

  test(
    'expanded review events land in real task pages after inbox retirement',
    () {
      expect(
        workbenchRouteFor('PROCUREMENT_FINANCE_CHANGE_SUBMITTED'),
        '/finance/procurement-approvals',
      );
      expect(
        workbenchRouteFor('SALES_ORDER_APPROVED'),
        RouteName.productionMaterialAnalysis,
      );
      expect(
        workbenchRouteFor('SUBCONTRACT_DRAW_AVAILABLE'),
        RouteName.operationsSubcontractDrawSegment(),
      );
      expect(
        workbenchRouteFor(
          'SUBCONTRACT_DRAW_AVAILABLE',
          actionRoute: RouteName.operationsSubcontractDrawSegment(
            orderItemId: 'item-1',
          ),
        ),
        RouteName.operationsSubcontractDrawSegment(orderItemId: 'item-1'),
      );
      // ADR-156 委外可下单：落「待处理」分段，通知自带申请号时沿用。
      expect(
        workbenchRouteFor('SUBCONTRACT_ORDER_KIT_READY'),
        RouteName.operationsSubcontractPendingSegment(),
      );
      expect(
        workbenchRouteFor(
          'SUBCONTRACT_ORDER_KIT_READY',
          actionRoute:
              '/operations/workbench/subcontract?segment=pending&keyword=EB-001',
        ),
        '/operations/workbench/subcontract?segment=pending&keyword=EB-001',
      );
      expect(
        workbenchRouteFor('SUBCONTRACT_OUTBOUND_READY'),
        RouteName.warehouseSubcontractOutbound,
      );
      expect(
        workbenchRouteFor('PRODUCTION_DRAW_PENDING'),
        RouteName.warehouseDrawTasks,
      );
      expect(
        workbenchRouteFor('PROCUREMENT_IQC_STOCK_IN_PENDING'),
        RouteName.warehouseQualityResults,
      );
      expect(
        workbenchRouteFor('PROCUREMENT_FINANCE_APPROVED'),
        RouteName.warehouseInboundTasks,
      );
      expect(
        workbenchRouteFor(
          'SALES_ORDER_PENDING_FINANCE_CONFIRM',
          actionRoute: '/finance/sales-order-changes',
        ),
        '/finance/sales-order-changes',
      );
      expect(workbenchRouteFor('UNKNOWN_EVENT'), RouteName.dashboard);
    },
  );

  test('hr events land on their approval queues, not the dashboard', () {
    // 2026-09-09/10 人事域弹卡（HrNoticeService）：6 个既有事件 + 工资待发布 + 建议待回复。
    expect(
      workbenchRouteFor('PROFILE_CHANGE_SUBMITTED'),
      '/hr/profile-changes',
    );
    expect(workbenchRouteFor('VISITOR_APPLY_SUBMITTED'), '/visitor-approval');
    expect(workbenchRouteFor('VISITOR_HOST_CONFIRM_REQUIRED'), '/my-visitors');
    expect(workbenchRouteFor('EXPENSE_CLAIM_SUBMITTED'), '/expense/approval');
    expect(
      workbenchRouteFor('EXPENSE_CLAIM_PENDING_PAYMENT'),
      '/expense/approval',
    );
    expect(workbenchRouteFor('PAYROLL_BATCH_SUBMITTED'), '/payroll/review');
    expect(
      workbenchRouteFor('PAYROLL_BATCH_PENDING_PUBLISH'),
      '/payroll/review',
    );
    expect(workbenchRouteFor('SUGGESTION_SUBMITTED'), RouteName.suggestion);
    expect(RouteName.suggestion, '/suggestion');
  });

  Notice noticeOf(
    String id, {
    String title = '待财务确认：SO-001',
    String? actionRoute,
    String sourceEvent = 'SALES_ORDER_PENDING_FINANCE_CONFIRM',
    String content = '销售订货单已审核，待财务确认。',
    NoticePriority priority = NoticePriority.normal,
    NoticeType type = NoticeType.approval,
  }) {
    return Notice(
      id: id,
      title: title,
      content: content,
      type: type,
      publisher: '系统',
      publishedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      isRead: false,
      priority: priority,
      interactive: true,
      actionRoute: actionRoute,
      sourceEvent: sourceEvent,
    );
  }

  /// 人工通知（人事手动发布）：公告类默认 acknowledge（打卡）；task 类 none（只提醒）。
  Notice manualOf(
    String id, {
    String title = '国庆放假安排',
    NoticeType type = NoticeType.announcement,
    NoticePriority priority = NoticePriority.normal,
  }) {
    return Notice(
      id: id,
      title: title,
      content: '10 月 1 日至 7 日放假，10 月 8 日正常上班。',
      type: type,
      publisher: '人事部',
      publishedAt: DateTime.now().subtract(const Duration(hours: 1)),
      isRead: false,
      priority: priority,
      interactionMode: type.interactionMode,
    );
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    required _FakeNoticeRepository repo,
    required List<Notice> pending,
    List<Notice> manual = const [],
    List<GoRoute> routes = const [],
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('home')),
        ...routes,
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [noticeRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp.router(
          routerConfig: router,
          // 根 Navigator context 由 showDialog 默认使用。
          // 分级徽章/计数用 AppLocalizations：测试固定 zh 便于中文断言。
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
        ),
      ),
    );
    for (final n in [...pending, ...manual]) {
      repo.noticesById[n.id] = n;
    }
    final context = tester.element(find.text('home'));
    unawaited(
      showReviewPendingDialog(context, pending: pending, manual: manual),
    );
    await tester.pumpAndSettle();
  }

  for (final entry in [
    (
      'PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED',
      RouteName.productionOverproductionRateRequests,
      '超产比例待审批',
      Icons.percent_rounded,
    ),
    (
      'PRODUCTION_MATERIAL_INCREMENT_SUBMITTED',
      RouteName.productionMaterialIncrementRequests,
      '追加用料待审批',
      Icons.playlist_add_check_rounded,
    ),
  ]) {
    testWidgets('${entry.$3} 单条和分组通知都进入对应审批队列', (tester) async {
      final repo = _FakeNoticeRepository();
      await pumpDialog(
        tester,
        repo: repo,
        pending: [noticeOf('review-1', title: '本次申请', sourceEvent: entry.$1)],
        routes: [GoRoute(path: entry.$2, builder: (_, _) => Text(entry.$3))],
      );
      expect(find.byIcon(entry.$4), findsOneWidget);
      await tester.tap(find.text('去工作台处理'));
      await tester.pumpAndSettle();
      expect(find.text(entry.$3), findsOneWidget);
      expect(repo.readIds, ['review-1']);

      resetReviewPendingDialogForTest();
      final groupedRepo = _FakeNoticeRepository();
      await pumpDialog(
        tester,
        repo: groupedRepo,
        pending: [
          noticeOf('review-2', title: '生产申请', sourceEvent: entry.$1),
          noticeOf('finance', title: '财务申请'),
        ],
        routes: [GoRoute(path: entry.$2, builder: (_, _) => Text(entry.$3))],
      );
      // ADR-163：头部摘要为分级计数（两条均 approval+normal → 待办 2，
      // 2026-10-06 修订：审批类不因 normal 降进度级），不再是事件域 chips。
      expect(find.text('待办 2'), findsOneWidget);
      await tester.tap(find.text('生产申请'));
      await tester.pumpAndSettle();
      expect(find.text(entry.$3), findsOneWidget);
      expect(groupedRepo.readIds, ['review-2'], reason: '点击单条不把另一个业务事件当作已处理');
    });
  }

  testWidgets('委外可下单卡直落任务中心「待处理」并带申请号', (tester) async {
    const route =
        '/operations/workbench/subcontract?segment=pending&keyword=EB-001';
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf(
          'kit-1',
          title: '委外可下单：EB-001 委外件 可下单 4 件',
          sourceEvent: 'SUBCONTRACT_ORDER_KIT_READY',
          actionRoute: route,
        ),
        noticeOf('finance', title: '财务申请'),
      ],
      routes: [
        GoRoute(
          path: RouteName.operationsSubcontractWorkbench,
          builder: (_, state) => Text(
            '任务中心 ${state.uri.queryParameters['segment']} '
            '${state.uri.queryParameters['keyword']}',
          ),
        ),
      ],
    );
    // ADR-163：两条 approval+normal 待办的头部摘要是「待办 2」分级计数
    // （2026-10-06 修订：审批类一律行动级）。
    expect(find.text('待办 2'), findsOneWidget);
    await tester.tap(find.text('委外可下单：EB-001 委外件 可下单 4 件'));
    await tester.pumpAndSettle();
    expect(find.text('任务中心 pending EB-001'), findsOneWidget);
    expect(repo.readIds, ['kit-1']);
  });

  for (final grouped in [false, true]) {
    testWidgets(
      'workshop material progress remains complete in ${grouped ? 'grouped' : 'single'} popup',
      (tester) async {
        const content =
            'A 物料本次到货 100 件，尚缺 900 件。\n'
            'B 物料尚缺 1000 件。\n'
            '仓库料请先领取，直送料按交接投入。\n'
            '两种物料共同支持产量后才能开工；进行中请继续领料。';
        final repo = _FakeNoticeRepository();
        await pumpDialog(
          tester,
          repo: repo,
          pending: [
            noticeOf(
              'workshop',
              title: '车间物料到货',
              sourceEvent: 'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED',
              content: content,
            ),
            if (grouped) noticeOf('finance'),
          ],
        );
        final text = tester.widget<Text>(find.text(content));
        expect(text.maxLines, isNull);
        expect(text.overflow, isNot(TextOverflow.ellipsis));
        expect(find.text('去工作台处理'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  // ---------------- 人工通知（人事/公司通知）分组（2026-09-10，ADR-063 §8）----------------

  testWidgets(
    'manual acknowledge card shows 打卡确认 and disappears after acknowledging',
    (tester) async {
      final repo = _FakeNoticeRepository();
      await pumpDialog(
        tester,
        repo: repo,
        pending: [],
        manual: [manualOf('m1')],
      );

      // 只有人工通知：标题「登录提醒」、无「去工作台处理」、条目带打卡按钮。
      expect(find.text('登录提醒'), findsOneWidget);
      expect(find.text('待办提醒'), findsNothing);
      expect(find.text('有 1 条通知需要你确认'), findsOneWidget);
      expect(find.text('人事/公司通知 · 1'), findsOneWidget);
      expect(find.text('国庆放假安排'), findsOneWidget);
      expect(find.text('打卡确认'), findsOneWidget);
      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('知道了'), findsNothing);
      expect(find.text('去工作台处理'), findsNothing);
      expect(find.text('全部稍后再看'), findsOneWidget);

      await tester.tap(find.text('打卡确认'));
      await tester.pump();

      expect(repo.acknowledgedIds, ['m1']);
      expect(find.text('已打卡'), findsOneWidget);
      expect(find.text('打卡确认'), findsNothing);

      // 短暂展示「已打卡」后移除条目；全部处理完弹窗自关。
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.byType(ReviewPendingDialog), findsNothing);
      expect(repo.readIds, isEmpty, reason: '打卡不代行已读');
    },
  );

  testWidgets('manual none-mode card shows 知道了 which marks read and removes', (
    tester,
  ) async {
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [],
      manual: [manualOf('m2', type: NoticeType.task, title: '周五提交周报')],
    );

    expect(find.text('周五提交周报'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
    expect(find.text('打卡确认'), findsNothing);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    expect(repo.readIds, ['m2']);
    expect(repo.acknowledgedIds, isEmpty);
    expect(find.byType(ReviewPendingDialog), findsNothing);
  });

  testWidgets('acknowledge failure keeps the manual card for retry', (
    tester,
  ) async {
    final repo = _FakeNoticeRepository()
      ..acknowledgeError = Exception('network down');
    await pumpDialog(tester, repo: repo, pending: [], manual: [manualOf('m1')]);

    await tester.tap(find.text('打卡确认'));
    await tester.pumpAndSettle();

    expect(repo.acknowledgedIds, isEmpty);
    expect(find.text('打卡确认'), findsOneWidget);
    expect(find.text('已打卡'), findsNothing);
    expect(find.byType(ReviewPendingDialog), findsOneWidget);
  });

  testWidgets(
    'reviews plus manual notices share one dialog: 待办提醒 title, grouped, snooze all',
    (tester) async {
      // 列表分组标题在弹窗封顶高度内（ListView 惰性构建，默认 600 高屏
      // 只剩 ~160px 给列表）；用 1080p 视口让两组全部在树内可断言。
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FakeNoticeRepository();
      await pumpDialog(
        tester,
        repo: repo,
        pending: [noticeOf('n1')],
        manual: [
          manualOf('m3', priority: NoticePriority.urgent, title: '今日停电'),
        ],
      );

      // 有审核待办时保留原标题与主按钮；两组各有分组标题。
      expect(find.text('待办提醒'), findsOneWidget);
      expect(find.text('登录提醒'), findsNothing);
      expect(find.text('有 2 项事务等待你处理'), findsOneWidget);
      expect(find.text('人事/公司通知 · 1'), findsOneWidget);
      expect(find.text('待办审核 · 1'), findsOneWidget);
      expect(find.text('今日停电'), findsOneWidget);
      expect(find.text('待财务确认：SO-001'), findsOneWidget);
      expect(find.text('去工作台处理'), findsOneWidget);
      expect(find.text('打卡确认'), findsOneWidget);
      // 紧急人工通知带「紧急」红徽章（ADR-163 分级徽章）。
      expect(find.text('紧急'), findsOneWidget);
      // 头部分级计数：待办(approval+normal→行动 1，2026-10-06 修订) + 人工紧急(紧急 1)。
      expect(find.text('待办 1'), findsOneWidget);
      expect(find.text('紧急 1'), findsOneWidget);

      await tester.tap(find.text('全部稍后再看'));
      await tester.pumpAndSettle();

      expect(repo.snoozedIds, containsAll(['n1', 'm3']));
      expect(repo.readIds, isEmpty);
      expect(find.byType(ReviewPendingDialog), findsNothing);
    },
  );

  testWidgets('manual notices render within a 375px-wide viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [],
      manual: [manualOf('m1', priority: NoticePriority.important)],
    );

    expect(tester.takeException(), isNull);
    expect(find.text('打卡确认'), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    // ADR-163：人工 important 不再显示旧「重要」徽章，归广播级「公告」。
    expect(find.text('重要'), findsNothing);
    expect(find.text('公告'), findsOneWidget);
  });

  testWidgets('renders single pending item with claim chip', (tester) async {
    final repo = _FakeNoticeRepository();
    await pumpDialog(tester, repo: repo, pending: [noticeOf('n1')]);

    expect(find.text('待办提醒'), findsOneWidget);
    expect(find.text('有 1 项事务等待你处理'), findsOneWidget);
    expect(find.text('待财务确认：SO-001'), findsOneWidget);
    expect(find.text('待处理'), findsOneWidget);
    expect(find.text('去工作台处理'), findsOneWidget);
    expect(find.text('全部稍后再看'), findsOneWidget);
  });

  testWidgets('renders multiple items and claim status from heartbeat', (
    tester,
  ) async {
    final repo = _FakeNoticeRepository()
      ..statusResult = [
        const PendingReviewStatus(noticeId: 'n1', resolved: false),
        const PendingReviewStatus(
          noticeId: 'n2',
          resolved: false,
          claimedByName: '张三',
        ),
      ];
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf('n1'),
        noticeOf('n2', title: '到货 IQC 待检：CR-005'),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('有 2 项事务等待你处理'), findsOneWidget);
    expect(find.text('到货 IQC 待检：CR-005'), findsOneWidget);
    expect(find.text('待处理'), findsOneWidget);
    expect(find.text('张三 正在审核'), findsOneWidget);
    expect(find.text('去工作台处理'), findsOneWidget);
    expect(find.text('全部稍后再看'), findsOneWidget);
  });

  testWidgets('snooze all only snoozes every item (no markRead) and closes', (
    tester,
  ) async {
    // 2026-09-10：稍后再看只调 snooze（服务端顺带置已读）；并发再调 markRead
    // 会把刚写的 snoozed_until 冲掉，「稍后」就永远不会再弹。
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf('n1'),
        noticeOf('n2', title: '第二项'),
      ],
    );

    await tester.tap(find.text('全部稍后再看'));
    await tester.pumpAndSettle();

    expect(repo.snoozedIds, containsAll(['n1', 'n2']));
    expect(repo.readIds, isEmpty);
    expect(find.text('待办提醒'), findsNothing);
  });

  testWidgets('primary button goes to the domain workbench even for one item', (
    tester,
  ) async {
    // 第四轮口径：主按钮不再直达单据详情，一律去任务工作台
    // （单条也去——行为统一，处理在工作台做）。
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf('n1', actionRoute: '/finance/sales-order-confirmations/abc'),
      ],
      routes: [
        GoRoute(
          path: '/finance/sales-order-confirmations',
          builder: (_, _) => const Text('财务确认工作台'),
        ),
      ],
    );

    await tester.tap(find.text('去工作台处理'));
    await tester.pumpAndSettle();

    expect(find.text('财务确认工作台'), findsOneWidget);
    expect(find.text('待办提醒'), findsNothing);
    expect(repo.readIds, contains('n1'));
  });

  testWidgets('primary button goes to dashboard when items span domains', (
    tester,
  ) async {
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf('n1'),
        noticeOf(
          'n2',
          title: '到货 IQC 待检：CR-005',
          sourceEvent: 'PROCUREMENT_IQC_PENDING',
        ),
      ],
      routes: [
        GoRoute(
          path: RouteName.dashboard,
          builder: (_, _) => const Text('工作台任务'),
        ),
      ],
    );

    await tester.tap(find.text('去工作台处理'));
    await tester.pumpAndSettle();

    expect(find.text('工作台任务'), findsOneWidget);
    expect(repo.readIds, containsAll(['n1', 'n2']));
  });

  testWidgets('tapping a list row goes to that item domain workbench', (
    tester,
  ) async {
    // 混合列表里点具体行 → 该行所属域的工作台（比主按钮更精确的快捷通道）。
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf('n1'),
        noticeOf(
          'n2',
          title: '到货 IQC 待检：CR-005',
          sourceEvent: 'PROCUREMENT_IQC_PENDING',
        ),
      ],
      routes: [
        GoRoute(
          path: RouteName.qualityTaskCenter,
          builder: (_, _) => const Text('品质任务中心'),
        ),
      ],
    );

    await tester.tap(find.text('到货 IQC 待检：CR-005'));
    await tester.pumpAndSettle();

    expect(find.text('品质任务中心'), findsOneWidget);
    expect(repo.readIds, contains('n2'));
    expect(repo.readIds, isNot(contains('n1')));
  });

  testWidgets('new arrivals merge into the open dialog, not a second layer', (
    tester,
  ) async {
    final repo = _FakeNoticeRepository();
    await pumpDialog(tester, repo: repo, pending: [noticeOf('n1')]);

    // 已打开时再次调用：并入当前弹窗（「一共有 2 项」），不叠第二层。
    final context = tester.element(find.text('待办提醒'));
    repo.noticesById['n2'] = noticeOf('n2', title: '第二项');
    await showReviewPendingDialog(
      context,
      pending: [noticeOf('n2', title: '第二项')],
    );
    await tester.pumpAndSettle();

    expect(find.text('待办提醒'), findsOneWidget);
    expect(find.text('有 2 项事务等待你处理'), findsOneWidget);
    expect(find.text('第二项'), findsOneWidget);
  });

  testWidgets('single item card hugs content without blank space', (
    tester,
  ) async {
    // 回归（2026-09-03）：大卡内部 Column 曾缺 mainAxisSize.min，在 Flexible
    // 的 loose 约束下占满剩余高度——1080p 上单条弹窗被拉到 560 上限，
    // 内容下一大片空白。修复后卡片高度贴合内容（约 300）。
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeNoticeRepository();
    await pumpDialog(tester, repo: repo, pending: [noticeOf('n1')]);

    final cardSize = tester.getSize(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    expect(cardSize.height, lessThan(450));
    expect(cardSize.height, greaterThan(200));
  });

  testWidgets('many items cap dialog height and scroll inside the list', (
    tester,
  ) async {
    // 高度随内容自适应、封顶 min(60% 屏高, 560)（默认测试屏 800x600 → 360），
    // 不再被列表内容拉到接近全屏；超出部分在列表内部滚动可达。
    final repo = _FakeNoticeRepository();
    // type=task 钉回进度级紧凑行：本用例按 dense 行高校准（2026-10-06 修订后
    // approval 默认归行动级行，行高变化会影响滚动断言的几何校准）。
    final pending = [
      for (var i = 0; i < 30; i++)
        noticeOf('n$i', title: '待办事项 #$i', type: NoticeType.task),
    ];
    await pumpDialog(tester, repo: repo, pending: pending);

    // Dialog 内部是全屏 Align（居中用），可见卡片高度量 Material
    // （最外层那个——按钮等子组件也含 Material，故取 first）。
    final cardSize = tester.getSize(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    expect(cardSize.height, lessThanOrEqualTo(600 * 0.6));
    // 头部与操作按钮始终可见（不被列表挤掉）。
    expect(find.text('有 30 项事务等待你处理'), findsOneWidget);
    expect(find.text('去工作台处理'), findsOneWidget);
    // 最后一项初始在视口外，列表内部可滚动直达（不被裁掉丢失）。
    final lastItem = find.text('待办事项 #29');
    expect(lastItem.hitTestable(), findsNothing);
    await tester.scrollUntilVisible(
      lastItem,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(lastItem.hitTestable(), findsOneWidget);
  });

  // ---------------- 分级体系（2026-10-06，ADR-163）----------------

  /// 取标题文本所属卡片（唯一 Container 祖先）的 BoxDecoration。
  BoxDecoration decorationOfCard(WidgetTester tester, String title) {
    final container = tester.widget<Container>(
      find
          .ancestor(of: find.text(title), matching: find.byType(Container))
          .first,
    );
    return container.decoration! as BoxDecoration;
  }

  testWidgets('urgent review renders red card with 紧急 badge and sorts first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        // task+normal → 进度级（2026-10-06 修订后 approval 默认归行动级，
        // 用 task 类型保留本用例的进度级卡位）。
        noticeOf('normal-1', title: '普通进度待办', type: NoticeType.task),
        noticeOf(
          'urgent-1',
          title: '委外短交预警：WO-009',
          priority: NoticePriority.urgent,
        ),
        noticeOf(
          'action-1',
          title: '重要行动待办',
          priority: NoticePriority.important,
        ),
      ],
    );

    final scheme = Theme.of(tester.element(find.text('待办提醒'))).colorScheme;

    // 红卡三重编码：紧急徽章（红底白字图标+文字）+ error 描边 1.5 + error 标题。
    expect(find.text('紧急'), findsOneWidget);
    expect(find.byIcon(Icons.priority_high_rounded), findsOneWidget);
    final urgentCard = decorationOfCard(tester, '委外短交预警：WO-009');
    expect(urgentCard.border!.top.color, scheme.error);
    expect(urgentCard.border!.top.width, 1.5);
    expect(urgentCard.color, scheme.errorContainer.withValues(alpha: 0.45));
    final urgentTitle = tester.widget<Text>(find.text('委外短交预警：WO-009'));
    expect(urgentTitle.style?.color, scheme.error);
    expect(urgentTitle.style?.fontWeight, FontWeight.w700);
    // 非 urgent 条目无描边。
    expect(decorationOfCard(tester, '普通进度待办').border, isNull);

    // 排序置顶：urgent < action < progress（同一列表内的纵向位置）。
    final urgentTop = tester.getTopLeft(find.text('委外短交预警：WO-009')).dy;
    final actionTop = tester.getTopLeft(find.text('重要行动待办')).dy;
    final progressTop = tester.getTopLeft(find.text('普通进度待办')).dy;
    expect(urgentTop, lessThan(actionTop));
    expect(actionTop, lessThan(progressTop));
  });

  testWidgets(
    'same sourceEvent splits into 行动/进度 levels by priority (ADR-163)',
    (tester) async {
      // 车间物料事件同源不同级：「可开工行动卡」important=行动(teal)、
      // 「到货进展」normal=进度(info 蓝)。
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FakeNoticeRepository();
      await pumpDialog(
        tester,
        repo: repo,
        pending: [
          noticeOf(
            'progress-1',
            title: '物料到货进展：A 件到货 100',
            sourceEvent: 'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED',
            content: 'A 物料本次到货 100 件，尚缺 900 件。',
            type: NoticeType.task,
          ),
          noticeOf(
            'action-1',
            title: '可开工行动卡：B 件',
            sourceEvent: 'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED',
            content: '两种物料共同支持产量后才能开工。',
            priority: NoticePriority.important,
            type: NoticeType.task,
          ),
        ],
      );

      // 徽章文字分档（不只靠颜色）。
      expect(find.text('待办'), findsOneWidget);
      expect(find.text('进度'), findsOneWidget);
      // 行动级(teal)与进度级(info 蓝)徽章图标色分档。
      final scheme = Theme.of(tester.element(find.text('待办提醒'))).colorScheme;
      final actionBadgeIcon = tester.widget<Icon>(
        find.byIcon(Icons.task_alt_rounded),
      );
      final progressBadgeIcon = tester.widget<Icon>(
        find.byIcon(Icons.trending_up_rounded),
      );
      expect(actionBadgeIcon.color, scheme.onPrimaryContainer);
      expect(progressBadgeIcon.color, UtenColors.onInfoContainer);
      expect(actionBadgeIcon.color, isNot(equals(progressBadgeIcon.color)));
      // 行动卡排序在进度卡之前。
      expect(
        tester.getTopLeft(find.text('可开工行动卡：B 件')).dy,
        lessThan(tester.getTopLeft(find.text('物料到货进展：A 件到货 100')).dy),
      );
    },
  );

  testWidgets(
    'manual notices: broadcast amber card and manual urgent red border',
    (tester) async {
      // 人工组：普通公告=广播级暖色底；人工紧急=红系强化并置组首。
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FakeNoticeRepository();
      await pumpDialog(
        tester,
        repo: repo,
        pending: [],
        manual: [
          manualOf('m-normal'), // 默认标题「国庆放假安排」
          manualOf(
            'm-urgent',
            priority: NoticePriority.urgent,
            title: '今日停电通知',
          ),
        ],
      );

      final scheme = Theme.of(tester.element(find.text('登录提醒'))).colorScheme;

      expect(find.text('公告'), findsOneWidget);
      expect(find.text('紧急'), findsOneWidget);
      // 广播级卡片 = 暖色容器（amber，与 error 红拉开色相）。
      final broadcastCard = decorationOfCard(tester, '国庆放假安排');
      expect(broadcastCard.color, UtenColors.broadcastContainer);
      expect(broadcastCard.border, isNull);
      // 人工紧急 = errorContainer 底 + 1.5px error 描边（红系强化）。
      final urgentCard = decorationOfCard(tester, '今日停电通知');
      expect(urgentCard.color, scheme.errorContainer.withValues(alpha: 0.45));
      expect(urgentCard.border!.top.color, scheme.error);
      expect(urgentCard.border!.top.width, 1.5);
      // 组内排序：urgent 人工条目置组首。
      expect(
        tester.getTopLeft(find.text('今日停电通知')).dy,
        lessThan(tester.getTopLeft(find.text('国庆放假安排')).dy),
      );
      // 头部分级计数带各级色点。
      expect(find.text('紧急 1'), findsOneWidget);
      expect(find.text('公告 1'), findsOneWidget);
    },
  );

  testWidgets('header summary counts every level with colored dots', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf('u1', title: '紧急卡', priority: NoticePriority.urgent),
        noticeOf('a1', title: '行动卡', priority: NoticePriority.important),
        noticeOf('p1', title: '进度卡', type: NoticeType.task),
      ],
      manual: [manualOf('m1', title: '公告卡')],
    );

    expect(find.text('紧急 1'), findsOneWidget);
    expect(find.text('待办 1'), findsOneWidget);
    expect(find.text('进度 1'), findsOneWidget);
    expect(find.text('公告 1'), findsOneWidget);
    // 待办审核组在前、人事广播组在后（ADR-163 排序：broadcast 垫底）。
    expect(
      tester.getTopLeft(find.text('待办审核 · 3')).dy,
      lessThan(tester.getTopLeft(find.text('人事/公司通知 · 1')).dy),
    );
  });

  // ---------------- 2026-10-06 修订：审批/工作流类一律行动级 ----------------

  testWidgets(
    'approval-type normal-priority notice renders action badge, not progress',
    (tester) async {
      // SALES_ORDER_PENDING_FINANCE_CONFIRM 等审批事件后端多标 priority=normal，
      // 但语义是「待我决定」的强待办——修订后不落最低权重的进度级。
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FakeNoticeRepository();
      await pumpDialog(
        tester,
        repo: repo,
        pending: [
          // noticeOf 默认 type=approval、priority=normal。
          noticeOf('approval-1'),
          // 对照组：task+normal 仍为进度级。
          noticeOf(
            'progress-1',
            title: '物料到货进展：A 件到货 100',
            sourceEvent: 'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED',
            type: NoticeType.task,
          ),
        ],
      );

      // 行动级「待办」徽章 + 进度级「进度」徽章各一；审批卡排序在进度卡前。
      expect(find.text('待办'), findsOneWidget);
      expect(find.text('进度'), findsOneWidget);
      expect(find.byIcon(Icons.task_alt_rounded), findsOneWidget);
      expect(find.byIcon(Icons.trending_up_rounded), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('待财务确认：SO-001')).dy,
        lessThan(tester.getTopLeft(find.text('物料到货进展：A 件到货 100')).dy),
      );
    },
  );

  testWidgets('workflow-type normal-priority notice renders action badge', (
    tester,
  ) async {
    // 流程类（type=workflow）与审批类同口径：priority=normal 也不降进度级。
    final repo = _FakeNoticeRepository();
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf(
          'workflow-1',
          title: '流程节点完成：PO-012',
          type: NoticeType.workflow,
        ),
      ],
    );

    expect(find.text('待办'), findsOneWidget);
    expect(find.text('进度'), findsNothing);
    expect(find.byIcon(Icons.task_alt_rounded), findsOneWidget);
    expect(find.byIcon(Icons.trending_up_rounded), findsNothing);
  });

  test('sortByReviewLevel keeps arrival order within the same level', () {
    // [List.sort] 不稳定；sortByReviewLevel 以 (级别, 原始下标) 排序——
    // 同级条目无论乱序到达还是混合级插入，都保持到达顺序（稳定不变量）。
    final items = [
      noticeOf('a-2'), // approval+normal → 行动级
      noticeOf('p-1', type: NoticeType.task), // task+normal → 进度级
      noticeOf('a-1'), // 行动级
      noticeOf('u-1', priority: NoticePriority.urgent), // 紧急级
      noticeOf('a-3'), // 行动级
    ];
    final sorted = sortByReviewLevel(items);
    expect(sorted.map((n) => n.id).toList(), [
      'u-1', // 紧急置顶
      'a-2',
      'a-1',
      'a-3', // 行动级三条保持到达序
      'p-1', // 进度垫底
    ]);
  });
}
