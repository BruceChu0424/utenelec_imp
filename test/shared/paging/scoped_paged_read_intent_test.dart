import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
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
  for (final controller in [false, true]) {
    test(
      '${controller ? 'controller' : 'scoped read'} reading-page intent keeps true cross-page cache hits and acknowledges unchanged DTOs',
      () async {
        final reader = ScopedPagedRead<String>();
        final pages = PagedListController<String>();
        addTearDown(reader.dispose);
        addTearDown(pages.dispose);
        final reads = <int>[], accepted = <int>[];
        Future<PagedResult<String>> fetch(int page) async {
          reads.add(page);
          return _page(page);
        }

        Future<void> read(int page) async {
          if (controller) {
            await pages.load(
              page,
              queryScope: 'query',
              useCachedPage: true,
              fetch: () => fetch(page),
              fetchPage: fetch,
              isCurrent: () => true,
              canPrefetch: () => false,
            );
          } else {
            await reader.read(
              page,
              scope: 'query',
              useCache: true,
              fetchPage: fetch,
              isCurrent: () => true,
              canPrefetch: () => false,
            );
          }
        }

        await read(1);
        await read(3);
        await PagedReadIntent.navigation(
          1,
          () => read(3),
          onAccepted: accepted.add,
        );
        expect(reads, [
          1,
          3,
        ], reason: 'Fetched 3 is a different visible reading page from 1');
        expect(accepted, [3]);
        await PagedReadIntent.navigation(
          3,
          () => read(3),
          onAccepted: accepted.add,
        );
        expect(reads, [
          1,
          3,
          3,
        ], reason: 'An actual same reading-page read remains fresh');
        await PagedReadIntent.navigation(
          3,
          () => PagedReadIntent.bufferSeed(() => read(2)),
          onAccepted: accepted.add,
        );
        expect(accepted, [
          3,
          3,
        ], reason: 'A seed cannot acknowledge a foreground destination');
        await PagedReadIntent.navigation(
          3,
          () async {},
          onAccepted: accepted.add,
        );
        expect(
          accepted,
          [3, 3],
          reason:
              'Cancelled navigation without a read has no acceptance receipt',
        );
      },
    );
  }

  test(
    'late older foreground result cannot replace the accepted refresh page',
    () async {
      final reader = ScopedPagedRead<String>();
      addTearDown(reader.dispose);
      final second = Completer<PagedResult<String>>();
      final reads = <int>[];
      Future<PagedResult<String>> fetch(int page) {
        reads.add(page);
        return page == 2 ? second.future : Future.value(_page(page));
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
      final older = read(2);
      await read(3);
      second.complete(_page(2));
      await older;
      await read(3);
      expect(
        reads.where((page) => page == 3),
        hasLength(2),
        reason:
            'The accepted foreground page remains 3, so explicitly rereading it is fresh',
      );
    },
  );

  for (final controller in [false, true]) {
    test(
      '${controller ? 'controller' : 'scoped read'} same accepted page refreshes while cross-page return stays cached',
      () async {
        final reader = ScopedPagedRead<String>();
        final pages = PagedListController<String>();
        addTearDown(reader.dispose);
        addTearDown(pages.dispose);
        final reads = <int>[];
        var revision = 1;
        Future<PagedResult<String>> fetch(int page) async {
          reads.add(page);
          return PagedResult(
            items: ['page-$page-v$revision'],
            page: page,
            size: 2,
            total: 200,
            totalPages: 100,
          );
        }

        Future<PagedResult<String>> read(int page, {bool cached = true}) async {
          if (controller) {
            await pages.load(
              page,
              queryScope: 'query',
              useCachedPage: cached,
              fetch: () => fetch(page),
              fetchPage: fetch,
              isCurrent: () => true,
              canPrefetch: () => false,
            );
            return pages.page!;
          }
          return reader.read(
            page,
            scope: 'query',
            useCache: cached,
            fetchPage: fetch,
            isCurrent: () => true,
            canPrefetch: () => false,
          );
        }

        await read(1, cached: false);
        revision = 2;
        expect((await read(1)).items, ['page-1-v2']);
        expect(reads, [1, 1]);
        await PagedReadIntent.bufferSeed(() => read(1));
        expect(reads, [
          1,
          1,
        ], reason: 'Buffer preparation is never a same-page refresh');
        await read(2);
        revision = 3;
        expect((await read(1)).items, ['page-1-v2']);
        expect(reads, [1, 1, 2]);
        expect((await read(1)).items, ['page-1-v3']);
        expect(reads, [1, 1, 2, 1]);
      },
    );
  }

  for (final controller in [false, true]) {
    test(
      '${controller ? 'controller' : 'scoped read'} seed 79 to 78 never predicts 77 or replaces the original center',
      () async {
        final reads = <int>[];
        Future<PagedResult<String>> fetch(int page) async {
          reads.add(page);
          return _page(page);
        }

        final reader = ScopedPagedRead<String>();
        final pages = PagedListController<String>();
        addTearDown(reader.dispose);
        addTearDown(pages.dispose);
        Future<void> read(int page, {bool cached = true}) async {
          if (controller) {
            await pages.load(
              page,
              queryScope: 'query',
              useCachedPage: cached,
              fetch: () => fetch(page),
              fetchPage: fetch,
              isCurrent: () => true,
            );
          } else {
            await reader.read(
              page,
              scope: 'query',
              useCache: cached,
              fetchPage: fetch,
              isCurrent: () => true,
            );
          }
        }

        await read(79, cached: false);
        await PagedReadIntent.bufferSeed(() => read(78));
        await Future<void>.delayed(Duration.zero);
        expect(reads.toSet(), {79, 78, 80});
        expect(reads, isNot(contains(77)));
        expect(reads.where((page) => page == 78), hasLength(1));
        expect(PagedReadIntent.isBufferSeed, isFalse);
        await read(78);
        await Future<void>.delayed(Duration.zero);
        expect(
          reads,
          contains(77),
          reason: 'Ordinary navigation still prepares its own adjacent page',
        );
      },
    );
  }
}
