// UtenPersonCard - 通用人物/实体卡片（业务无关）
// 文档：docs/02-组件库/UtenPersonCard.md
//
// 用途：员工、审批人、发布人、联系人等"头像+标题+副标题+尾部"形态的卡片展示。
// 卡片化、响应式友好，改一处全站生效。复合 UtenCard（性能档/主题自适应）。
import 'package:flutter/material.dart';

import 'uten_card.dart';

class UtenPersonCard extends StatelessWidget {
  const UtenPersonCard({
    super.key,
    required this.title,
    this.subtitle,
    this.avatarText,
    this.avatarColor,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.margin = const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    this.elevation = UtenCardElevation.low,
  });

  final String title;
  final String? subtitle;
  final String? avatarText;
  final Color? avatarColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry? margin;
  final UtenCardElevation elevation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = (avatarText == null || avatarText!.isEmpty)
        ? (title.isEmpty ? '?' : title.characters.first)
        : avatarText!.characters.first;
    return UtenCard(
      onTap: onTap,
      onLongPress: onLongPress,
      margin: margin,
      elevation: elevation,
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: CircleAvatar(
            backgroundColor: avatarColor ?? theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
            child: Text(initial),
          ),
          title: Text(title, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          subtitle: subtitle == null || subtitle!.isEmpty
              ? null
              : Text(subtitle!, overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.bodySmall),
          trailing: trailing,
        ),
      ),
    );
  }
}
