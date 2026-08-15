import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// 单据详情页「来源单据」行：显示关联单据编号，可点击时带下划线与跳转图标，
/// 不可点击（无权威 id 或纯文本谱系）时退化为只读文本。
///
/// 全站溯源跳转统一走本组件，样式与反馈口径一致：
/// - 有 [onTap]：主题色 + 下划线 + 跳转图标，点击触发（页面自行做权限预检/异常提示）；
/// - 无 [onTap]：普通文本（谱系仍可见，不可下钻）；
/// - [billNo] 为空：显示「—」（无来源，如手工单）。
class SourceDocLink extends StatelessWidget {
  const SourceDocLink({
    super.key,
    required this.label,
    required this.billNo,
    this.subtitle,
    this.onTap,
  });

  final String label;

  /// 关联单据编号（显示用）；为空渲染「—」。
  final String? billNo;

  /// 可选副标题（如来源销售订单的客户/业务员），紧跟编号后弱化显示。
  final String? subtitle;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final no = (billNo == null || billNo!.isEmpty) ? null : billNo;
    final body = no == null
        ? Text('—', style: theme.textTheme.bodyMedium)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  no,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: onTap == null
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.primary,
                    decoration: onTap == null ? null : TextDecoration.underline,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (subtitle?.isNotEmpty == true) ...[
                const SizedBox(width: UtenSpacing.s4),
                Flexible(
                  child: Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (onTap != null) ...[
                const SizedBox(width: UtenSpacing.s4),
                Icon(
                  Icons.open_in_new,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              ],
            ],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: onTap == null
                ? body
                : InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(4),
                    child: body,
                  ),
          ),
        ],
      ),
    );
  }
}
