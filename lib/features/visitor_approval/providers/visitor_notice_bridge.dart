// 访客审批事件 → 工作通知桥
// 文档：docs/02-组件库/UtenNotify.md §七
//
// 职责：审批流转产生结果后，自动生成一条工作类 Notice 并入通知收件箱，
// 再走统一到达调度（dispatchNoticeArrival）弹提醒：
// - approve 通过        → approval / normal    → 顶部弹条
// - reject 驳回         → approval / important → 居中橙色弹窗（驳回必须被看见）
// - forward 转接待人    → workflow / normal    → 顶部弹条
// - hostConfirm 被访人确认/拒绝 → workflow/approval（同上规则）
//
// 接真后端后，这段逻辑由服务端推送触发（每个相关接收端各自收到），
// 本桥即为前端落点：入库 → 列表/角标刷新 → 按重要度弹通道。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notice/models/notice.dart';
import '../../notice/providers/notice_arrival.dart';
import '../../notice/providers/notice_providers.dart';
import '../../visitor/models/visitor_application.dart';
import '../../visitor/widgets/visitor_status_ui.dart';

/// HR 审批动作（approve / reject / forward）完成后调用。
Future<void> notifyVisitorApprovalOutcome(
  BuildContext context,
  WidgetRef ref, {
  required VisitorApplication app,
  required String action,
  String? rejectReason,
}) async {
  final when = fmtDateTime(app.plannedVisitAt);
  final host = app.hostName ?? app.hostDepartment ?? '被访人';

  final (title, content, type, priority) = switch (action) {
    'approve' => (
      '审批通过：访客 ${app.visitorName} 的来访申请已批准',
      '访客 ${app.visitorName} 的来访申请已由 HR 审批通过。\n\n'
          '来访事由：${app.visitPurpose}\n'
          '来访时间：$when\n'
          '接待人：$host\n\n'
          '通行凭证（二维码/通行码）已生效，门卫核验后即可入园。',
      NoticeType.approval,
      NoticePriority.normal,
    ),
    'reject' => (
      '审批驳回：访客 ${app.visitorName} 的来访申请被驳回',
      '访客 ${app.visitorName} 的来访申请已被 HR 驳回。\n\n'
          '来访事由：${app.visitPurpose}\n'
          '来访时间：$when\n'
          '${rejectReason != null && rejectReason.isNotEmpty ? '驳回原因：$rejectReason\n' : ''}'
          '\n如需重新来访，请修改信息后再次提交申请。',
      NoticeType.approval,
      NoticePriority.important,
    ),
    _ => (
      '流程流转：访客 ${app.visitorName} 的申请已转接待人确认',
      '访客 ${app.visitorName} 的来访申请已由 HR 转交接待人确认。\n\n'
          '来访事由：${app.visitPurpose}\n'
          '来访时间：$when\n'
          '接待人：$host\n\n'
          '接待人确认后申请将进入下一环节。',
      NoticeType.workflow,
      NoticePriority.normal,
    ),
  };

  await _publishAndDispatch(
    context,
    ref,
    title: title,
    content: content,
    type: type,
    priority: priority,
  );
}

/// 被访人确认 / 拒绝接待后调用。
Future<void> notifyVisitorHostConfirm(
  BuildContext context,
  WidgetRef ref, {
  required VisitorApplication app,
  required bool confirmed,
}) async {
  final when = fmtDateTime(app.plannedVisitAt);
  final host = app.hostName ?? '被访人';

  final (title, content, type, priority) = confirmed
      ? (
          '流程流转：$host 已确认接待访客 ${app.visitorName}',
          '接待人 $host 已确认接待访客 ${app.visitorName}。\n\n'
              '来访事由：${app.visitPurpose}\n'
              '来访时间：$when\n\n'
              '申请已回到 HR 待办队列，等待最终审批。',
          NoticeType.workflow,
          NoticePriority.normal,
        )
      : (
          '审批驳回：$host 拒绝接待访客 ${app.visitorName}',
          '接待人 $host 拒绝了访客 ${app.visitorName} 的来访申请。\n\n'
              '来访事由：${app.visitPurpose}\n'
              '来访时间：$when\n\n'
              '该申请已关闭，如需来访请重新提交。',
          NoticeType.approval,
          NoticePriority.important,
        );

  await _publishAndDispatch(
    context,
    ref,
    title: title,
    content: content,
    type: type,
    priority: priority,
  );
}

/// 入库 → 列表/角标失效刷新 → 按重要度弹到达提醒。
///
/// 已接真后端：发布人由后端取当前登录员工姓名快照（前端不再传 publisher）。
/// 审批动作人可能无 notice:publish 权限（如普通员工确认接待）——
/// 此时通知发布失败不应拖垮审批主流程，try/catch 静默降级为仅本地提醒。
Future<void> _publishAndDispatch(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String content,
  required NoticeType type,
  required NoticePriority priority,
}) async {
  Notice? notice;
  try {
    notice = await ref
        .read(noticeRepositoryProvider)
        .publish(
          title: title,
          content: content,
          type: type,
          priority: priority,
        );
    ref.invalidate(noticeListProvider);
    ref.invalidate(unreadNoticeCountProvider);
  } catch (_) {
    // 无发布权限或网络异常：审批主流程已成功，通知落库失败可容忍
  }
  if (notice != null && context.mounted) {
    dispatchNoticeArrival(context, notice);
  }
}
