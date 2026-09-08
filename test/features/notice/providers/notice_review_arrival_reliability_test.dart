import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_arrival.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/notice/widgets/review_pending_dialog.dart';

class _StatusRepository implements NoticeRepository {
  final batches = <List<String>>[];
  int failures = 0;
  Completer<List<PendingReviewStatus>>? delayed;

  @override
  Future<List<PendingReviewStatus>> pendingReviewStatus(
    List<String> ids,
  ) async {
    batches.add(List.of(ids));
    if (failures > 0) {
      failures--;
      throw StateError('temporary connection failure');
    }
    if (delayed case final response?) return response.future;
    return [
      for (final id in ids) PendingReviewStatus(noticeId: id, resolved: false),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements NoticeArrivalCursorStore {
  NoticeArrivalCursor? cursor;
  Set<String> delivered = {};
  @override
  Future<NoticeArrivalCursor?> read(String identityKey) async => cursor;
  @override
  Future<Set<String>> readDeliveredIds(String identityKey) async =>
      Set.of(delivered);
  @override
  Future<void> write(
    String identityKey,
    NoticeArrivalCursor cursor,
    Set<String> ids,
  ) async {
    this.cursor = cursor;
    delivered = Set.of(ids);
  }
}

Notice _notice(String id, int minute, {bool interactive = false}) => Notice(
  id: id,
  title: '本地测试待办 $id',
  content: '待财务核对',
  type: interactive ? NoticeType.approval : NoticeType.task,
  publisher: '系统',
  publishedAt: DateTime.utc(2026, 9, 7, 1, minute),
  isRead: false,
  interactive: interactive,
  sourceEvent: interactive ? 'SALES_ORDER_PENDING_FINANCE_CONFIRM' : null,
  actionRoute: '/finance/sales-order-confirmations',
);

NoticeArrivalCursor _cursor(Notice notice) =>
    NoticeArrivalCursor(publishedAt: notice.publishedAt, id: notice.id);

void main() {
  setUp(resetReviewPendingDialogForTest);

  test(
    'simultaneous status checks use bounded batches and preserve each id',
    () async {
      final repository = _StatusRepository();
      final container = ProviderContainer(
        overrides: [noticeRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final load = container.read(noticeReviewArrivalStatusProvider);
      final values = await Future.wait([
        for (var i = 0; i < 120; i++) load('notice-$i'),
        load('notice-0'),
      ]);
      expect(repository.batches.map((batch) => batch.length), [50, 50, 20]);
      expect(values.map((value) => value?.noticeId), [
        for (var i = 0; i < 120; i++) 'notice-$i',
        'notice-0',
      ]);
    },
  );

  test(
    'a failed burst is not cached as resolved and a later request recovers',
    () async {
      final repository = _StatusRepository()..failures = 1;
      final container = ProviderContainer(
        overrides: [noticeRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final load = container.read(noticeReviewArrivalStatusProvider);
      await expectLater(
        Future.wait([for (var i = 0; i < 120; i++) load('n-$i')]),
        throwsStateError,
      );
      expect(repository.batches, hasLength(1));
      expect((await load('n-0'))?.resolved, isFalse);
      expect(repository.batches, hasLength(2));
    },
  );

  testWidgets('review arrives before a slow later audit page finishes', (
    tester,
  ) async {
    final normal = _notice('normal', 1);
    final review = _notice('review', 2, interactive: true);
    final tail = _notice('tail', 3);
    final laterPage = Completer<NoticeArrivalPage>();
    final arrived = <String>[];
    final store = _Store();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          noticeArrivalCursorStoreProvider.overrideWithValue(store),
          noticeArrivalRefreshProvider.overrideWithValue(() async {}),
          noticeArrivalLoaderProvider.overrideWithValue((after) async {
            if (after == null) {
              return NoticeArrivalPage(
                items: [normal, review],
                cursor: _cursor(review),
                hasMore: true,
              );
            }
            return laterPage.future;
          }),
        ],
        child: MaterialApp(
          home: NoticeArrivalListener(
            identityKey: 'finance',
            onArrival: (_, notice, delivered) {
              arrived.add(notice.id);
              delivered();
            },
            child: const Text('工作台'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(arrived, ['review']);
    expect(laterPage.isCompleted, isFalse);
    laterPage.complete(
      NoticeArrivalPage(items: [tail], cursor: _cursor(tail), hasMore: false),
    );
    await tester.pump();
    expect(arrived, ['review', 'normal', 'tail']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'temporary review check failure retries without falsely acknowledging delivery',
    (tester) async {
      final repository = _StatusRepository()..failures = 1;
      final store = _Store();
      final review = _notice('review', 2, interactive: true);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: Stack(
                children: [
                  NoticeArrivalListener(
                    identityKey: 'finance',
                    child: Text('工作台'),
                  ),
                  AppNotificationHost(),
                ],
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            noticeRepositoryProvider.overrideWithValue(repository),
            noticeArrivalCursorStoreProvider.overrideWithValue(store),
            noticeArrivalRefreshProvider.overrideWithValue(() async {}),
            noticeArrivalLoaderProvider.overrideWithValue(
              (after) async => NoticeArrivalPage(
                items: after == null ? [review] : [],
                cursor: _cursor(review),
                hasMore: false,
              ),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      expect(repository.batches, hasLength(1));
      expect(find.byType(ReviewPendingDialog), findsNothing);
      expect(store.delivered, isEmpty);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(repository.batches, hasLength(1));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byType(ReviewPendingDialog), findsOneWidget);
      expect(find.text(review.title), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late status proof cannot open a popup after its identity generation ended',
    (tester) async {
      final repository = _StatusRepository()
        ..delayed = Completer<List<PendingReviewStatus>>();
      var current = true;
      var delivered = 0;
      late BuildContext context;
      final review = _notice('private-old', 2, interactive: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [noticeRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Builder(
              builder: (value) {
                context = value;
                return const Text('工作台');
              },
            ),
          ),
        ),
      );
      final pending = dispatchReviewCard(
        context,
        review,
        kind: AppNotificationKind.info,
        isCurrent: () => current,
        onDelivered: () => delivered++,
      );
      await tester.pump();
      current = false;
      repository.delayed!.complete([
        PendingReviewStatus(noticeId: review.id, resolved: false),
      ]);
      await pending;
      await tester.pumpAndSettle();
      expect(find.byType(ReviewPendingDialog), findsNothing);
      expect(delivered, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
