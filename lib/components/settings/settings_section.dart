// SettingsSection - 设置页通用区块（标题 + 卡片 + 行 + 分隔线）
// 文档：docs/02-组件库/SettingsSection.md（待写）
//
// 设计：
// - 标题用小号灰字 + 字间距，模拟表单分组语义
// - 卡片用 UtenCard（与项目其他卡片统一视觉）
// - 多个 item 之间用 Divider 分隔
// - 员工侧（SettingsPage）和访客侧（VisitorSettingsPage）共用，
//   避免在两处重复写"标题 + 卡片 + items + dividers"布局

import 'package:flutter/material.dart';

import '../cards/uten_card.dart';
import '../inputs/uten_field_hint_icon.dart';
import '../layout/uten_section_header.dart';

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.info,
  });

  final String title;
  final List<Widget> children;
  final String? info;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenSectionHeader(title: title, info: info, subdued: true),
        const SizedBox(height: 8),
        UtenCard(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class SettingsItem extends StatelessWidget {
  const SettingsItem({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      title: Row(
        children: [
          Flexible(child: Text(title, style: theme.textTheme.bodyLarge)),
          if (subtitle?.trim().isNotEmpty == true)
            UtenFieldHintIcon(info: subtitle, dense: true),
        ],
      ),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [child],
    );
  }
}
