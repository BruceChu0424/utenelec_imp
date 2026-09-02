// UtenLocationField + showUtenPickerSheet —— "添加位置"统一交互组件
//
// 解决旧版"添加分类/部门"对话框的两个问题：
//  1) 选父级用「对话框套对话框」（叠弹窗，窄屏难用）→ 改响应式底部抽屉 / 右侧抽屉。
//  2) 层级不透明（"几级几级不知道怎么选"）→ 位置卡片显式展示「父级 + 结果层级」。
// 货品/模具分类、部门管理 共用本组件；树内容（UtenCategoryTreeView /
//  UtenDepartmentTreeView）由调用方作为 childBuilder 传入，保留领域差异。
import 'package:flutter/material.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/layout/uten_adaptive_panel.dart';
import '../../components/layout/uten_bottom_action_bar.dart';
import '../../core/theme/uten_tokens.dart';

/// 位置选择结果。
/// - 返回 null：用户取消（关闭抽屉）。
/// - isRoot=true：选了「顶级」（无父级）。
/// - node 非 null：选了该节点作父级。
typedef LocationPickResult<T> = ({T? node, bool isRoot});

/// 位置树内容构造器。
///
/// [pendingSelection] 是抽屉内的暂存选择；调用方用它刷新树的选中标记。
/// 只有用户点击“确定”后，暂存值才会作为 [showUtenPickerSheet] 的结果返回。
typedef UtenLocationPickerChildBuilder<T> = Widget Function(
  BuildContext sheetContext,
  LocationPickResult<T>? pendingSelection,
  ValueChanged<T> onSelect,
  VoidCallback onSelectRoot,
);

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
/// [childBuilder] 由调用方构造自己的树（UtenCategoryTreeView / UtenDepartmentTreeView）。
/// 点击节点只更新抽屉内暂存选择；点击“确定”才返回，取消/关闭/背景返回 null。
Future<LocationPickResult<T>?> showUtenPickerSheet<T>({
  required BuildContext context,
  required String title,
  required String rootLabel,
  required UtenLocationPickerChildBuilder<T> childBuilder,
  LocationPickResult<T>? initialSelection,
  String? rootHint,
  String searchHint = '搜索',
  bool showRootOption = true,
  String cancelLabel = '取消',
  String confirmLabel = '确定',
}) {
  Widget buildSheet(BuildContext sheetCtx) => _UtenLocationPickerSheet<T>(
    title: title,
    rootLabel: rootLabel,
    rootHint: rootHint,
    showRootOption: showRootOption,
    initialSelection: initialSelection,
    cancelLabel: cancelLabel,
    confirmLabel: confirmLabel,
    childBuilder: childBuilder,
  );

  return showUtenAdaptivePanel<LocationPickResult<T>>(
    context: context,
    builder: buildSheet,
  );
}

class _UtenLocationPickerSheet<T> extends StatefulWidget {
  const _UtenLocationPickerSheet({
    required this.title,
    required this.rootLabel,
    required this.showRootOption,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.childBuilder,
    this.rootHint,
    this.initialSelection,
  });

  final String title;
  final String rootLabel;
  final String? rootHint;
  final bool showRootOption;
  final String cancelLabel;
  final String confirmLabel;
  final UtenLocationPickerChildBuilder<T> childBuilder;
  final LocationPickResult<T>? initialSelection;

  @override
  State<_UtenLocationPickerSheet<T>> createState() =>
      _UtenLocationPickerSheetState<T>();
}

class _UtenLocationPickerSheetState<T>
    extends State<_UtenLocationPickerSheet<T>> {
  LocationPickResult<T>? _pendingSelection;

  bool get _canConfirm {
    final pending = _pendingSelection;
    return pending != null && (widget.showRootOption || !pending.isRoot);
  }

  @override
  void initState() {
    super.initState();
    _pendingSelection = widget.initialSelection;
  }

  void _select(T node) {
    setState(() => _pendingSelection = (node: node, isRoot: false));
  }

  void _selectRoot() {
    setState(() => _pendingSelection = (node: null, isRoot: true));
  }

  void _cancel() => Navigator.of(context).pop();

  void _confirm() {
    if (!_canConfirm) return;
    Navigator.of(context).pop<LocationPickResult<T>>(_pendingSelection);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rootSelected = _pendingSelection?.isRoot ?? false;
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
                  widget.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: widget.cancelLabel,
                icon: const Icon(Icons.close_rounded),
                onPressed: _cancel,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 顶级行：先暂存“无父级”，用户点击确定后再返回。
        if (widget.showRootOption) ...[
          ListTile(
            selected: rootSelected,
            selectedTileColor: theme.colorScheme.primaryContainer,
            leading: Icon(
              Icons.account_tree_outlined,
              color: theme.colorScheme.primary,
            ),
            title: Text(widget.rootLabel),
            subtitle: widget.rootHint == null ? null : Text(widget.rootHint!),
            trailing: rootSelected
                ? Icon(
                    Icons.check_circle_rounded,
                    color: theme.colorScheme.primary,
                  )
                : null,
            onTap: _selectRoot,
          ),
          const Divider(height: 1),
        ],
        Expanded(
          child: widget.childBuilder(
            context,
            _pendingSelection,
            _select,
            _selectRoot,
          ),
        ),
        UtenBottomActionBar(
          child: Row(
            children: [
              Expanded(
                child: UtenButton(
                  type: UtenButtonType.ghost,
                  size: UtenButtonSize.large,
                  isExpanded: true,
                  onPressed: _cancel,
                  child: Text(widget.cancelLabel),
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: UtenButton(
                  size: UtenButtonSize.large,
                  isExpanded: true,
                  onPressed: _canConfirm ? _confirm : null,
                  child: Text(widget.confirmLabel),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
