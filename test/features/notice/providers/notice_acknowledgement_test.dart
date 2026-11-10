import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/providers/notice_unread_index_provider.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../helpers/badge_summary_fixture.dart';

Notice _notice({bool read = false}) => Notice(
  id: 'n-1',
  title: '服务器有新版本',
  content: '系统更新通知',
  type: NoticeType.system,
  publisher: '系统',
  publishedAt: DateTime.utc(2026, 11, 3),
  isRead: read,
  myAcked: read,
  interactionMode: NoticeInteractionMode.acknowledge,
);

class _Repository implements NoticeRepository {
  final gate = Completer<Notice>();
  final markAllGate = Completer<void>();
  final deleteGate = Completer<int>();
  int listCalls = 0;
  int detailCalls = 0;

  @override
  Future<Notice> acknowledge(String id) => gate.future;

  @override
  Future<void> markAllRead() => markAllGate.future;

  @override
  Future<int> deleteMany(List<String> ids) => deleteGate.future;

  @override
  Future<List<Notice>> list({bool? onlyUnread, bool? importantOnly}) async {
    listCalls++;
    return [_notice()];
  }

  @override
  Future<Notice?> getById(String id) async {
    detailCalls++;
    return _notice();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Index extends NoticeUnreadIndexNotifier {
  @override
  NoticeUnreadIndex? build() => NoticeUnreadIndex(
    unreadCount: 2,
    digest: 1,
    items: [
      for (final id in ['n-1', 'n-2'])
        NoticeUnreadItem(id: id, publishedAt: DateTime.utc(2026, 11, 3)),
    ],
  );
}

void main() {
  for (final delete in [false, true]) {
    for (final changeSession in [false, true]) {
      testWidgets(
        'notice write survives source disposal: delete=$delete, changeSession=$changeSession',
        (tester) async {
          final session = StateProvider<AuthenticatedScope?>(
            (ref) => const AuthenticatedScope(userId: 'first'),
          );
          final repo = _Repository();
          final badges = FixedBadgeSummaryNotifier(badgeSummaryFixture());
          final container = ProviderContainer(
            overrides: [
              authenticatedScopeProvider.overrideWith(
                (ref) => ref.watch(session),
              ),
              noticeRepositoryProvider.overrideWithValue(repo),
              noticeUnreadIndexProvider.overrideWith(_Index.new),
              badgeSummaryProvider.overrideWith(() => badges),
            ],
          );
          addTearDown(container.dispose);
          late WidgetRef source;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: Consumer(
                builder: (context, ref, child) {
                  source = ref;
                  return const SizedBox.shrink();
                },
              ),
            ),
          );
          container.read(noticeUnreadIndexProvider);
          final pending = delete
              ? deleteNotices(source, ['n-1'])
              : markAllNoticeRead(source);
          await tester.pumpWidget(const SizedBox.shrink());
          if (changeSession) {
            container.read(session.notifier).state = const AuthenticatedScope(
              userId: 'second',
            );
          }
          if (delete) {
            repo.deleteGate.complete(1);
          } else {
            repo.markAllGate.complete();
          }
          await pending;
          expect(badges.refreshCalls, changeSession ? 0 : 1);
          expect(
            container.read(noticeUnreadIndexProvider)!.items,
            hasLength(!delete && !changeSession ? 0 : 2),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final outcome in ['success', 'failure', 'old-session', 'not-read']) {
    test('acknowledgement refreshes authoritative state: $outcome', () async {
      final session = StateProvider<AuthenticatedScope?>(
        (ref) => const AuthenticatedScope(userId: 'first'),
      );
      final repo = _Repository();
      final badges = FixedBadgeSummaryNotifier(badgeSummaryFixture());
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(session)),
          noticeRepositoryProvider.overrideWithValue(repo),
          noticeUnreadIndexProvider.overrideWith(_Index.new),
          badgeSummaryProvider.overrideWith(() => badges),
        ],
      );
      addTearDown(container.dispose);
      final list = container.listen(noticeListProvider, (_, _) {});
      final detail = container.listen(noticeDetailProvider('n-1'), (_, _) {});
      addTearDown(list.close);
      addTearDown(detail.close);
      await container.read(noticeListProvider.future);
      await container.read(noticeDetailProvider('n-1').future);
      container.read(noticeUnreadIndexProvider);

      final pending = acknowledgeNoticeContainer(container, 'n-1');
      expect(container.read(noticeUnreadIndexProvider)!.items, hasLength(2));
      expect(badges.refreshCalls, 0, reason: 'the request is still pending');
      if (outcome == 'old-session') {
        container.read(session.notifier).state = const AuthenticatedScope(
          userId: 'second',
        );
      }
      if (outcome == 'failure') {
        final failure = expectLater(pending, throwsStateError);
        repo.gate.completeError(StateError('offline'));
        await failure;
      } else {
        repo.gate.complete(_notice(read: outcome != 'not-read'));
        await pending;
      }
      await container.read(noticeListProvider.future);
      await container.read(noticeDetailProvider('n-1').future);

      final published = outcome == 'success' || outcome == 'not-read';
      // A new identity owns its own fresh list/detail; the old receipt must
      // neither refresh it again nor publish badge/index changes into it.
      final expectedReads = published || outcome == 'old-session' ? 2 : 1;
      expect(repo.listCalls, expectedReads);
      expect(repo.detailCalls, expectedReads);
      expect(badges.refreshCalls, published ? 1 : 0);
      expect(
        container.read(noticeUnreadIndexProvider)!.items.map((item) => item.id),
        outcome == 'success' ? ['n-2'] : ['n-1', 'n-2'],
        reason: 'only a current-session authoritative read removes an item',
      );
    });
  }
}
