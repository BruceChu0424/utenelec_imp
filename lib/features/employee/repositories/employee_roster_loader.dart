import '../../../core/network/api_exception.dart';
import '../models/employee_api_models.dart';
import 'employee_repository.dart';

/// 名册在一个表内展示完整授权范围；网络仍遵循服务端分页上限。
/// 每批提交前检查查询身份，防止旧部门/搜索/排序的响应混入新名册。
Future<void> loadEmployeeRoster({
  required EmployeeRepository repository,
  required bool Function() isCurrent,
  required void Function(List<EmployeeSummary> items, int total, bool hasMore)
  onBatch,
  String? search,
  Set<String>? statuses,
  String? departmentId,
  bool includeSubtree = false,
  String? sort,
  String? order,
}) async {
  final rows = <String, EmployeeSummary>{};
  var page = 1;
  while (isCurrent()) {
    final result = await repository.list(
      page: page,
      size: 100,
      search: search,
      statuses: statuses,
      departmentId: departmentId,
      includeSubtree: includeSubtree,
      sort: sort,
      order: order,
    );
    if (!isCurrent()) return;
    final hasMore = result.page < result.totalPages;
    if (result.page != page || (hasMore && result.items.isEmpty)) {
      throw ApiException('INVALID_PAGINATION', '员工列表分页信息异常，请刷新后重试');
    }
    for (final row in result.items) {
      rows[row.id] = row;
    }
    final incomplete = !hasMore && rows.length != result.total;
    onBatch(
      List<EmployeeSummary>.unmodifiable(rows.values),
      result.total,
      hasMore || incomplete,
    );
    if (incomplete) {
      throw ApiException('ROSTER_CHANGED', '员工资料在加载期间已变化，请重新加载完整名册');
    }
    if (!hasMore) return;
    page++;
  }
}
