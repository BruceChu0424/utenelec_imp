// 员工端访客审批 Provider（HR 列表/详情、被访人我的访客）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../visitor/models/visitor_application.dart';
import '../../visitor/repositories/visitor_repository.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../../shared/models/paged_result.dart';

typedef VisitorApprovalQuery = ({String? status, int page});
final visitorApprovalListProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorApplication>, VisitorApprovalQuery>((ref, q) {
      return ref
          .watch(visitorStaffRepositoryProvider)
          .approvalList(status: q.status, page: q.page);
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
