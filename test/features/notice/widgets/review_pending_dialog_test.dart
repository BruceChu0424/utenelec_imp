// ReviewPendingDialog（V459 居中审核弹窗）契约测试：
// - 渲染：标题/条数副标题/条目标题/认领状态 chip（待处理 vs XX 正在审核）；
// - 「稍后再看」：全部条目 snooze（15 分钟）+ 已读 + 关闭弹窗；
// - 「去工作台处理」（第四轮口径）：单条也去域工作台（不直达详情）；跨域
//   混合去待审收件台；点列表行去该行所属域工作台（仅该条已读）；
// - 新到待办并入已开弹窗（不叠第二层）；高度自适应 + 多条封顶滚动。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/notice/widgets/review_pending_dialog.dart';

class _FakeNoticeRepository implements NoticeRepository {
  final List<String> snoozedIds = [];
  final List<String> readIds = [];
  final Map<String, Notice> noticesById = {};
  List<PendingReviewStatus> statusResult = const [];

  @override
  Future<void> snooze(String id, {int minutes = 15}) async {
    snoozedIds.add(id);
  }

  @override
  Future<List<PendingReviewStatus>> pendingReviewStatus(
    List<String> ids,
  ) async => statusResult;

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

  test('production workshop tasks use their dedicated workbench route', () {
    expect(
      workbenchRouteFor('PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED'),
      RouteName.productionWorkshopTasks,
    );
  });

  Notice noticeOf(
    String id, {
    String title = '待财务确认：SO-001',
    String? actionRoute,
    String sourceEvent = 'SALES_ORDER_PENDING_FINANCE_CONFIRM',
  }) {
    return Notice(
      id: id,
      title: title,
      content: '销售订货单已审核，待财务确认。',
      type: NoticeType.approval,
      publisher: '系统',
      publishedAt: DateTime.now().subtract(const Duration(minutes: 2)),
      isRead: false,
      interactive: true,
      actionRoute: actionRoute,
      sourceEvent: sourceEvent,
    );
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    required _FakeNoticeRepository repo,
    required List<Notice> pending,
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
        ),
      ),
    );
    for (final n in pending) {
      repo.noticesById[n.id] = n;
    }
    final context = tester.element(find.text('home'));
    unawaited(showReviewPendingDialog(context, pending: pending));
    await tester.pumpAndSettle();
  }

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

  testWidgets('snooze all marks read, snoozes every item and closes', (
    tester,
  ) async {
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

  testWidgets('primary button goes to inbox when items span domains', (
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
          path: RouteName.reviewsInbox,
          builder: (_, _) => const Text('待审收件台'),
        ),
      ],
    );

    await tester.tap(find.text('去工作台处理'));
    await tester.pumpAndSettle();

    expect(find.text('待审收件台'), findsOneWidget);
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
    final pending = [
      for (var i = 0; i < 30; i++) noticeOf('n$i', title: '待办事项 #$i'),
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
}
