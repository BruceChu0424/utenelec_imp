import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

/// P4.1 provisional first batch (2026-11-07 user decision): the first validated
/// batch may render while the same read continues; the complete result replaces
/// it; failures and retired requests never leave a half list as the result.
void main() {
  const total = 250;
  PagedResult<String> pageOf(int page) {
    final start = (page - 1) * 100;
    final end = (start + 100).clamp(0, total);
    return PagedResult<String>(
      items: [for (var i = start; i < end; i++) 'row-$i'],
      page: page,
      size: 100,
      total: total,
      totalPages: 3,
      readScopeVersion: 'scope-a',
    );
  }

  test('only the first validated batch is published, with the exact total', () async {
    final provisional = <PagedResult<String>>[];
    final result = await loadCompletePagedResult<String>(
      loadPage: (page, size) async => pageOf(page),
      isCurrent: () => true,
      idOf: (row) => row,
      onProvisionalBatch: provisional.add,
    );
    expect(provisional, hasLength(1));
    expect(provisional.single.items, hasLength(100));
    expect(provisional.single.items.first, 'row-0');
    expect(provisional.single.total, total);
    expect(provisional.single.readScopeVersion, 'scope-a');
    expect(result.items, hasLength(total));
    expect(result.total, total);
  });

  test('a single-batch result is published only as the complete result', () async {
    final provisional = <PagedResult<String>>[];
    final result = await loadCompletePagedResult<String>(
      loadPage: (page, size) async => const PagedResult<String>(
        items: ['only'],
        page: 1,
        size: 100,
        total: 1,
        totalPages: 1,
      ),
      isCurrent: () => true,
      idOf: (row) => row,
      onProvisionalBatch: provisional.add,
    );
    expect(provisional, isEmpty);
    expect(result.items, ['only']);
  });

  test('the shared reader binds provisional rows to the same session, then replaces them', () async {
    final reader = ScopedPagedRead<String>(idOf: (row) => row);
    final provisional = <PagedResult<String>>[];
    final result = await reader.read(
      1,
      scope: 'goods',
      fetchPage: (page) async => pageOf(page),
      isCurrent: () => true,
      onProvisionalBatch: provisional.add,
    );
    expect(provisional, hasLength(1));
    // Provisional rows carry the reader's owner proof: the view may render them
    // while the read continues, and retirement retires them with the session.
    final binding = readWindowBindingOf(provisional.single.items)!;
    expect(binding.isCurrent, isTrue);
    expect(
      binding.sameSession(readWindowBindingOf(result.items)),
      isTrue,
      reason: 'provisional and complete rows share one reader session',
    );
    expect(readWindowBindingOf(result.items)?.pending, isFalse);
  });

  test('a failure after the provisional batch fails the whole read', () async {
    final reader = ScopedPagedRead<String>(idOf: (row) => row);
    final provisional = <PagedResult<String>>[];
    await expectLater(
      reader.read(
        1,
        scope: 'goods',
        fetchPage: (page) async =>
            page == 1 ? pageOf(1) : throw StateError('stream broke'),
        isCurrent: () => true,
        onProvisionalBatch: provisional.add,
      ),
      throwsStateError,
    );
    expect(provisional, hasLength(1));
    // The rows the view received are owned by a session that has failed.
    final binding = readWindowBindingOf(provisional.single.items)!;
    expect(binding.pending, isFalse);
    expect(binding.failed, isTrue);
  });

  test('a superseded request never publishes provisional rows', () async {
    final reader = ScopedPagedRead<String>(idOf: (row) => row);
    final provisional = <PagedResult<String>>[];
    var current = true;
    final gate = Completer<void>();
    final read = reader.read(
      1,
      scope: 'goods',
      fetchPage: (page) async {
        await gate.future;
        return pageOf(page);
      },
      isCurrent: () => current,
      onProvisionalBatch: provisional.add,
    );
    current = false;
    gate.complete();
    await expectLater(read, throwsA(anything));
    expect(provisional, isEmpty);
  });

  test('a refresh with an accepted result keeps it pending instead of a half list', () async {
    final reader = ScopedPagedRead<String>(idOf: (row) => row);
    await reader.read(1, scope: 'goods', fetchPage: (page) async => pageOf(page), isCurrent: () => true);
    reader.refresh();
    final provisional = <PagedResult<String>>[];
    final result = await reader.read(
      1,
      scope: 'goods',
      fetchPage: (page) async => pageOf(page),
      isCurrent: () => true,
      onProvisionalBatch: provisional.add,
    );
    // refresh() drops the accepted result, so this is a fresh read again.
    expect(provisional, hasLength(1));
    expect(result.items, hasLength(total));
  });

  test('complete readers in the view zone claim the slot once', () async {
    final published = <PagedResult<Object?>>[];
    final sink = PagedReadProvisionalSink(published.add);
    await PagedReadIntent.provisionalRead(sink, () async {
      expect(PagedReadIntent.currentProvisional, same(sink));
      await Future<void>.delayed(Duration.zero);
      expect(PagedReadIntent.currentProvisional, same(sink));
      expect(sink.claim(), isTrue);
      // An auxiliary complete read in the same zone cannot publish.
      expect(sink.claim(), isFalse);
    });
    expect(PagedReadIntent.currentProvisional, isNull);
  });

  test('a fetchComplete read sees the view slot in its zone', () async {
    final reader = ScopedPagedRead<String>(idOf: (row) => row);
    final provisional = <PagedResult<String>>[];
    final result = await reader.read(
      1,
      scope: 'goods',
      fetchPage: (page) async => pageOf(page),
      fetchComplete: () async {
        final sink = PagedReadIntent.currentProvisional;
        expect(sink, isNotNull);
        final claimed = sink!.claim();
        return loadCompletePagedResult<String>(
          loadPage: (page, size) async => pageOf(page),
          isCurrent: () => true,
          idOf: (row) => row,
          onProvisionalBatch: claimed
              ? (partial) => sink.publish(partial as PagedResult<Object?>)
              : null,
        );
      },
      isCurrent: () => true,
      onProvisionalBatch: provisional.add,
    );
    expect(provisional, hasLength(1));
    expect(provisional.single.items, hasLength(100));
    expect(result.items, hasLength(total));
  });
}
