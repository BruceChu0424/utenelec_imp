// ReviewPendingDialog（V459 居中审核弹窗）契约测试：
// - 渲染：标题/条数副标题/条目标题/认领状态 chip（待处理 vs XX 正在审核）；
// - 「稍后再看」：全部条目 snooze（15 分钟）+ 已读 + 关闭弹窗；
// - 「去审核」：标已读 + 跳 actionRoute + 关闭弹窗；
// - 弹窗单例守卫：已打开时再次调用为空操作。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

  Notice noticeOf(
    String id, {
    String title = '待财务确认：SO-001',
    String? actionRoute,
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
      sourceEvent: 'SALES_ORDER_PENDING_FINANCE_CONFIRM',
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

    expect(find.text('待办审核'), findsOneWidget);
    expect(find.text('有 1 项事务等待你处理'), findsOneWidget);
    expect(find.text('待财务确认：SO-001'), findsOneWidget);
    expect(find.text('待处理'), findsOneWidget);
    expect(find.text('去审核'), findsOneWidget);
    expect(find.text('稍后再看'), findsOneWidget);
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
    expect(find.text('去处理第一条'), findsOneWidget);
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
    expect(find.text('待办审核'), findsNothing);
  });

  testWidgets('review navigates to the action route', (tester) async {
    final repo = _FakeNoticeRepository();
    var reviewOpened = false;
    await pumpDialog(
      tester,
      repo: repo,
      pending: [
        noticeOf('n1', actionRoute: '/finance/sales-order-confirmations/abc'),
      ],
      routes: [
        GoRoute(
          path: '/finance/sales-order-confirmations/:id',
          builder: (_, _) {
            reviewOpened = true;
            return const Scaffold(body: Text('审核页'));
          },
        ),
      ],
    );

    await tester.tap(find.text('去审核'));
    await tester.pumpAndSettle();

    expect(reviewOpened, isTrue);
    expect(find.text('待办审核'), findsNothing);
  });

  testWidgets('dialog is a singleton while open', (tester) async {
    final repo = _FakeNoticeRepository();
    await pumpDialog(tester, repo: repo, pending: [noticeOf('n1')]);

    // 已打开时再次调用不叠加第二层弹窗。
    final context = tester.element(find.text('待办审核'));
    await showReviewPendingDialog(context, pending: [noticeOf('n2')]);
    await tester.pumpAndSettle();

    expect(find.text('待办审核'), findsOneWidget);
  });
}
