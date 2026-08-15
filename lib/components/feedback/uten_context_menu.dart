// UtenContextMenu - 行级上下文操作菜单（右击/长按弹出小框，三端一致）。
//
// 触发方式按平台自然降级：
// - 桌面（Windows/macOS/Linux）：鼠标右击（onSecondaryTapDown）；
// - Web：同样吃鼠标右击（需配合 main.dart 的 BrowserContextMenu.disableContextMenu()
//   屏蔽浏览器自带右键菜单，否则两个菜单叠着出）；
// - 手机/触屏：没有右键，用长按（onLongPressStart）出同一个菜单。
//
// 菜单本身是一个挂在 root Overlay 上的自绘小框（不走 PopupMenu，便于精确锚定
// 指针位置 + 控制宽度/分隔线样式），点外部、再次右击空白或选中条目后关闭；
// 靠近屏幕右/下边缘时自动向左/向上翻转，保证不出屏。
//
// 用法：
//   UtenContextMenuRegion(
//     entriesBuilder: () => [
//       UtenMenuItem(label: '复制货品', icon: Icons.copy_rounded, onTap: ...),
//       const UtenMenuDivider(),
//       UtenMenuItem(label: '删除货品', icon: Icons.delete_outline,
//           destructive: true, onTap: ...),
//     ],
//     onMenuOpening: () => 先选中该行,
//     child: 行内容,
//   )
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// 菜单条目基类（[UtenMenuItem] 或 [UtenMenuDivider]）。
sealed class UtenContextMenuEntry {
  const UtenContextMenuEntry();
}

/// 一个可点的菜单项。[enabled]=false 时置灰不可点（用于"剪贴板为空时粘贴不可用"）。
/// [destructive]=true 时图标与文字用错误色（删除/禁用类危险操作）。
class UtenMenuItem extends UtenContextMenuEntry {
  const UtenMenuItem({
    required this.label,
    required this.onTap,
    this.icon,
    this.enabled = true,
    this.destructive = false,
  });

  final String label;
  final IconData? icon;
  final bool enabled;
  final bool destructive;

  /// 点击回调（菜单先关闭，再执行回调——回调里可以安全弹对话框）。
  final VoidCallback onTap;
}

/// 菜单分组分隔线。
class UtenMenuDivider extends UtenContextMenuEntry {
  const UtenMenuDivider();
}

/// 在 [globalPosition]（全局坐标，通常取手势事件的 globalPosition）弹出菜单。
/// 条目为空时什么都不弹。返回的 Future 在菜单关闭后完成。
Future<void> showUtenContextMenu(
  BuildContext context, {
  required Offset globalPosition,
  required List<UtenContextMenuEntry> entries,
}) {
  if (entries.isEmpty) return Future.value();
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _UtenContextMenuOverlay(
      position: globalPosition,
      entries: entries,
      onDismiss: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
  return Future.value();
}

/// 给子树挂「右击/长按出菜单」能力的包裹组件。
/// [entriesBuilder] 在手势触发那一刻才调用（取最新状态决定条目可用性）；
/// 返回空列表则不弹菜单。[onMenuOpening] 在菜单弹出前同步调用（用于先把该行置为选中）。
class UtenContextMenuRegion extends StatelessWidget {
  const UtenContextMenuRegion({
    super.key,
    required this.entriesBuilder,
    required this.child,
    this.onMenuOpening,
  });

  final List<UtenContextMenuEntry> Function() entriesBuilder;
  final VoidCallback? onMenuOpening;
  final Widget child;

  void _open(BuildContext context, Offset globalPosition) {
    final entries = entriesBuilder();
    if (entries.isEmpty) return;
    onMenuOpening?.call();
    showUtenContextMenu(
      context,
      globalPosition: globalPosition,
      entries: entries,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 桌面/Web：鼠标右击。不抢单/双击（不同按键，手势竞技场互不冲突）。
      onSecondaryTapDown: (d) => _open(context, d.globalPosition),
      // 手机/触屏：长按出同一个菜单。与单击选中/双击打开共存：
      // 长按与 tap 是不同识别器，tap 先赢则长按自动取消，行为符合直觉。
      onLongPressStart: (d) => _open(context, d.globalPosition),
      child: child,
    );
  }
}

class _UtenContextMenuOverlay extends StatelessWidget {
  const _UtenContextMenuOverlay({
    required this.position,
    required this.entries,
    required this.onDismiss,
  });

  final Offset position;
  final List<UtenContextMenuEntry> entries;
  final VoidCallback onDismiss;

  static const double _menuWidth = 216;
  static const double _itemHeight = 40;
  static const double _verticalPad = 6;
  static const double _edge = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    // 估算菜单高度用于出屏翻转（条目 40 + 分隔线 9 + 上下内边距）。
    var height = _verticalPad * 2;
    for (final e in entries) {
      height += e is UtenMenuDivider ? 9 : _itemHeight;
    }
    // 水平：右边不够宽就贴到指针左侧；垂直：下边不够高就向上翻。
    final left = (position.dx + _menuWidth + _edge > size.width)
        ? (position.dx - _menuWidth).clamp(
            _edge,
            size.width - _menuWidth - _edge,
          )
        : position.dx.clamp(_edge, size.width - _menuWidth - _edge);
    final top = (position.dy + height + _edge > size.height)
        ? (position.dy - height).clamp(_edge, size.height - height - _edge)
        : position.dy.clamp(_edge, size.height - height - _edge);

    return Stack(
      children: [
        // 点菜单外任意位置关闭（左键/右键都关，与系统右键菜单行为一致）。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
            onSecondaryTapDown: (_) => onDismiss(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: theme.colorScheme.surfaceContainerHigh,
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: _menuWidth,
                maxWidth: _menuWidth,
                maxHeight: 420,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: _verticalPad),
                children: [
                  for (final e in entries)
                    e is UtenMenuDivider
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            child: Divider(height: 1, thickness: 1),
                          )
                        : _buildItem(theme, e as UtenMenuItem),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItem(ThemeData theme, UtenMenuItem item) {
    final color = !item.enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
        : item.destructive
        ? UtenColors.error
        : theme.colorScheme.onSurface;
    return InkWell(
      onTap: item.enabled
          ? () {
              onDismiss();
              item.onTap();
            }
          : null,
      child: SizedBox(
        height: _itemHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: item.icon == null
                    ? null
                    : Icon(item.icon, size: 17, color: color),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
