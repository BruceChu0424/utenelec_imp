// UtenLocationField + showUtenPickerSheet —— "添加位置"统一交互组件
//
// 解决旧版"添加分类/部门"对话框的两个问题：
//  1) 选父级用「对话框套对话框」（叠弹窗，窄屏难用）→ 改响应式底部抽屉 / 右侧抽屉。
//  2) 层级不透明（"几级几级不知道怎么选"）→ 位置卡片显式展示「父级 + 结果层级」。
// 货品/模具分类、部门管理 共用本组件；树内容（UtenCategoryTreeView /
//  UtenDepartmentTreeView）由调用方作为 childBuilder 传入，保留领域差异。
import 'package:flutter/material.dart';

import '../../core/responsive/breakpoint.dart';
import '../../core/theme/uten_tokens.dart';

/// 位置选择结果。
/// - 返回 null：用户取消（关闭抽屉）。
/// - isRoot=true：选了「顶级」（无父级）。
/// - node 非 null：选了该节点作父级。
typedef LocationPickResult<T> = ({T? node, bool isRoot});

/// 「添加位置」卡片：父级路径 + 结果层级徽标 + 「更改」入口。
///
/// 给新增/编辑分类·部门对话框用：把"父级"从一个不起眼的只读输入框，
/// 升级为一张显眼卡片，并明示新节点将落在第几级。
class UtenLocationField extends StatelessWidget {
  const UtenLocationField({
    super.key,
    required this.pathLabel,
    required this.resultLevelLabel,
    required this.onTap,
    this.headingLabel = '添加位置',
    this.changeLabel = '更改',
    this.rootLabel = '顶级',
    this.enabled = true,
  });

  /// 父级路径文案（如「V5系列模具」或「成品 › 包装材料」）；为空显示 rootLabel。
  final String? pathLabel;

  /// 「顶级」时显示的文案。
  final String rootLabel;

  /// 新节点结果层级（如「L2」「二级班组」）。
  final String resultLevelLabel;

  /// 卡片标题（默认「添加位置」）。
  final String headingLabel;

  /// 「更改」按钮文案。
  final String changeLabel;

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRoot = pathLabel == null || pathLabel!.isEmpty;
    final display = isRoot ? rootLabel : pathLabel!;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: UtenRadius.mdAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: UtenRadius.mdAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s12,
          ),
          child: Row(
            children: [
              Icon(
                isRoot
                    ? Icons.account_tree_outlined
                    : Icons.folder_open_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      headingLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      display,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              // 结果层级徽标
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s8,
                  vertical: UtenSpacing.s4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: UtenRadius.smAll,
                ),
                child: Text(
                  resultLevelLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (enabled) ...[
                const SizedBox(width: UtenSpacing.s4),
                Text(
                  changeLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 响应式位置选择器：compact=底部抽屉（~85% 高），medium+=右侧抽屉（420 宽）。
///
/// [childBuilder] 由调用方构造自己的树（UtenCategoryTreeView / UtenDepartmentTreeView），
/// 在 onToggleSelect 里调 [onSelect]；顶部自动渲染一个「{rootLabel}」行，点它调 [onSelectRoot]。
/// 关闭/背景返回 null（取消）。
Future<LocationPickResult<T>?> showUtenPickerSheet<T>({
  required BuildContext context,
  required String title,
  required String rootLabel,
  required Widget Function(
    BuildContext sheetCtx,
    void Function(T node) onSelect,
    void Function() onSelectRoot,
  ) childBuilder,
  String? rootHint,
  String searchHint = '搜索',
  bool showRootOption = true,
}) {
  Widget buildSheet(BuildContext sheetCtx) {
    void select(T n) => Navigator.of(sheetCtx).pop<LocationPickResult<T>>(
          (node: n, isRoot: false),
        );
    void selectRoot() => Navigator.of(sheetCtx).pop<LocationPickResult<T>>(
          (node: null, isRoot: true),
        );
    final theme = Theme.of(sheetCtx);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            UtenSpacing.s12,
            UtenSpacing.s8,
            UtenSpacing.s4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(sheetCtx).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 顶级行：选它表示无父级（新节点落顶层）。编辑模式（后端不支持移到根）可隐藏。
        if (showRootOption) ...[
          ListTile(
            leading: Icon(
              Icons.account_tree_outlined,
              color: theme.colorScheme.primary,
            ),
            title: Text(rootLabel),
            subtitle: rootHint == null ? null : Text(rootHint),
            onTap: selectRoot,
          ),
          const Divider(height: 1),
        ],
        Expanded(child: childBuilder(sheetCtx, select, selectRoot)),
      ],
    );
  }

  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<LocationPickResult<T>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(ctx).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.85,
          child: Material(
            color: Theme.of(ctx).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(UtenRadius.lg),
            ),
            clipBehavior: Clip.antiAlias,
            child: buildSheet(ctx),
          ),
        ),
      ),
    );
  }
  return showGeneralDialog<LocationPickResult<T>>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: SizedBox(width: 420, height: double.infinity, child: buildSheet(ctx)),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}
