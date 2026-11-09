import 'package:flutter/material.dart';

import '../../../components/feedback/uten_progress_dialog.dart';
import '../models/master_batch.dart';
import 'master_edit_owner.dart';

/// 主档批量启停/删除（unit/color 等独立页）的统一进度弹窗入口。
///
/// 整批一次请求提交，发出后无法撤回：不提供「取消」。弹窗路由登记给
/// [MasterEditOwner]（只有自己的弹窗在顶时才允许写入），owner 失效
/// （身份/权限/范围变化或被其他页面顶掉）时按取消收尾，旧结果不再呈现。
///
/// 返回 null 表示 owner 已失效或弹窗被外力关闭：调用方直接返回，不弹结果。
Future<MasterBatchResult?> runMasterBatchWithProgress(
  BuildContext context, {
  required MasterEditOwner owner,
  required String title,
  required String status,
  String? detail,
  required Future<MasterBatchResult> Function() command,
}) {
  return showUtenProgress<MasterBatchResult>(
    context,
    title: title,
    icon: Icons.task_alt_outlined,
    initialStatus: status,
    initialDetail: detail,
    cancellable: false,
    invalidation: owner,
    onRouteOpened: owner.trackRoute,
    action: (_) => owner.run(command),
  );
}
