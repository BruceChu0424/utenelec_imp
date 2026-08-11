// 通知到达调度器
// 文档：docs/02-组件库/UtenNotify.md §七
//
// 职责：一条新通知（Notice）到达时，按其重要度分派到统一通知门面的对应通道：
// - urgent    → UtenNotify.alert(urgent)    屏幕正中红色弹窗，必须显式确认
// - important → UtenNotify.alert(important) 屏幕正中橙色弹窗
// - normal    → UtenNotify.banner(...)      顶部弹条（微信式），点击跳对应页面
//
// 点击/确认行为：标注已读（同步刷新通知页与角标）+ 跳转到 notice.actionRoute
// （"待办对应的站内办理入口"）；无 actionRoute 时回退通知详情弹层。
//
// 接真后端后，推送 / WebSocket 的落点就在这里：后端推一条 Notice →
// 仓储入库 → 列表/角标失效刷新 → dispatchNoticeArrival 弹提醒。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_center_alert.dart';
import '../../../core/ui/uten_notify.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';
import '../widgets/notice_detail_dialog.dart';

/// 分派一条到达的通知到对应弹出通道。
///
/// [onOpenDetail] 可选，完全自定义「打开」行为；默认：
/// - 标注已读（[markNoticeReadContainer]，同步刷新通知页与角标）；
/// - normal 横幅点击 → 跳 `actionRoute`，无则开详情弹层；
/// - urgent/important 确认 → 开详情弹层（弹层内「前往办理页面」按钮负责跳转）。
void dispatchNoticeArrival(
  BuildContext context,
  Notice notice, {
  VoidCallback? onOpenDetail,
}) {
  // 横幅/弹窗的点击可能在数分钟后、来源页已 dispose 时才触发：用 app 级
  // ProviderContainer（随 app 生命周期稳定）与在弹窗外捕获的 router，避免
  // WidgetRef 失效抛 StateError，以及弹窗内 GoRouter.of 取不到的竞态。
  final container = ProviderScope.containerOf(context, listen: false);
  final router = GoRouter.of(context);

  void markRead() {
    // fire-and-forget：标注已读失败可容忍，角标/列表在下次轮询（60s）自愈。
    markNoticeReadContainer(container, notice.id).ignore();
  }

  // urgent/important：标注已读 + 打开详情弹层。
  final openDetail =
      onOpenDetail ??
      () {
        markRead();
        showNoticeDetailDialog(context, noticeId: notice.id);
      };

  // normal 横幅：标注已读 + 直接跳对应页面（无 actionRoute 回退详情弹层）。
  final openBanner =
      onOpenDetail ??
      () {
        markRead();
        if (noticeActionTarget(notice) case final target?) {
          router.go(target);
        } else {
          showNoticeDetailDialog(context, noticeId: notice.id);
        }
      };

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
      if (notice.type.isCelebratory) {
        // 庆典通知：节庆图标 + 对象名标题，停留略久。
        UtenNotify.banner(
          context,
          title: notice.subjectName != null
              ? '${notice.type.label}祝福 · ${notice.subjectName}'
              : '${notice.type.label}祝福',
          message: notice.title,
          icon: notice.type.icon,
          duration: const Duration(seconds: 5),
          onTap: openBanner,
        );
      } else {
        UtenNotify.banner(
          context,
          title: notice.type.isWork
              ? '${notice.type.label} · ${notice.publisher}'
              : notice.publisher,
          message: notice.title,
          icon: notice.type.icon,
          duration: const Duration(seconds: 4),
          onTap: openBanner,
        );
      }
  }
}

/// 弹窗正文截断（详情进详情页看全文）
String _truncate(String s, [int max = 120]) =>
    s.length <= max ? s : '${s.substring(0, max)}……';
