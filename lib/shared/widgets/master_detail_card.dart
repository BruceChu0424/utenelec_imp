// MasterDetailCard - 通用「分组详情卡 + 操作按钮」（分类/部门 共用）。
//
// 泛化自原 basic_data 的 CategoryDetailCard：不再绑定具体领域模型（ProductCategoryDetail），
// 调用方传入标题/副标题/stats/path 与三按钮（新增子项/编辑/删除），外加可选的
// [extraActions]（领域扩展，如部门「岗位管理」）。
//
// 标题一行 + 统一操作条一行：管理类（新增/编辑/删除 + extraActions）与数据类
// （secondaryActions，如导入/导出/预览）合并到同一组，中间竖线分组；
// 大屏（medium+）操作条右对齐、窄屏（compact）居中，按钮多自动换行——三档断点一致。
// 改样式只改这里一处——分类页与部门页共用。
import 'package:flutter/material.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/cards/uten_card.dart';
import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_tokens.dart';

/// 详情卡的一个统计项；[value] 为 null/空时该统计自动隐藏（省去调用方逐个判空）。
class MasterDetailStat {
  const MasterDetailStat(this.label, this.value);

  final String label;
  final String? value;
}

/// 详情卡的额外操作按钮（三按钮之外的领域扩展，如部门「岗位管理」）。
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
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
    this.addChildLabel = '新增子分类', // TODO(l10n): 补 arb
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

  /// 「新增子项」回调（分类=新增子分类；部门=新增子部门）。
  final VoidCallback onAddChild;

  /// 「新增子项」按钮文案。
  final String addChildLabel;

  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// 额外操作（追加在三按钮之后）。
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
          // 统一操作条：管理类（新增/编辑/删除 + 扩展）与数据类（导入/导出/预览）按钮
          // 合并到同一组，取代原先「主操作挂标题右侧、secondaryActions 单独左对齐一行」
          // 的割裂布局；大屏右对齐、窄屏居中，自动换行适配。
          if (canEdit ||
              extraActions.isNotEmpty ||
              secondaryActions.isNotEmpty) ...[
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

  /// 标题行：前置图标徽标 + 标题/副标题。操作按钮统一移到 [_actionBar]，
  /// 不再挤在标题旁——大屏小屏都是「标题一行 + 操作条一行」，布局一致好适配。
  /// 无权限时也保留图标徽标 + 标题（stats/path 照常），仅少了操作条。
  Widget _titleRow(ThemeData theme, BuildContext context) {
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
      ],
    );
  }

  UtenButton _action({
    required IconData icon,
    required String label,
    required UtenButtonType type,
    required VoidCallback onPressed,
  }) {
    return UtenButton(
      type: type,
      icon: icon,
      onPressed: onPressed,
      child: Text(label),
    );
  }

  /// 三按钮 + 额外操作，按顺序排列。
  List<Widget> _buildButtons() {
    return [
      if (canEdit) ...[
        _action(
          icon: Icons.add_rounded,
          label: addChildLabel,
          type: UtenButtonType.tonal,
          onPressed: onAddChild,
        ),
        _action(
          icon: Icons.edit_outlined,
          label: '编辑', // TODO(l10n): 补 arb
          type: UtenButtonType.tonal,
          onPressed: onEdit,
        ),
        _action(
          icon: Icons.delete_outline,
          label: '删除', // TODO(l10n): 补 arb
          type: UtenButtonType.danger,
          onPressed: onDelete,
        ),
      ],
      for (final e in extraActions)
        _action(
          icon: e.icon,
          label: e.label,
          type: e.type,
          onPressed: e.onPressed,
        ),
    ];
  }

  /// 统一操作条：管理类（新增/编辑/删除 + 扩展 extraActions）与数据类
  /// （secondaryActions，如导入/导出/预览打印）合并到同一行。
  /// 两组都非空时中间插一条竖向分隔线，明确「管理 | 数据」两组。
  /// 大屏（medium+）右对齐、窄屏（compact）居中；按钮多时自动换行，三档断点都适配。
  Widget _actionBar(ThemeData theme, BuildContext context) {
    final manage = _buildButtons();
    final data = secondaryActions;
    final children = <Widget>[];
    children.addAll(manage);
    if (manage.isNotEmpty && data.isNotEmpty) {
      children.add(
        Container(
          width: 1,
          height: 22,
          color: theme.colorScheme.outlineVariant,
        ),
      );
    }
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
