// UtenDialog - 确认对话框（UtenButton 动作 + 主题适配 + 按钮居中）
// 文档：docs/02-组件库/UtenDialog.md
import 'package:flutter/material.dart';

import '../buttons/uten_button.dart';

abstract final class UtenDialog {
  /// 显示确认对话框。返回 true=确认，false/null=取消。
  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required Widget content,
    String? confirmLabel,
    String? cancelLabel,
    VoidCallback? onConfirm,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => SelectionArea(
        // 弹窗文字可框选复制（准则 §3.4 局部包裹：弹窗是独立路由，自带 region，
        // 不与页面 region 嵌套；TextField 不受影响，自带原生选择）。
        child: AlertDialog(
          title: Text(title),
          // 比例护栏（2026-09-11）：AlertDialog 的 content 既不限宽也不滚动，
          // 一段长说明就能把弹窗顶到满屏高（用户反馈「登记并送检的弹窗巨长」）。
          // 这里统一限宽 460、限高 60% 屏高并让内容自己滚。
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 460,
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
            ),
            child: SingleChildScrollView(child: content),
          ),
          // 按钮整体居中（全仓弹窗统一规范）
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelLabel ?? '取消'),
            ),
            UtenButton(
              type: danger ? UtenButtonType.danger : UtenButtonType.primary,
              onPressed: () {
                Navigator.pop(ctx, true);
                onConfirm?.call();
              },
              child: Text(confirmLabel ?? '确认'),
            ),
          ],
        ),
      ),
    );
  }
}
