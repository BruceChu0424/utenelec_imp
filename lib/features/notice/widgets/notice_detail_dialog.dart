import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/responsive/breakpoint.dart';
import '../../../core/responsive/dialog_size.dart';
import '../pages/notice_detail_page.dart';

/// 从通知列表或到达提醒打开详情：
/// 手机使用高位底部弹层，平板/桌面使用居中对话框；深链仍保留独立详情路由。
Future<void> showNoticeDetailDialog(
  BuildContext context, {
  required String noticeId,
}) {
  // 弹窗外捕获 router：调用方（通知列表）context 在 go_router 栈内，GoRouter.of
  // 可达；弹窗内 context 取不到 GoRouterState，故「查看详情」跳转所需的 router 在
  // 此捕获，交 onActionNavigate 闭包携带——先关弹窗再用本 router 跳转。
  final router = GoRouter.of(context);
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.92,
        child: NoticeDetailPage(
          noticeId: noticeId,
          onBack: () => Navigator.of(sheetContext).pop(),
          onActionNavigate: (target) {
            Navigator.of(sheetContext).pop();
            router.go(target);
          },
        ),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final height = MediaQuery.sizeOf(dialogContext).height - 96;
      return Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: utenDialogInsetPadding(dialogContext),
        child: SizedBox(
          width: utenDialogWidth(dialogContext, 760),
          height: height.clamp(480.0, 760.0).toDouble(),
          child: NoticeDetailPage(
            noticeId: noticeId,
            onBack: () => Navigator.of(dialogContext).pop(),
            onActionNavigate: (target) {
              Navigator.of(dialogContext).pop();
              router.go(target);
            },
          ),
        ),
      );
    },
  );
}
