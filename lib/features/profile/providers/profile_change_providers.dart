// 个人信息修改 Provider。
// 文档：docs/03-页面/我的页.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/profile_change_request.dart';
import '../repositories/profile_change_repository.dart';

/// 员工自查列表（按状态过滤；null = 全部）。
final myProfileChangesProvider = FutureProvider.autoDispose
    .family<ProfileChangePage<MyProfileChangeListItem>, String?>((ref, status) {
      return ref.watch(profileChangeRepositoryProvider).myList(status: status);
    });

/// 员工自查单批详情。
final myProfileChangeDetailProvider = FutureProvider.autoDispose
    .family<ProfileChangeBatch, String>((ref, batchId) {
      return ref.watch(profileChangeRepositoryProvider).myBatchDetail(batchId);
    });

/// HR 队列（按状态过滤；null = pending）。
final hrProfileChangesProvider = FutureProvider.autoDispose
    .family<ProfileChangePage<HrProfileChangeListItem>, String?>((ref, status) {
      return ref.watch(profileChangeRepositoryProvider).hrList(status: status);
    });

/// HR 单批详情。
final hrProfileChangeDetailProvider = FutureProvider.autoDispose
    .family<ProfileChangeBatch, String>((ref, batchId) {
      return ref.watch(profileChangeRepositoryProvider).hrBatchDetail(batchId);
    });

/// 某员工的 HR 待审数（员工详情 Hero 后区块）。
final pendingCountForEmployeeProvider = FutureProvider.autoDispose
    .family<int, String>((ref, employeeId) {
      return ref
          .watch(profileChangeRepositoryProvider)
          .hrPendingCountFor(employeeId);
    });
