import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

PagedResult<String> _page(int page) => PagedResult(
  items: ['row-$page'],
  page: page,
  size: 2,
  total: 200,
  totalPages: 100,
);

void main() {
  test(
    'explicit preparation starts next transport before any edge scroll and foreground adopts it',
    () async {
      final reader = ScopedPagedRead<String>();
      addTearDown(reader.dispose);
      final reads = <int>[];
      Future<PagedResult<String>> fetch(int page) async {
        reads.add(page);
        return _page(page);
      }

      Future<PagedResult<String>> read(int page) => reader.read(
        page,
        scope: 'query',
        fetchPage: fetch,
        isCurrent: () => true,
        useCache: true,
        canPrefetch: () => false,
      );
      await read(1);
      await Future<void>.delayed(Duration.zero);
      expect(reads, [1]);
      await reader.prepareNext(1, canPrepare: () => true);
      expect(reads, [1, 2]);
      expect((await read(2)).items, ['row-2']);
      expect(reads, [1, 2]);
      await reader.prepareNext(2, canPrepare: () => true);
      expect(reads, [1, 2, 3]);
    },
  );

  test(
    'seed preparation cannot replace 79 with 78 or recursively request 77',
    () async {
      final reader = ScopedPagedRead<String>();
      addTearDown(reader.dispose);
      final reads = <int>[];
      Future<PagedResult<String>> fetch(int page) async {
        reads.add(page);
        return _page(page);
      }

      Future<PagedResult<String>> read(int page) => reader.read(
        page,
        scope: 'query',
        fetchPage: fetch,
        isCurrent: () => true,
        useCache: true,
        canPrefetch: () => false,
      );
      await read(79);
      await PagedReadIntent.bufferSeed(() async {
        await read(78);
        await reader.prepareNext(78, canPrepare: () => true);
      });
      await reader.prepareNext(79, canPrepare: () => true);
      expect(reads, [79, 78, 80]);
      await read(79);
      expect(reads, [
        79,
        78,
        80,
        79,
      ], reason: 'Preparation does not change the accepted foreground page');
    },
  );

  test(
    'explicit next-page preparation shares one speculative worker and stops a retired chain',
    () async {
      final reader = ScopedPagedRead<String>();
      addTearDown(reader.dispose);
      final gates = <int, Completer<PagedResult<String>>>{};
      final started = {2: Completer<void>(), 21: Completer<void>()};
      final reads = <int>[];
      var current = true, active = 0, maximum = 0;
      Future<PagedResult<String>> fetch(int page) {
        reads.add(page);
        if (page == 1) return Future.value(_page(page));
        active++;
        if (active > maximum) maximum = active;
        final gate = gates[page] = Completer<PagedResult<String>>();
        started[page]?.complete();
        return gate.future.whenComplete(() => active--);
      }

      await reader.read(
        1,
        scope: 'query',
        fetchPage: fetch,
        isCurrent: () => current,
        canPrefetch: () => false,
      );
      final first = reader.prepareNext(1, canPrepare: () => true);
      await started[2]!.future;
      final skipped = reader.prepareNext(50, canPrepare: () => true);
      final latest = reader.prepareNext(20, canPrepare: () => true);
      expect(reads, [1, 2]);
      gates[2]!.complete(_page(2));
      await started[21]!.future;
      expect(reads, [1, 2, 21]);
      current = false;
      gates[21]!.complete(_page(21));
      await Future.wait([first, skipped, latest]);
      expect(maximum, 1);
      expect(reads, [1, 2, 21]);
    },
  );
}
