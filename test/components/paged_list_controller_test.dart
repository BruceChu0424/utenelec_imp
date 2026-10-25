// PagedListController（单据列表页共享分页状态机）行为回归：
//  - 最新请求胜出：慢的旧请求响应不回写页面数据；
//  - silent 后台刷新：保留原页，独立进度/错误；无原页时按首屏处理；
//  - ApiException 优先展示 message，其它异常落兜底文案；
//  - 关键字/排序归一：trim 空 → null，未选排序列 → order null。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

PagedResult<String> _page(List<String> items, {int total = 0}) => PagedResult(
  items: items,
  page: 1,
  size: items.length,
  total: total,
  totalPages: 1,
);

void main() {
  test('最新请求胜出：旧慢请求的响应不回写', () async {
    final c = PagedListController<String>();
    var notifyCount = 0;
    c.addListener(() => notifyCount++);

    final slow = c.load(
      1,
      fetch: () async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return _page(const ['old']);
      },
    );
    await c.load(2, fetch: () async => _page(const ['new']));
    await slow;

    expect(c.page?.items, const ['new']);
    expect(c.pageNum, 2);
    expect(c.loading, isFalse);
    expect(notifyCount, greaterThan(0));
    c.dispose();
  });

  test(
    'silent retains the accepted page and exposes background progress',
    () async {
      final c = PagedListController<String>();
      final accepted = _page(const ['stale']);
      c.page = accepted;
      final gate = Completer<PagedResult<String>>();
      final observed = <bool>[];
      c.addListener(() => observed.add(c.refreshing));
      final pending = c.load(1, silent: true, fetch: () => gate.future);
      expect(c.page, same(accepted));
      expect(c.refreshing, isTrue);
      expect(c.loading, isFalse);
      expect(c.isLoadingFirst, isFalse);
      expect(
        c.isLoadingMore,
        isFalse,
        reason: 'Do not reset the table page window',
      );

      gate.complete(_page(const ['fresh']));
      await pending;
      expect(c.page?.items, const ['fresh']);
      expect(c.loading, isFalse);
      expect(c.refreshing, isFalse);
      expect(c.error, isNull);
      expect(c.refreshError, isNull);
      expect(observed, [true, false]);
      c.dispose();
    },
  );

  for (final apiError in [false, true]) {
    test(
      'silent retains rows and reports a ${apiError ? 'server' : 'parse'} failure',
      () async {
        final c = PagedListController<String>();
        final accepted = _page(const ['stale']);
        c.page = accepted;
        await c.load(
          1,
          silent: true,
          fetch: () async => throw apiError
              ? ApiException('CONFLICT', '网络抖动')
              : const FormatException('bad response'),
        );
        expect(c.page, same(accepted));
        expect(
          c.error,
          isNull,
          reason: 'Background failure must not replace the table',
        );
        expect(c.refreshError, apiError ? '网络抖动' : '加载列表失败');
        expect(c.refreshing, isFalse);
        expect(c.loading, isFalse);

        final gate = Completer<PagedResult<String>>();
        final retry = c.load(1, silent: true, fetch: () => gate.future);
        expect(
          c.refreshError,
          isNull,
          reason: 'A retry retires the previous failure',
        );
        expect(c.refreshing, isTrue);
        gate.complete(_page(const ['fresh']));
        await retry;
        expect(c.page?.items, ['fresh']);
        expect(c.refreshError, isNull);
        expect(c.refreshing, isFalse);
        c.dispose();
      },
    );
  }

  test(
    'silent without an accepted page uses first-load progress and errors',
    () async {
      final c = PagedListController<String>();
      final gate = Completer<PagedResult<String>>();
      final pending = c.load(1, silent: true, fetch: () => gate.future);
      expect(c.loading, isTrue);
      expect(c.isLoadingFirst, isTrue);
      expect(c.refreshing, isFalse);
      gate.completeError(ApiException('NETWORK', '网络抖动'));
      await pending;
      expect(c.page, isNull);
      expect(c.error, '网络抖动');
      expect(c.refreshError, isNull);
      expect(c.loading, isFalse);
      c.dispose();
    },
  );

  test('new background request supersedes an earlier normal load', () async {
    final c = PagedListController<String>();
    c.page = _page(const ['accepted']);
    final oldGate = Completer<PagedResult<String>>();
    final newGate = Completer<PagedResult<String>>();
    final oldLoad = c.load(1, fetch: () => oldGate.future);
    expect(c.isLoadingMore, isTrue);
    final newLoad = c.load(1, silent: true, fetch: () => newGate.future);
    expect(
      c.loading,
      isFalse,
      reason: 'The superseded foreground load is retired',
    );
    expect(c.refreshing, isTrue);
    newGate.complete(_page(const ['new']));
    await newLoad;
    oldGate.completeError(ApiException('NETWORK', 'old failure'));
    await oldLoad;
    expect(c.page?.items, ['new']);
    expect(c.refreshError, isNull);
    expect(c.error, isNull);
    expect(c.refreshing, isFalse);
    expect(c.loading, isFalse);
    c.dispose();
  });

  for (final failure in [
    ApiException('UNAUTHORIZED', '请重新登录'),
    ApiException('FORBIDDEN', '无查看权限'),
    ApiException('CUSTOM_ACCESS_RULE', '无查看权限', httpStatus: 403),
    ApiException('CUSTOM_SESSION_RULE', '请重新登录', httpStatus: 401),
  ]) {
    test(
      'access denial ${failure.code}/${failure.httpStatus} removes accepted rows',
      () async {
        final c = PagedListController<String>();
        c.page = _page(const ['private accepted document']);
        await c.load(1, silent: true, fetch: () async => throw failure);
        expect(c.page, isNull);
        expect(c.error, failure.message);
        expect(c.refreshError, isNull);
        expect(c.refreshing, isFalse);
        expect(c.loading, isFalse);
        c.dispose();
      },
    );
  }

  test('错误映射：ApiException 展示 message，其它异常落兜底文案', () async {
    final c = PagedListController<String>();
    await c.load(1, fetch: () async => throw ApiException('CONFLICT', '后端说不行'));
    expect(c.error, '后端说不行');
    expect(c.loading, isFalse, reason: '失败后停止加载，由 error 接管展示');

    await c.load(1, fetch: () async => throw const FormatException('boom'));
    expect(c.error, '加载列表失败');
    c.dispose();
  });

  test('关键字与排序归一', () {
    final c = PagedListController<String>();
    expect(c.normalizedKeyword, isNull);
    c.keyword = '   ';
    expect(c.normalizedKeyword, isNull);
    c.keyword = ' CG-01 ';
    expect(c.normalizedKeyword, 'CG-01');

    expect(c.sortOrder, isNull);
    c.onSortChange('billDate', false);
    expect(c.sortKey, 'billDate');
    expect(c.sortAsc, isFalse);
    expect(c.sortOrder, 'desc');
    c.dispose();
  });

  test(
    'background results retain the table window until a foreground query',
    () async {
      final c = PagedListController<String>();
      addTearDown(c.dispose);
      await c.load(1, fetch: () async => _page(const ['accepted']));
      final revision = c.paginationRevision;
      await c.load(
        1,
        silent: true,
        fetch: () async => _page(const ['updated']),
      );
      expect(c.paginationRevision, revision);
      await c.load(
        1,
        silent: true,
        fetch: () async => throw ApiException('NETWORK', 'offline'),
      );
      expect(c.paginationRevision, revision);
      await c.load(1, fetch: () async => _page(const ['new query']));
      expect(c.paginationRevision, greaterThan(revision));
      final foregroundRevision = c.paginationRevision;
      c.invalidateReadOwner();
      expect(c.paginationRevision, greaterThan(foregroundRevision));
    },
  );

  test('confirmed access denial retires every cached table page', () async {
    final c = PagedListController<String>();
    addTearDown(c.dispose);
    c.page = _page(const ['private']);
    final revision = c.paginationRevision;
    await c.load(
      1,
      silent: true,
      fetch: () async => throw ApiException('FORBIDDEN', 'denied'),
    );
    expect(c.page, isNull);
    expect(c.paginationRevision, greaterThan(revision));
  });

  for (final fails in [false, true]) {
    test(
      'reset discards a late ${fails ? 'error' : 'page'} without another load',
      () async {
        final c = PagedListController<String>();
        final gate = Completer<PagedResult<String>>();
        final pending = c.load(4, fetch: () => gate.future);
        c.keyword = 'old reader';
        c.onSortChange('billNo', false);
        c.reset();
        if (fails) {
          gate.completeError(ApiException('FORBIDDEN', 'old reader error'));
        } else {
          gate.complete(_page(const ['private old document']));
        }
        await pending;
        expect(c.page, isNull);
        expect(c.error, isNull);
        expect(c.refreshError, isNull);
        expect(c.refreshing, isFalse);
        expect(c.loading, isFalse);
        expect(c.pageNum, 1);
        expect(c.keyword, isEmpty);
        expect(c.sortKey, isNull);
        c.dispose();
      },
    );
  }

  for (final fails in [false, true]) {
    test(
      'reader invalidation retires a background ${fails ? 'error' : 'page'}',
      () async {
        final c = PagedListController<String>();
        c.page = _page(const ['private accepted document']);
        final gate = Completer<PagedResult<String>>();
        final pending = c.load(1, silent: true, fetch: () => gate.future);
        expect(c.refreshing, isTrue);
        c.invalidateReadOwner();
        if (fails) {
          gate.completeError(ApiException('NETWORK', 'old reader failure'));
        } else {
          gate.complete(_page(const ['private late document']));
        }
        await pending;
        expect(c.page, isNull);
        expect(c.error, isNull);
        expect(c.refreshError, isNull);
        expect(c.loading, isFalse);
        expect(c.refreshing, isFalse);
        c.dispose();
      },
    );
  }

  test(
    'dispose invalidates pending reads and prevents new transport calls',
    () async {
      final c = PagedListController<String>();
      final gate = Completer<PagedResult<String>>();
      final pending = c.load(1, fetch: () => gate.future);
      c.dispose();
      gate.complete(_page(const ['private old document']));
      await pending;
      var called = false;
      await c.load(
        1,
        fetch: () async {
          called = true;
          return _page(const ['x']);
        },
      );
      expect(c.page, isNull);
      expect(called, isFalse);
    },
  );
}
