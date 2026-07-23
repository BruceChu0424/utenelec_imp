// 员工端访客审批 Provider（HR 列表/详情、被访人我的访客）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../visitor/models/visitor_application.dart';
import '../../visitor/repositories/visitor_repository.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';

final visitorApprovalListProvider =
    FutureProvider.autoDispose.family<List<VisitorApplication>, String?>((ref, status) {
  return ref.watch(visitorStaffRepositoryProvider).approvalList(status: status);
});

final visitorApprovalDetailProvider =
    FutureProvider.autoDispose.family<VisitorApplicationDetail, String>((ref, id) {
  return ref.watch(visitorStaffRepositoryProvider).approvalDetail(id);
});

final myAsHostProvider = FutureProvider.autoDispose<List<VisitorApplication>>((ref) {
  return ref.watch(visitorStaffRepositoryProvider).myAsHost();
});
