import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

PagedResult<int> _page(int page, {int revision = 0}) => PagedResult(
  items: [revision * 10 + page],
  page: page,
  size: 1,
  total: 3,
  totalPages: 3,
  readScopeVersion: 'same-authority',
);

void main() {
  test(
    'refreshing an accepted empty result carries pending proof until revalidated',
    () async {
      final reader = ScopedPagedRead<int>();
      addTearDown(reader.dispose);
      final accepted = await reader.read(
        1,
        scope: 'A',
        fetchPage: (_) async => const PagedResult<int>(
          items: [],
          page: 1,
          size: 100,
          total: 0,
          totalPages: 0,
        ),
        isCurrent: () => true,
      );
      final proof = readWindowBindingOf(accepted.items)!;
      expect(proof.empty, isTrue);
      reader.refresh();
      expect(proof.isCurrent, isTrue);
      expect(proof.pending, isTrue);
      expect(proof.empty, isFalse);
      final next = await reader.read(
        1,
        scope: 'A',
        fetchPage: (page) async => _page(page),
        isCurrent: () => true,
        useCache: true,
      );
      expect(next.items, [1, 2, 3]);
      expect(proof.pending, isFalse);
      expect(proof.empty, isFalse);
    },
  );

  test(
    'same-query refresh preserves complete rendering proof through failure and explicit retry',
    () async {
      final reader = ScopedPagedRead<int>(idOf: (row) => row);
      addTearDown(reader.dispose);
      final accepted = await reader.read(
        1,
        scope: 'A',
        fetchPage: (page) async => _page(page),
        isCurrent: () => true,
      );
      final proof = readWindowBindingOf(accepted.items)!;
      reader.refresh();
      expect(proof.isCurrent, isTrue);
      expect(proof.pending, isTrue);
      final failure = NetworkException();
      await expectLater(
        reader.read(
          1,
          scope: 'A',
          fetchPage: (_) async => throw failure,
          isCurrent: () => true,
          useCache: true,
        ),
        throwsA(same(failure)),
      );
      expect(accepted.items, [1, 2, 3]);
      expect(proof.isCurrent, isTrue);
      expect(proof.pending, isFalse);
      expect(proof.failed, isTrue);
      reader.refresh();
      final retriedPages = <int>[];
      final next = await reader.read(
        1,
        scope: 'A',
        fetchPage: (page) async {
          retriedPages.add(page);
          return _page(page, revision: 2);
        },
        isCurrent: () => true,
        useCache: true,
      );
      expect(retriedPages, [1, 2, 3]);
      expect(next.items, [21, 22, 23]);
      expect(proof.failed, isFalse);
      expect(proof.pending, isFalse);
      reader.invalidate();
      expect(
        proof.isCurrent,
        isFalse,
        reason: 'Write invalidation stays hard.',
      );
    },
  );

  test(
    'rapid refresh cancels a held old batch and never fetches its later batch',
    () async {
      final reader = ScopedPagedRead<int>(idOf: (row) => row);
      addTearDown(reader.dispose);
      await reader.read(
        1,
        scope: 'A',
        fetchPage: (page) async => _page(page),
        isCurrent: () => true,
      );
      final held = Completer<PagedResult<int>>();
      final oldPages = <int>[];
      reader.refresh();
      final old = reader.read(
        1,
        scope: 'A',
        fetchPage: (page) async {
          oldPages.add(page);
          return page == 2 ? held.future : _page(page, revision: 1);
        },
        isCurrent: () => true,
      );
      final rejected = expectLater(old, throwsA(isA<UiWorkCancelled>()));
      // The continuation batch is scheduled after a yield once the first
      // batch publishes, so page 2 arrives one event-loop hop later.
      var waitTurns = 0;
      while (oldPages.length < 2 && waitTurns < 200) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        waitTurns++;
      }
      expect(oldPages, [1, 2]);
      reader.refresh();
      reader.refresh();
      final newPages = <int>[];
      final fresh = await reader.read(
        1,
        scope: 'A',
        fetchPage: (page) async {
          newPages.add(page);
          return _page(page, revision: 3);
        },
        isCurrent: () => true,
        useCache: true,
      );
      held.complete(_page(2, revision: 1));
      await rejected;
      expect(oldPages, [1, 2]);
      expect(newPages, [1, 2, 3]);
      expect(fresh.items, [31, 32, 33]);
    },
  );

  test(
    'query, owner ABA and access denial never reuse the old proof',
    () async {
      final reader = ScopedPagedRead<int>(idOf: (row) => row);
      addTearDown(reader.dispose);
      var epoch = 1;
      Future<PagedResult<int>> read(String query, int owner) => reader.read(
        1,
        scope: query,
        fetchPage: (page) async => _page(page),
        isCurrent: () => epoch == owner,
      );
      final original = await read('A', 1);
      final proof = readWindowBindingOf(original.items)!;
      final replacement = await read('B', 1);
      expect(proof.isCurrent, isFalse);
      final replacementProof = readWindowBindingOf(replacement.items)!;
      epoch = 2;
      reader.refresh();
      expect(replacementProof.isCurrent, isFalse);
      epoch = 3;
      final returned = await read('A', 3);
      expect(proof.isCurrent, isFalse);
      expect(replacementProof.isCurrent, isFalse);
      final returnedProof = readWindowBindingOf(returned.items)!;
      reader.refresh();
      final denied = ApiException('FORBIDDEN', 'revoked', httpStatus: 403);
      await expectLater(
        reader.read(
          1,
          scope: 'A',
          fetchPage: (_) async => throw denied,
          isCurrent: () => epoch == 3,
        ),
        // 真失败带匿名关联号后缀（read_failure_diagnostics）：原始 code 与消息
        // 前缀原样到达，实例不再是同一个。
        throwsA(
          isA<ApiException>()
              .having((error) => error.code, 'code', 'FORBIDDEN')
              .having(
                (error) => error.message,
                'message',
                startsWith('revoked'),
              ),
        ),
      );
      expect(returnedProof.isCurrent, isFalse);
      reader.dispose();
      expect(returnedProof.isCurrent, isFalse);
    },
  );
}
