import '../../../core/network/api_exception.dart';
import '../../../core/performance/ui_work_budget.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
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
  bool requireStableTotal = false,
}) async {
  try {
    await loadCompletePagedSnapshot<EmployeeSummary>(
      isCurrent: isCurrent,
      idOf: (row) => row.id,
      onBatch: onBatch,
      requireStableTotal: requireStableTotal,
      loadPage: (page, size) => repository.list(
        page: page,
        size: size,
        search: search,
        statuses: statuses,
        departmentId: departmentId,
        includeSubtree: includeSubtree,
        sort: sort,
        order: order,
      ),
    );
  } on UiWorkCancelled {
    return;
  } on ApiException catch (error) {
    if (error.code == 'SNAPSHOT_CHANGED') {
      throw ApiException('ROSTER_CHANGED', '员工资料在加载期间已变化，请重新加载完整名册');
    }
    rethrow;
  }
}
