import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

PagedResult<int> _page(int page) => PagedResult(
  items: [page * 10, page * 10 + 1],
  page: page,
  size: 2,
  total: 40,
  totalPages: 20,
);

void main() {
  for (final controller in [false, true]) {
    test(
      '${controller ? 'controller' : 'scoped reader'} prepares from projected reading position and retires late cache data',
      () async {
        final reader = ScopedPagedRead<int>();
        final list = PagedListController<int>();
        addTearDown(reader.dispose);
        addTearDown(list.dispose);
        final reads = <int>[];
        var scope = 'A';
        Completer<PagedResult<int>>? gate;
        final reverseStarted = Completer<void>();
        Future<PagedResult<int>> fetch(int page) async {
          reads.add(page);
          if (page == 9 && !reverseStarted.isCompleted) {
            reverseStarted.complete();
          }
          return gate?.future ?? _page(page);
        }

        Future<PagedResult<int>> read(int page) async {
          final owner = scope;
          if (controller) {
            await list.load(
              page,
              queryScope: scope,
              fetch: () => fetch(page),
              fetchPage: fetch,
              isCurrent: () => owner == scope,
              useCachedPage: true,
              canPrefetch: () => false,
            );
            return list.page!;
          }
          return reader.read(
            page,
            scope: scope,
            fetchPage: fetch,
            isCurrent: () => owner == scope,
            useCache: true,
            canPrefetch: () => false,
          );
        }

        final result = await read(1);
        await PagedReadIntent.bufferSeed(() => read(2));
        final projected = result.items.map((row) => 'row-$row').toList();
        projectReadWindowBinding<int, String>(
          result.items,
          projected,
          project: (rows) => rows.map((row) => 'row-$row').toList(),
          projectionKey: 'labels',
        );
        final binding = readWindowBindingOf<String>(projected)!;
        await binding.prepareAround(5, canPrepare: () => true);
        expect(reads, [1, 2, 6, 7, 4, 3]);
        expect(result.page, 1, reason: 'Preparation never publishes a UI page');
        await read(3);
        expect(reads, [
          1,
          2,
          6,
          7,
          4,
          3,
        ], reason: 'Return adopts the cached page');

        gate = Completer<PagedResult<int>>();
        final pending = binding.prepareAround(
          10,
          prepend: true,
          canPrepare: () => true,
        );
        await reverseStarted.future;
        expect(reads.last, 9, reason: 'Reverse scroll prepares behind first');
        scope = 'B';
        gate.complete(_page(9));
        await pending;
        gate = null;
        expect(reads, isNot(contains(8)));
        await read(9);
        expect(reads.where((page) => page == 9), hasLength(2));
        expect(binding.isCurrent, isFalse);
      },
    );
  }
}
