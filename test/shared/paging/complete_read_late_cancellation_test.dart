import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

PagedResult<int> _page(int page, int size, int total) {
  final start = (page - 1) * size;
  return PagedResult<int>(
    items: [for (var i = start; i < (start + size).clamp(0, total); i++) i],
    page: page,
    size: size,
    total: total,
    totalPages: (total + size - 1) ~/ size,
    readScopeVersion: 'synthetic-current-scope',
  );
}

void main() {
  test(
    '100k read cancelled at 99k rejects a deliberately late final reply',
    () async {
      const total = 100000;
      final reader = ScopedPagedRead<int>(idOf: (row) => row);
      addTearDown(reader.dispose);
      final reached = Completer<void>();
      final release = Completer<void>();
      final snapshots = <PagedResult<int>>[];
      var batchCalls = 0;
      var lateReplies = 0;
      final loading = reader.read(
        1,
        scope: 'query-A',
        isCurrent: () => true,
        fetchPage: (_) => throw StateError('sized loader required'),
        fetchPageSized: (page, size) async {
          batchCalls++;
          if ((page - 1) * size == 99000) {
            reached.complete();
            await release.future;
            lateReplies++;
          }
          // This producer deliberately ignores retirement. The shared reader
          // must reject the reply without help from a compliant transport.
          return _page(page, size, total);
        },
        progressiveInterval: Duration.zero,
        onProgressiveBatch: snapshots.add,
      );
      final rejected = expectLater(loading, throwsA(isA<UiWorkCancelled>()));
      await reached.future.timeout(const Duration(seconds: 20));
      expect(snapshots.last.items, hasLength(99000));
      expect(snapshots.last.items.last, 98999);
      final published = snapshots.length;
      final callsAtRetirement = batchCalls;
      final oldRows = snapshots.last.items;
      final owner = readWindowBindingOf(oldRows)!;
      expect(owner.isCurrent, isTrue);
      reader.invalidate();
      expect(owner.isCurrent, isFalse);
      release.complete();
      await rejected;
      expect(lateReplies, 1);
      expect(batchCalls, callsAtRetirement);
      expect(snapshots, hasLength(published));
      expect(oldRows, hasLength(99000));
      expect(snapshots.first.items, hasLength(50));

      final recovered = await reader.read(
        1,
        scope: 'query-B',
        isCurrent: () => true,
        fetchPage: (_) => throw StateError('sized loader required'),
        fetchPageSized: (page, size) async => _page(page, size, total),
      );
      expect(recovered.items, hasLength(total));
      expect(recovered.items.first, 0);
      expect(recovered.items.last, total - 1);
      expect(readWindowBindingOf(recovered.items)!.isCurrent, isTrue);
      expect(owner.isCurrent, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 50)),
  );

  test(
    '24 rapidly superseded reads publish only the final 100k owner',
    () async {
      const total = 100000;
      final reader = ScopedPagedRead<int>(idOf: (row) => row);
      addTearDown(reader.dispose);
      final lateGates = List.generate(23, (_) => Completer<void>());
      final outcomes = <Future<PagedResult<int>?>>[];
      var current = 0;
      var lateReplies = 0;
      var rejected = 0;
      final failures = <Object>[];
      final publishedOwners = <int>[];
      for (var generation = 0; generation < 24; generation++) {
        final own = generation;
        current = own;
        final result = reader.read(
          1,
          scope: ('rapid-query', own),
          isCurrent: () => own == current,
          fetchPage: (_) => throw StateError('sized loader required'),
          fetchPageSized: (page, size) async {
            if (own < 23) {
              await lateGates[own].future;
              lateReplies++;
            }
            return _page(page, size, total);
          },
          onProgressiveBatch: (partial) {
            publishedOwners.add(own);
          },
        );
        outcomes.add(
          result.then<PagedResult<int>?>(
            (value) => value,
            onError: (Object error, StackTrace stack) {
              rejected++;
              failures.add(error);
              return null;
            },
          ),
        );
      }
      for (final gate in lateGates) {
        gate.complete();
      }
      final completed = await Future.wait(outcomes);
      expect(rejected, 23);
      expect(failures, everyElement(isA<UiWorkCancelled>()));
      expect(publishedOwners, everyElement(23));
      expect(lateReplies, 23);
      expect(completed.take(23), everyElement(isNull));
      final finalRows = completed.last!.items;
      expect(finalRows, hasLength(total));
      for (var i = 0; i < total; i++) {
        expect(finalRows[i], i);
      }
    },
    timeout: const Timeout(Duration(seconds: 50)),
  );
}
