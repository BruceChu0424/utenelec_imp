// 个人信息修改 Provider。
// 文档：docs/03-页面/我的页.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/profile_change_request.dart';
import '../repositories/profile_change_repository.dart';

/// 本人完整员工档案（我的页联系方式/地址等字段用；编辑页 profile_edit_page.dart
/// 已有同款 employeeRepositoryProvider.getById(employeeId) 调用，这里补个共享
/// provider 给只读展示页复用，避免我的页把邮箱/电话/地址一直显示占位符"—"——
/// AppUser（session）本身不带这些字段，只带 employeeId 指路）。
final myEmployeeProfileProvider = FutureProvider.autoDispose<EmployeeProfile?>((
  ref,
) async {
  final employeeId = ref.watch(sessionProvider).user?.employeeId;
  if (employeeId == null || employeeId.isEmpty) return null;
  return ref.read(employeeRepositoryProvider).getById(employeeId);
});

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
final hrProfileChangesProvider = FutureProvider.autoDispose
    .family<
      ProfileChangePage<HrProfileChangeListItem>,
      ({String? status, int page})
    >((ref, key) {
      return ref
          .watch(profileChangeRepositoryProvider)
          .hrList(page: key.page, status: key.status);
    });

/// HR 单批详情。
final hrProfileChangeDetailProvider = FutureProvider.autoDispose
    .family<ProfileChangeBatch, String>((ref, batchId) {
      return ref.watch(profileChangeRepositoryProvider).hrBatchDetail(batchId);
    });
