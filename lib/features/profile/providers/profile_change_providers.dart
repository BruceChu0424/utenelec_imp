// 个人信息修改 Provider。
// 文档：docs/03-页面/我的页.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../basic_data/models/master_facet.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/profile_change_request.dart';
import '../repositories/profile_change_repository.dart';

/// 本人完整员工档案。
///
/// 只能通过后端从当前认证主体解析员工档案，不能相信 session/JWT 中可陈旧的
/// employeeId 再调用 HR 详情端点；`null` 专指当前账号未绑定可用员工档案。
final myEmployeeProfileProvider = FutureProvider.autoDispose<EmployeeProfile?>(
  (ref) => ref.watch(employeeRepositoryProvider).getMe(),
);

/// 员工自查列表（按状态过滤 + 分页；status null = 全部）。
/// family key 含 page：列表页翻页时换 key 触发后端按页拉取（修原先写死 page=1
/// 致 >20 条静默截断的 bug）。计数入口（profile_page）传 page=1、读 page.total 即真总数。
final myProfileChangesProvider = FutureProvider.autoDispose
    .family<
      ProfileChangePage<MyProfileChangeListItem>,
      ({String? status, int page})
    >((ref, key) {
      return ref
          .watch(profileChangeRepositoryProvider)
          .myList(page: key.page, status: key.status);
    });

/// 员工自查单批详情。
final myProfileChangeDetailProvider = FutureProvider.autoDispose
    .family<ProfileChangeBatch, String>((ref, batchId) {
      return ref.watch(profileChangeRepositoryProvider).myBatchDetail(batchId);
    });

/// HR 队列（按状态过滤 + 分页；status null = pending）。
/// family key 含 page：列表页翻页按页拉取（修原先写死 page=1 致 >20 条静默截断；
/// HR 全公司队列 >20 待审是常态，截断风险高于个人页）。
/// 员工详情页「待审修改」区块等只按状态取用；HR 队列页另有带部门筛选的
/// [hrProfileChangeQueueProvider]（两者同一后端端点，key 形状不同）。
final hrProfileChangesProvider = FutureProvider.autoDispose
    .family<
      ProfileChangePage<HrProfileChangeListItem>,
      ({String? status, int page})
    >((ref, key) {
      return ref
          .watch(profileChangeRepositoryProvider)
          .hrList(page: key.page, status: key.status);
    });

/// HR 队列页专用（2026-09-10）：key 增 departmentId——表头「部门」筛选下推后端
/// （原先只裁剪当前页，命中行可能落在其他页）；换筛选即换 key，回第 1 页由页面负责。
final hrProfileChangeQueueProvider = FutureProvider.autoDispose
    .family<
      ProfileChangePage<HrProfileChangeListItem>,
      ({String? status, String? departmentId, int page})
    >((ref, key) {
      return ref
          .watch(profileChangeRepositoryProvider)
          .hrList(
            page: key.page,
            status: key.status,
            departmentId: key.departmentId,
          );
    });

/// HR 队列表头筛选桶（部门），按当前分段状态取后端聚合（全量，非当前页）。
final hrProfileChangeFacetsProvider = FutureProvider.autoDispose
    .family<Map<String, List<MasterFacetBucket>>, String?>((ref, status) {
      return ref
          .watch(profileChangeRepositoryProvider)
          .hrFacets(status: status);
    });

/// HR 单批详情。
final hrProfileChangeDetailProvider = FutureProvider.autoDispose
    .family<ProfileChangeBatch, String>((ref, batchId) {
      return ref.watch(profileChangeRepositoryProvider).hrBatchDetail(batchId);
    });
