import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

PagedResult<String> _page(int page, List<String> rows, {int total = 5}) =>
    PagedResult(
      items: rows,
      page: page,
      size: 2,
      total: total,
      totalPages: (total / 2).ceil(),
    );

void main() {
  test(
    'a shifted multi-page window is published once after every page succeeds',
    () async {
      final list = PagedListController<String>();
      addTearDown(list.dispose);
      final accepted = _page(2, ['C', 'D']);
      list.page = accepted;
      list.retainPages([1, 2]);
      final lastPage = Completer<PagedResult<String>>();
      final reads = <int>[];
      final request = list.load(
        2,
        silent: true,
        fetch: () async => throw StateError('must use fetchPage'),
        fetchPage: (page) {
          reads.add(page);
          return page == 1
              ? Future.value(_page(1, ['B', 'C']))
              : lastPage.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(reads, [1, 2]);
      expect(list.page, same(accepted));
      expect(list.refreshedPages, isEmpty);
      lastPage.complete(_page(2, ['D', 'E']));
      await request;
      expect(list.refreshedPages, {
        1: ['B', 'C'],
        2: ['D', 'E'],
      });
      expect(list.page!.items, ['D', 'E']);
      expect(list.refreshing, isFalse);
    },
  );

  for (final denied in [false, true]) {
    test(
      'a failed second page ${denied ? 'clears private rows' : 'keeps the entire old snapshot'}',
      () async {
        final list = PagedListController<String>();
        addTearDown(list.dispose);
        final accepted = _page(2, ['C', 'D']);
        list.page = accepted;
        list.retainPages([1, 2]);
        await list.load(
          2,
          silent: true,
          fetch: () async => accepted,
          fetchPage: (page) async {
            if (page == 1) return _page(1, ['B', 'C']);
            throw ApiException(denied ? 'FORBIDDEN' : 'NETWORK', 'failed');
          },
        );
        expect(list.refreshedPages, isEmpty);
        expect(list.page, denied ? isNull : same(accepted));
        expect(list.refreshError, denied ? isNull : 'failed');
        expect(list.error, denied ? 'failed' : isNull);
      },
    );
  }

  test(
    'a superseding query stops later window reads and rejects partial results',
    () async {
      final list = PagedListController<String>();
      addTearDown(list.dispose);
      list.page = _page(2, ['C', 'D']);
      list.retainPages([1, 2]);
      final first = Completer<PagedResult<String>>();
      final reads = <int>[];
      final pending = list.load(
        2,
        silent: true,
        fetch: () => first.future,
        fetchPage: (page) {
          reads.add(page);
          return first.future;
        },
      );
      await list.load(1, fetch: () async => _page(1, ['new query']));
      first.complete(_page(1, ['obsolete']));
      await pending;
      expect(reads, [1]);
      expect(list.page!.items, ['new query']);
      expect(list.refreshedPages, isEmpty);
    },
  );

  test(
    'retained revalidation is bounded to five positive distinct pages',
    () async {
      final list = PagedListController<String>();
      addTearDown(list.dispose);
      list.page = _page(2, ['old'], total: 100);
      list.retainPages([0, -1, 1, 1, 2, 3, 4, 5, 6, 7]);
      final reads = <int>[];
      await list.load(
        2,
        silent: true,
        fetch: () async => _page(2, ['fallback']),
        fetchPage: (page) async {
          reads.add(page);
          return _page(page, ['row $page'], total: 100);
        },
      );
      expect(reads, [1, 2, 3, 4, 5]);
      expect(list.refreshedPages.keys, [1, 2, 3, 4, 5]);
    },
  );

  test(
    'a deleted last window falls back to the remaining valid last page',
    () async {
      final list = PagedListController<String>();
      addTearDown(list.dispose);
      list.page = _page(5, ['old'], total: 10);
      list.retainPages([4, 5]);
      final reads = <int>[];
      await list.load(
        5,
        silent: true,
        fetch: () async => _page(5, []),
        fetchPage: (page) async {
          reads.add(page);
          return _page(page, page == 2 ? ['remaining'] : [], total: 4);
        },
      );
      expect(reads, [4, 2]);
      expect(list.page!.page, 2);
      expect(list.refreshedPages, {
        2: ['remaining'],
      });
    },
  );

  test(
    'scheduler revalidation observes failure without changing ordinary UI loads',
    () async {
      final list = PagedListController<String>();
      addTearDown(list.dispose);
      list.page = _page(1, ['old']);
      final pending = list.load(
        1,
        silent: true,
        fetch: () async => throw ApiException('NETWORK', 'offline'),
      );
      await expectLater(list.revalidate(pending), throwsStateError);
      expect(list.page!.items, ['old']);
      expect(list.refreshError, 'offline');
    },
  );
}
