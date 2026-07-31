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
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: content,
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
    );
  }
}
