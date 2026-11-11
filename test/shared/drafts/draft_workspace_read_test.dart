import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_read.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';

void main() {
  test(
    'first page publishes while the same owner still completes all pages',
    () async {
      final later = Completer<PagedResult<int>>();
      final requested = <int>[];
      final read = DraftWorkspaceRead<int>(
        (owner) => owner.loadPages((page, size) {
          requested.add(page);
          return page == 1
              ? Future.value(
                  const PagedResult(
                    items: [1],
                    page: 1,
                    size: 1,
                    total: 2,
                    totalPages: 2,
                  ),
                )
              : later.future;
        }, (rows) async => rows),
      );
      addTearDown(read.dispose);
      var complete = false;
      unawaited(read.completion.then((_) => complete = true));
      read.start();
      await read.firstPage;
      expect(read.snapshot.rows, [1]);
      expect(read.snapshot.complete, isFalse);
      expect(complete, isFalse);
      final firstObserved = await read.snapshots.first;
      expect(firstObserved.rows, [1]);

      later.complete(
        const PagedResult(
          items: [2],
          page: 2,
          size: 1,
          total: 2,
          totalPages: 2,
        ),
      );
      expect(await read.completion, [1, 2]);
      expect(read.snapshot.complete, isTrue);
      expect(requested, [1, 2]);
    },
  );

  test(
    'later failure preserves accepted rows and rejects full completion',
    () async {
      final error = ApiException('OFFLINE', 'offline');
      final read = DraftWorkspaceRead<int>(
        (owner) => owner.loadPages(
          (page, size) async => page == 1
              ? const PagedResult(
                  items: [1],
                  page: 1,
                  size: 1,
                  total: 2,
                  totalPages: 2,
                )
              : throw error,
          (rows) async => rows,
        ),
      );
      addTearDown(read.dispose);
      read.start();
      await read.firstPage;
      // a7a54d709: real complete-read failures are rebuilt as a new base
      // ApiException with one anonymous correlation ref appended to the
      // message and kept in details, so identity is no longer the raw
      // thrown instance; code and base message must survive and both
      // surfaces must expose that one annotated failure.
      final thrown = await read.completion.then<Object>(
        (rows) => throw StateError('completion must reject: $rows'),
        onError: (Object e) => e,
      );
      final annotated = thrown as ApiException;
      expect(annotated.code, 'OFFLINE');
      final ref = annotated.details?['diagnosticRef'];
      expect(ref, isA<String>().having((r) => r.length, 'length', 6));
      expect(annotated.message, 'offline（关联号 $ref）');
      expect(read.snapshot.rows, [1]);
      expect(read.snapshot.complete, isFalse);
      expect(read.snapshot.loading, isFalse);
      expect(read.snapshot.error, same(annotated));
    },
  );

  test(
    'retirement cancels the same read predicate and never publishes its later rows',
    () async {
      final later = Completer<PagedResult<int>>();
      final predicates = <bool Function()>[];
      final read = DraftWorkspaceRead<int>(
        (owner) => owner.loadPages((page, size) {
          predicates.add(PagedReadIntent.currentRead!);
          return page == 1
              ? Future.value(
                  const PagedResult(
                    items: [1],
                    page: 1,
                    size: 1,
                    total: 2,
                    totalPages: 2,
                  ),
                )
              : later.future;
        }, (rows) async => rows),
      );
      read.start();
      await read.firstPage;
      expect(predicates.every((current) => current()), isTrue);
      read.dispose();
      await expectLater(read.completion, throwsA(isA<ApiException>()));
      expect(predicates.every((current) => !current()), isTrue);
      later.complete(
        const PagedResult(
          items: [2],
          page: 2,
          size: 1,
          total: 2,
          totalPages: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(read.snapshot.rows, [1]);
      expect(read.snapshot.complete, isFalse);
    },
  );

  test(
    'a capped page still reaches all ten thousand rows without a duplicate drain',
    () async {
      final requested = <int>[];
      final read = DraftWorkspaceRead<int>(
        (owner) => owner.loadPages((page, size) async {
          requested.add(page);
          return PagedResult(
            items: List.generate(100, (index) => (page - 1) * 100 + index),
            page: page,
            size: 100,
            total: 10000,
            totalPages: 100,
          );
        }, (rows) async => rows),
      );
      addTearDown(read.dispose);
      read.start();
      final first = read.firstPage;
      final all = read.completion;
      await first;
      expect(read.snapshot.rows.length, lessThan(10000));
      expect(await all, orderedEquals(List.generate(10000, (index) => index)));
      expect(
        requested,
        orderedEquals(List.generate(100, (index) => index + 1)),
      );
    },
  );

  for (final page in [1, 2]) {
    test(
      'an invalid empty page $page never claims a complete empty result',
      () async {
        final read = DraftWorkspaceRead<int>(
          (owner) => owner.loadPages(
            (requested, size) async => PagedResult<int>(
              items: requested < page ? [1] : [],
              page: requested,
              size: 1,
              total: 3,
              totalPages: 3,
            ),
            (rows) async => rows,
          ),
        );
        addTearDown(read.dispose);
        read.start();
        await expectLater(read.completion, throwsA(isA<ApiException>()));
        expect(read.snapshot.complete, isFalse);
        expect(read.snapshot.rows, page == 1 ? isEmpty : [1]);
      },
    );
  }

  test(
    'shifted pages with a repeated identity retain prior rows and require retry',
    () async {
      final read = DraftWorkspaceRead<int>(
        (owner) => owner.loadPages<int>(
          (page, size) async => PagedResult(
            items: const [1],
            page: page,
            size: 1,
            total: 2,
            totalPages: 2,
          ),
          (rows) async => rows,
        ),
        keyOf: (row) => row,
      );
      addTearDown(read.dispose);
      read.start();
      await expectLater(read.completion, throwsA(isA<ApiException>()));
      expect(read.snapshot.rows, [1]);
      expect(read.snapshot.complete, isFalse);
    },
  );
}
