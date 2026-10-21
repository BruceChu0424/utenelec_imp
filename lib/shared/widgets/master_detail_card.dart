// MasterDetailCard - 分类、部门和账户的共享详情摘要。
// 管理动作集中在标题右侧菜单；分类宿主可用 UtenHierarchyDetailMenu 提供
// 与左树右键相同的即时动作，其他宿主继续传领域回调，由卡片统一生成菜单。
import 'package:flutter/material.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/cards/uten_card.dart';
import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';
import '../../components/feedback/uten_context_menu.dart';
import 'uten_hierarchy_detail_menu.dart';

/// 详情卡的一个统计项；[value] 为 null/空时该统计自动隐藏（省去调用方逐个判空）。
class MasterDetailStat {
  const MasterDetailStat(this.label, this.value);

  final String label;
  final String? value;
}

/// 详情卡菜单中的领域扩展动作，如部门「岗位管理」。
class MasterDetailCardAction {
  const MasterDetailCardAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.type = UtenButtonType.tonal,
  });

  final IconData icon;
  final String label;
  final UtenButtonType type;
  final VoidCallback onPressed;
}

class MasterDetailCard extends StatelessWidget {
  const MasterDetailCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.stats,
    required this.canEdit,
    this.canAddChild,
    this.canDelete,
    this.onAddChild,
    this.onEdit,
    this.onDelete,
    this.addChildLabel = '新增子分类', // TODO(l10n): 补 arb
    this.deleteLabel = '删除', // TODO(l10n): 补 arb
    this.path,
    this.icon = Icons.category_outlined,
    this.extraActions = const [],
    this.secondaryActions = const [],
  });

  final String title;
  final String subtitle;

  /// 统计项；空值项自动隐藏。
  final List<MasterDetailStat> stats;

  /// 路径文案（如「公司 › 一级部门 › 财务部」）；为空不渲染。
  final String? path;

  /// 头部前置图标（着色方框徽标，有/无权限都显示，保证卡片视觉一致、不显空）。
  final IconData icon;

  /// 是否有编辑权限（控制操作按钮显隐）。
  final bool canEdit;

  /// null 时沿用 canEdit，保持部门页等既有调用兼容。
  final bool? canAddChild;
  final bool? canDelete;

  bool get _canAddChild => canAddChild ?? canEdit;
  bool get _canDelete => canDelete ?? canEdit;

  /// 新增子项回调；null时不生成对应菜单项。分类宿主也可统一传入菜单scope。
  final VoidCallback? onAddChild;

  /// 「新增子项」按钮文案。
  final String addChildLabel;

  /// 「删除」按钮文案（分类详情 = 删除分类；部门 = 删除等，由调用方按领域给出）。
  final String deleteLabel;

  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// 额外菜单操作。
  final List<MasterDetailCardAction> extraActions;

  /// 次级操作（渲染在主操作行下方单独一行，如「导入/导出/预览打印」）；空则不渲染。
  final List<Widget> secondaryActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibleStats = stats
        .where((s) => s.value != null && s.value!.isNotEmpty)
        .toList();
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(theme, context),
          // 状态或数据操作仍可使用独立可换行区域，不挤占标题和菜单。
          if (secondaryActions.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            _actionBar(theme, context),
          ],
          if (visibleStats.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final s in visibleStats) _stat(theme, s.label, s.value!),
              ],
            ),
          ],
          if (path != null && path!.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '路径：$path', // TODO(l10n): 补 arb
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 标题自然换行，操作菜单保持明确的点击区域。
  Widget _titleRow(ThemeData theme, BuildContext context) {
    final inheritedMenu = UtenHierarchyDetailMenu.maybeOf(context);
    final ownEntries = _managementMenu(context);
    final entriesBuilder =
        inheritedMenu?.entriesBuilder ??
        (ownEntries.isEmpty ? null : () => _managementMenu(context));
    final titleColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    // 前置着色方框徽标（与基础资料 hub 卡片同一视觉语言）。
    final leading = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Icon(icon, size: 22, color: theme.colorScheme.primary),
    );
    return Row(
      children: [
        leading,
        const SizedBox(width: UtenSpacing.s12),
        Expanded(child: titleColumn),
        if (entriesBuilder != null) ...[
          const SizedBox(width: UtenSpacing.s12),
          UtenHierarchyMenuButton(entriesBuilder: entriesBuilder),
        ],
      ],
    );
  }

  List<UtenContextMenuEntry> _managementMenu(BuildContext context) {
    final l10n =
        Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppLocalizationsZh();
    return [
      if (_canAddChild && onAddChild != null)
        UtenMenuItem(
          icon: Icons.add_rounded,
          label: addChildLabel,
          onTap: onAddChild!,
        ),
      if (canEdit && onEdit != null)
        UtenMenuItem(
          icon: Icons.edit_outlined,
          label: l10n.hierarchyEdit,
          onTap: onEdit!,
        ),
      for (final e in extraActions)
        UtenMenuItem(
          icon: e.icon,
          label: e.label,
          destructive: e.type == UtenButtonType.danger,
          onTap: e.onPressed,
        ),
      if (_canDelete && onDelete != null) ...[
        if ((_canAddChild && onAddChild != null) ||
            (canEdit && onEdit != null) ||
            extraActions.isNotEmpty)
          const UtenMenuDivider(),
        UtenMenuItem(
          icon: Icons.delete_outline,
          label: deleteLabel,
          destructive: true,
          onTap: onDelete!,
        ),
      ],
    ];
  }

  /// 数据操作及状态标记按可用宽度换行。
  Widget _actionBar(ThemeData theme, BuildContext context) {
    final data = secondaryActions;
    final children = <Widget>[];
    children.addAll(data);

    final alignEnd = context.breakpoint.atLeastMedium;
    return Wrap(
      alignment: alignEnd ? WrapAlignment.end : WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: children,
    );
  }

  Widget _stat(ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Text('$label：$value', style: theme.textTheme.bodySmall),
    );
  }
}
