// 员工端访客审批 Provider（HR 列表/详情、被访人我的访客）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../basic_data/models/master_facet.dart';
import '../../visitor/models/visitor_application.dart';
import '../../visitor/repositories/visitor_repository.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../../shared/models/paged_result.dart';

/// 2026-09-10 key 增 hostDepartmentId：表头「接待人部门」筛选下推后端，
/// 换筛选即换 key（回第 1 页由页面负责）。
typedef VisitorApprovalQuery = ({
  String? status,
  String? hostDepartmentId,
  int page,
});
final visitorApprovalListProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorApplication>, VisitorApprovalQuery>((ref, q) {
      return ref
          .watch(visitorStaffRepositoryProvider)
          .approvalList(
            status: q.status,
            hostDepartmentId: q.hostDepartmentId,
            page: q.page,
          );
    });

/// HR 审批列表表头筛选桶（状态/接待人部门），按当前分段状态取后端全量聚合。
final visitorApprovalFacetsProvider = FutureProvider.autoDispose
    .family<Map<String, List<MasterFacetBucket>>, String?>((ref, status) {
      return ref
          .watch(visitorStaffRepositoryProvider)
          .approvalFacets(status: status);
    });

final visitorApprovalDetailProvider = FutureProvider.autoDispose
    .family<VisitorApplicationDetail, String>((ref, id) {
      return ref.watch(visitorStaffRepositoryProvider).approvalDetail(id);
    });

typedef VisitorHostQuery = ({String? status, int page});
final myAsHostProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorApplication>, VisitorHostQuery>((ref, q) {
      return ref
          .watch(visitorStaffRepositoryProvider)
          .myAsHost(status: q.status, page: q.page);
    });
