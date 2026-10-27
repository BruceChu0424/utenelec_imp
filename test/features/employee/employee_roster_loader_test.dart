import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/repositories/employee_roster_loader.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _Repository extends Fake implements EmployeeRepository {
  final calls =
      <
        ({
          int page,
          int size,
          String? search,
          String? departmentId,
          bool includeSubtree,
          Set<String>? statuses,
          String? sort,
          String? order,
        })
      >[];
  final pending = <Completer<PagedResult<EmployeeSummary>>>[];
  var _requestCreated = Completer<void>();

  Future<void> whenRequested(int count) async {
    while (calls.length < count) {
      await _requestCreated.future;
    }
  }

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) {
    calls.add((
      page: page,
      size: size,
      search: search,
      departmentId: departmentId,
      includeSubtree: includeSubtree,
      statuses: statuses,
      sort: sort,
      order: order,
    ));
    final response = Completer<PagedResult<EmployeeSummary>>();
    pending.add(response);
    final created = _requestCreated;
    _requestCreated = Completer<void>();
    created.complete();
    return response.future;
  }
}

EmployeeSummary _row(String id) =>
    EmployeeSummary(id: id, code: id, fullName: '员工$id');
PagedResult<EmployeeSummary> _page(
  int page,
  List<String> ids, {
  int pages = 2,
}) => PagedResult(
  items: ids.map(_row).toList(),
  page: page,
  size: 100,
  total: 3,
  totalPages: pages,
);

void main() {
  test('一次加载所有批次，保留查询授权范围，按稳定ID去重', () async {
    final repo = _Repository();
    final batches = <List<EmployeeSummary>>[];
    final more = <bool>[];
    final loading = loadEmployeeRoster(
      repository: repo,
      isCurrent: () => true,
      onBatch: (rows, total, hasMore) {
        batches.add(rows);
        more.add(hasMore);
      },
      search: '张',
      departmentId: 'dept',
      includeSubtree: true,
      statuses: {'active'},
      sort: 'code',
      order: 'desc',
    );
    repo.pending[0].complete(_page(1, ['a', 'b']));
    await repo.whenRequested(2);
    expect(repo.calls.length, 2);
    expect(repo.calls[1].page, 2);
    expect(repo.calls[1].size, 100);
    expect(repo.calls[1].search, '张');
    expect(repo.calls[1].departmentId, 'dept');
    expect(repo.calls[1].includeSubtree, isTrue);
    expect(repo.calls[1].statuses, {'active'});
    expect(repo.calls[1].sort, 'code');
    expect(repo.calls[1].order, 'desc');
    repo.pending[1].complete(_page(2, ['b', 'c']));
    await loading;
    expect(batches.last.map((row) => row.id), ['a', 'b', 'c']);
    expect(more, [true, false]);
  });
  test('搜索或部门变化后丢弃旧批次并停止续页', () async {
    final repo = _Repository();
    var current = true;
    final batches = <List<EmployeeSummary>>[];
    final loading = loadEmployeeRoster(
      repository: repo,
      isCurrent: () => current,
      onBatch: (rows, _, more) => batches.add(rows),
    );
    repo.pending[0].complete(_page(1, ['a']));
    await repo.whenRequested(2);
    current = false;
    repo.pending[1].complete(_page(2, ['stale']));
    await loading;
    expect(batches.single.single.id, 'a');
    expect(repo.calls.length, 2);
  });
  test('剩余页失败保留已交付名册，错误交给宿主提示重试', () async {
    final repo = _Repository();
    final batches = <List<EmployeeSummary>>[];
    final loading = loadEmployeeRoster(
      repository: repo,
      isCurrent: () => true,
      onBatch: (rows, _, more) => batches.add(rows),
    );
    final fails = expectLater(loading, throwsA(isA<ApiException>()));
    repo.pending[0].complete(_page(1, ['a']));
    await repo.whenRequested(2);
    repo.pending[1].completeError(ApiException('NETWORK', '断线'));
    await fails;
    expect(batches.single.single.id, 'a');
  });
  test('异常空续页不会无限发请求或假装全量已加载', () async {
    final repo = _Repository();
    final loading = loadEmployeeRoster(
      repository: repo,
      isCurrent: () => true,
      onBatch: (_, _, _) {},
    );
    final fails = expectLater(loading, throwsA(isA<ApiException>()));
    repo.pending[0].complete(_page(1, []));
    await fails;
    expect(repo.calls.length, 1);
  });

  test('跨页重复导致总数不符时保留行并提示重试，不宣称全量完成', () async {
    final repo = _Repository();
    final more = <bool>[];
    final loading = loadEmployeeRoster(
      repository: repo,
      isCurrent: () => true,
      onBatch: (_, _, hasMore) => more.add(hasMore),
    );
    final fails = expectLater(loading, throwsA(isA<ApiException>()));
    repo.pending[0].complete(_page(1, ['a', 'b']));
    await repo.whenRequested(2);
    repo.pending[1].complete(_page(2, ['b']));
    await fails;
    expect(more, [true, true]);
  });
}
