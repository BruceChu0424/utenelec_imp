// PagedListController（单据列表页共享分页状态机）行为回归：
//  - 最新请求胜出：慢的旧请求响应不回写页面数据；
//  - silent 静默刷新：不翻 loading、失败不弹错误、成功静默换数据；
//  - ApiException 优先展示 message，其它异常落兜底文案；
//  - 关键字/排序归一：trim 空 → null，未选排序列 → order null。
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

  test('silent：不翻 loading、失败静默、成功静默换数据', () async {
    final c = PagedListController<String>();
    c.page = _page(const ['stale']);

    var bugged = false;
    c
        .load(
          1,
          silent: true,
          fetch: () async => throw ApiException('CONFLICT', '网络抖动'),
        )
        .then((_) => bugged = true);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(bugged, isTrue);
    expect(c.error, isNull, reason: '静默刷新失败不弹错误');
    expect(c.page?.items, const ['stale']);

    await c.load(1, silent: true, fetch: () async => _page(const ['fresh']));
    expect(c.page?.items, const ['fresh']);
    expect(c.loading, isFalse);
    c.dispose();
  });

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

  test('dispose 后 load 不再通知(不抛)', () async {
    final c = PagedListController<String>();
    c.dispose();
    await c.load(1, fetch: () async => _page(const ['x']));
    // 不抛 ChangeNotifier.useAfterDispose 即通过；dispose 后仅抑制通知，字段写入无害
    expect(c.page?.items, const ['x']);
  });
}
