// 通知到达调度器
// 文档：docs/02-组件库/UtenNotify.md
//
// 职责：一条新通知（Notice）到达时，按其重要度分派到统一通知门面的对应通道：
// - urgent    → UtenNotify.alert(urgent)    屏幕正中红色弹窗，必须显式确认
// - important → UtenNotify.alert(important) 屏幕正中橙色弹窗
// - normal    → UtenNotify.banner(...)      顶部弹条（微信式），点击跳详情
//
// 接真后端后，推送 / WebSocket 的落点就在这里：后端推一条 Notice →
// 仓储入库 → 列表/角标失效刷新 → dispatchNoticeArrival 弹提醒。

import 'package:flutter/material.dart';
import '../../../components/feedback/uten_center_alert.dart';
import '../../../core/ui/uten_notify.dart';
import '../models/notice.dart';
import '../widgets/notice_detail_dialog.dart';

/// 分派一条到达的通知到对应弹出通道。
///
/// [onOpenDetail] 可选，自定义「查看详情」行为；默认打开自适应详情弹层，
/// 与通知列表的点击体验保持一致。
void dispatchNoticeArrival(
  BuildContext context,
  Notice notice, {
  VoidCallback? onOpenDetail,
}) {
  final openDetail =
      onOpenDetail ??
      () => showNoticeDetailDialog(context, noticeId: notice.id);

  switch (notice.priority) {
    case NoticePriority.urgent:
      UtenNotify.alert(
        context,
        title: notice.title,
        message: _truncate(notice.content),
        level: UtenAlertLevel.urgent,
        icon: notice.type.icon,
        confirmLabel: '查看详情',
        onConfirm: openDetail,
      );
    case NoticePriority.important:
      UtenNotify.alert(
        context,
        title: notice.title,
        message: _truncate(notice.content),
        level: UtenAlertLevel.important,
        icon: notice.type.icon,
        confirmLabel: '查看详情',
        cancelLabel: '稍后',
        onConfirm: openDetail,
      );
    case NoticePriority.normal:
      UtenNotify.banner(
        context,
        title: notice.type.isWork
            ? '${notice.type.label} · ${notice.publisher}'
            : notice.publisher,
        message: notice.title,
        icon: notice.type.icon,
        duration: const Duration(seconds: 4),
        onTap: openDetail,
      );
  }
}

/// 弹窗正文截断（详情进详情页看全文）
String _truncate(String s, [int max = 120]) =>
    s.length <= max ? s : '${s.substring(0, max)}……';
