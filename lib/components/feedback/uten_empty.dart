// UtenEmpty - 空状态/错误状态
// 文档：docs/02-组件库/UtenEmpty.md（待写）

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';

/// Uten 空状态组件
class UtenEmpty extends StatelessWidget {
  const UtenEmpty({
    super.key,
    this.icon = Icons.inbox_outlined,
    this.message = '暂无数据',
    this.description,
    this.actionLabel,
    this.onAction,
    this.isError = false,
  });

  /// 生成一个错误状态
  factory UtenEmpty.error({
    Key? key,
    String? message,
    String? description,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return UtenEmpty(
      key: key,
      icon: Icons.error_outline_rounded,
      message: message ?? '出错了，请稍后重试',
      description: description,
      actionLabel: actionLabel,
      onAction: onAction,
      isError: true,
    );
  }

  final IconData icon;
  final String message;
  final String? description;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? UtenColors.error : theme.colorScheme.onSurfaceVariant;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 32),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(
                description!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: UtenColors.primary,
                  side: const BorderSide(color: UtenColors.primary),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
