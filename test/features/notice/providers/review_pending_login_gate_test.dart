import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/providers/review_pending_login_gate.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/notice/widgets/review_pending_dialog.dart';

class _Repository implements NoticeRepository {
  final requests = <Completer<List<Notice>>>[];

  @override
  Future<List<Notice>> pendingReviews() {
    final request = Completer<List<Notice>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<List<PendingReviewStatus>> pendingReviewStatus(
    List<String> ids,
  ) async => [
    for (final id in ids) PendingReviewStatus(noticeId: id, resolved: false),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(resetReviewPendingDialogForTest);

  testWidgets(
    'login checks within one second and retries a transient failure',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [noticeRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => ReviewPendingLoginGate(
                enabled: true,
                identityKey: 'finance',
                dialogContext: () => context,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(repository.requests, hasLength(1));
      repository.requests.single.completeError(
        StateError('temporary network failure'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(repository.requests, hasLength(2));
      repository.requests.last.complete([]);
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(
        repository.requests,
        hasLength(2),
        reason: 'successful empty result ends the login check',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('logout cancels the pending login timer before any request', (
    tester,
  ) async {
    final repository = _Repository();
    Future<void> render(bool enabled) => tester.pumpWidget(
      ProviderScope(
        overrides: [noticeRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => ReviewPendingLoginGate(
              enabled: enabled,
              identityKey: 'a',
              dialogContext: () => context,
            ),
          ),
        ),
      ),
    );
    await render(true);
    await tester.pump(const Duration(milliseconds: 100));
    await render(false);
    await tester.pump(const Duration(seconds: 4));
    expect(repository.requests, isEmpty);
  });

  testWidgets(
    'late previous-account response cannot show its confidential task',
    (tester) async {
      final repository = _Repository();
      Future<void> render(String identity) => tester.pumpWidget(
        ProviderScope(
          overrides: [noticeRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => ReviewPendingLoginGate(
                enabled: true,
                identityKey: identity,
                dialogContext: () => context,
              ),
            ),
          ),
        ),
      );
      await render('a');
      await tester.pump(const Duration(seconds: 3));
      expect(repository.requests, hasLength(1));
      await render('b');
      await tester.pump(const Duration(seconds: 3));
      expect(repository.requests, hasLength(2));
      repository.requests[1].complete([]);
      repository.requests[0].complete([
        Notice(
          id: 'old-task',
          title: 'A confidential order',
          content: 'private amount',
          type: NoticeType.approval,
          publisher: 'system',
          publishedAt: DateTime.now(),
          isRead: false,
          interactive: true,
          sourceEvent: 'SALES_ORDER_PENDING_FINANCE_CONFIRM',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('A confidential order'), findsNothing);
      expect(find.byType(ReviewPendingDialog), findsNothing);
    },
  );
}
