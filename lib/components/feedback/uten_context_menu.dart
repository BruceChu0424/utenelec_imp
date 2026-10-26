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
import '../inputs/uten_dropdown_scroll_scope.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import 'uten_context_menu_policy.dart';
import 'uten_overlay_lifecycle.dart';

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
    this.preserveSelectionAfterAction = false,
  });

  final String label;
  final IconData? icon;
  final bool enabled;
  final bool destructive;

  /// 动作自行建立了需要保留的选择（例如选中新粘贴的货品），菜单宿主不再清理
  /// 该选择。默认 false，普通菜单动作继续在完成后清除临时上下文选择。
  final bool preserveSelectionAfterAction;

  /// 点击回调（菜单先关闭，再执行回调——回调里可以安全弹对话框）。
  ///
  /// 同时接受同步与异步动作；菜单返回的 Future 会等待本回调完成，让表格能在
  /// 对话框/网络动作结束后再收口临时选中态。
  final FutureOr<void> Function() onTap;
}

/// 菜单分组分隔线。
class UtenMenuDivider extends UtenContextMenuEntry {
  const UtenMenuDivider();
}

/// 上下文菜单关闭原因。
enum UtenContextMenuCloseReason {
  /// 点菜单外、再次右击空白等，仅取消菜单，没有执行条目。
  dismissed,

  /// 已选择可用条目，并且该条目的同步/异步回调已经完成。
  actionCompleted,
}

/// Lets a widget dismiss its transient menu immediately on deactivation.
/// Once an item starts, its asynchronous business action no longer belongs to
/// this controller and continues to completion under the caller's own guards.
class UtenContextMenuController {
  VoidCallback? _dismiss;

  void dismiss() => _dismiss?.call();

  void _attach(VoidCallback dismiss) {
    this.dismiss();
    _dismiss = dismiss;
  }

  void _detach(VoidCallback dismiss) {
    if (identical(_dismiss, dismiss)) _dismiss = null;
  }
}

/// 在 [globalPosition]（全局坐标，通常取手势事件的 globalPosition）弹出菜单。
/// 条目为空时什么都不弹。返回的 Future 在菜单关闭后完成；选择条目时会继续等待
/// 条目的动作回调及 [onActionCompleted] 完成，再返回
/// [UtenContextMenuCloseReason.actionCompleted]。取消菜单不调用完成回调。
Future<UtenContextMenuCloseReason> showUtenContextMenu(
  BuildContext context, {
  required Offset globalPosition,
  required List<UtenContextMenuEntry> entries,
  FutureOr<void> Function(UtenMenuItem item)? onActionCompleted,
  UtenContextMenuController? controller,
}) {
  if (entries.isEmpty || !context.mounted) {
    return Future.value(UtenContextMenuCloseReason.dismissed);
  }
  final overlay = Overlay.of(context, rootOverlay: true);
  // 手势的 globalPosition 是窗口坐标，浮层里 Positioned 用的是浮层(画布)坐标：
  // 根部整体缩放(UtenDisplayZoomBox)时两者相差 zoom 倍，先换算到浮层坐标。
  final overlayBox = overlay.context.findRenderObject();
  final position = overlayBox is RenderBox && overlayBox.attached
      ? overlayBox.globalToLocal(globalPosition)
      : globalPosition;
  final completer = Completer<UtenContextMenuCloseReason>();
  late OverlayEntry entry;
  late UtenOverlayLifecycle lifecycle;
  var closed = false;

  void dismiss() {
    if (closed) return;
    closed = true;
    controller?._detach(dismiss);
    lifecycle.dispose();
    entry.remove();
    completer.complete(UtenContextMenuCloseReason.dismissed);
  }

  Future<void> runAction(UtenMenuItem item) async {
    if (closed) return;
    closed = true;
    controller?._detach(dismiss);
    lifecycle.dispose();
    // 必须先移除菜单，业务动作才能安全地继续弹确认框/详情框。
    entry.remove();
    try {
      await Future<void>.sync(item.onTap);
    } finally {
      try {
        await Future<void>.sync(() => onActionCompleted?.call(item));
      } finally {
        completer.complete(UtenContextMenuCloseReason.actionCompleted);
      }
    }
  }

  entry = OverlayEntry(
    builder: (ctx) => UtenDropdownScrollScope(
      child: _UtenContextMenuOverlay(
        position: position,
        entries: entries,
        onDismiss: dismiss,
        onItemSelected: (item) => unawaited(runAction(item)),
      ),
    ),
  );
  overlay.insert(entry);
  lifecycle = UtenOverlayLifecycle(onUnavailable: dismiss);
  controller?._attach(dismiss);
  lifecycle.attach(context);
  return completer.future;
}

/// 给子树挂「右击/长按出菜单」能力的包裹组件。
/// [entriesBuilder] 在手势触发那一刻才调用（取最新状态决定条目可用性）；
/// 返回空列表则不弹菜单。[onMenuOpening] 在菜单弹出前同步调用（用于先把该行置为选中）。
class UtenContextMenuRegion extends StatefulWidget {
  const UtenContextMenuRegion({
    super.key,
    required this.entriesBuilder,
    required this.child,
    this.onMenuOpening,
    this.onActionCompleted,
    this.behavior = HitTestBehavior.translucent,
  });

  final List<UtenContextMenuEntry> Function() entriesBuilder;
  final VoidCallback? onMenuOpening;
  final FutureOr<void> Function()? onActionCompleted;
  final Widget child;
  final HitTestBehavior behavior;

  @override
  State<UtenContextMenuRegion> createState() => _UtenContextMenuRegionState();
}

class _UtenContextMenuRegionState extends State<UtenContextMenuRegion> {
  final _menuController = UtenContextMenuController();

  Future<void> _open(BuildContext context, Offset globalPosition) async {
    // 菜单的可用状态依赖本次右键刚选中的行，必须先更新选择再构建条目。
    widget.onMenuOpening?.call();
    final entries = widget.entriesBuilder();
    if (entries.isEmpty) return;
    final actionCompleted = widget.onActionCompleted;
    await showUtenContextMenu(
      context,
      globalPosition: globalPosition,
      entries: entries,
      controller: _menuController,
      onActionCompleted: (item) async {
        if (!item.preserveSelectionAfterAction) {
          await Future<void>.sync(() => actionCompleted?.call());
        }
      },
    );
  }

  /// 本次右键手势的指针 id（静态：开菜单会触发宿主 setState 重建换掉闭包，
  /// 局部变量存不住跨重建的指针；同一时刻只有一路右键手势，单值即可）。
  static int? _secondaryPointerInFlight;

  @override
  void deactivate() {
    _menuController.dismiss();
    super.deactivate();
  }

  @override
  void dispose() {
    _menuController.dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 桌面右键改走原始 Listener（2026-09-15 用户反馈）：手势竞技场里更深的
    // TextField / SelectionArea 识别器会按深度优先抢走右键、弹系统「全选/复制」
    // 工具条，行级 GestureDetector 竞争不过，自家菜单时有时无。Listener 不进
    // 竞技场，右键落在行内（含输入格/可选文字）即开自家菜单。
    //
    // 同一次右键的抬键阶段，输入框仍会 toggle 出自带工具条（EditableText 在
    // Windows/Linux 于 pointer up 触发、经 ContextMenuController 上 Overlay）：
    // 在该指针抬键的微任务里 removeAny 掉它（微任务在本次事件同步分发之后、
    // 下一帧绘制之前执行，系统工具条不会闪出来），用户只看到我们的一份。
    return Listener(
      behavior: widget.behavior,
      onPointerDown: (event) {
        if (!claimUtenContextMenuPointer(event)) return;
        _secondaryPointerInFlight = event.pointer;
        unawaited(_open(context, event.position));
      },
      onPointerUp: (event) => _dismissSystemContextMenu(event.pointer),
      onPointerCancel: (event) => _dismissSystemContextMenu(event.pointer),
      child: GestureDetector(
        behavior: widget.behavior,
        // 手机/触屏：长按出同一个菜单。与单击选中/双击打开共存：
        // 长按与 tap 是不同识别器，tap 先赢则长按自动取消，行为符合直觉。
        // 只挂触屏类设备——桌面右键已由上面的 Listener 覆盖，鼠标长按留给
        // 表格行拖拽（2026-10-19 UtenTableRowDrag），否则更深的本识别器会在
        // 竞技场里抢赢鼠标长按，行永远拾不起来。
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
        },
        onLongPressStart: (d) => unawaited(_open(context, d.globalPosition)),
        child: widget.child,
      ),
    );
  }

  static void _dismissSystemContextMenu(int pointer) {
    if (_secondaryPointerInFlight != pointer) return;
    _secondaryPointerInFlight = null;
    // removeAny 对当前没有系统菜单是 no-op；只清理系统右键工具条，
    // 自家菜单是普通 OverlayEntry，不受影响。
    scheduleMicrotask(ContextMenuController.removeAny);
  }
}

class _UtenContextMenuOverlay extends StatelessWidget {
  const _UtenContextMenuOverlay({
    required this.position,
    required this.entries,
    required this.onDismiss,
    required this.onItemSelected,
  });

  final Offset position;
  final List<UtenContextMenuEntry> entries;
  final VoidCallback onDismiss;
  final ValueChanged<UtenMenuItem> onItemSelected;

  static const double _menuWidth = 216;
  static const double _verticalPad = 6;
  static const double _edge = 8;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final media = MediaQuery.of(context);
      // Positioned uses the root overlay's local canvas. MediaQuery may describe
      // a differently sized page or the physical window during display zoom and
      // embedded previews, so it must not clamp the popup away from its anchor.
      final size = Size(
        constraints.hasBoundedWidth ? constraints.maxWidth : media.size.width,
        constraints.hasBoundedHeight
            ? constraints.maxHeight
            : media.size.height,
      );
      final leftEdge =
          _edge + math.max(media.padding.left, media.viewInsets.left);
      final rightEdge =
          _edge + math.max(media.padding.right, media.viewInsets.right);
      final topEdge = _edge + math.max(media.padding.top, media.viewInsets.top);
      final bottomEdge =
          _edge + math.max(media.padding.bottom, media.viewInsets.bottom);
      final menuWidth = math.min(
        _menuWidth,
        math.max(1.0, size.width - leftEdge - rightEdge),
      );
      final availableHeight = math.max(1.0, size.height - topEdge - bottomEdge);
      final itemHeight = UtenControlMetrics.minimumHitExtent(context);
      // 按最小点击高度估算翻转位置；长标签可增高，剩余视口由菜单滚动处理。
      var height = _verticalPad * 2;
      for (final e in entries) {
        height += e is UtenMenuDivider ? 9 : itemHeight;
      }
      height = math.min(height, math.min(420, availableHeight));
      final maxLeft = math.max(leftEdge, size.width - menuWidth - rightEdge);
      final maxTop = math.max(topEdge, size.height - height - bottomEdge);
      // 水平：右边不够宽就贴到指针左侧；垂直：下边不够高就向上翻。
      final left = (position.dx + menuWidth + rightEdge > size.width)
          ? (position.dx - menuWidth).clamp(leftEdge, maxLeft)
          : position.dx.clamp(leftEdge, maxLeft);
      final top = (position.dy + height + bottomEdge > size.height)
          ? (position.dy - height).clamp(topEdge, maxTop)
          : position.dy.clamp(topEdge, maxTop);

      return Stack(
        children: [
          // 点菜单外任意位置关闭（左键/右键都关，与系统右键菜单行为一致）。
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) {
                if (event.buttons & kSecondaryButton != 0) onDismiss();
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onDismiss,
              ),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 8,
              borderRadius: BorderRadius.circular(UtenRadius.md),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: menuWidth,
                  maxWidth: menuWidth,
                  maxHeight: math.max(
                    1.0,
                    math.min(420, size.height - top - bottomEdge),
                  ),
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
                          : _buildItem(context, theme, e as UtenMenuItem),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _buildItem(BuildContext context, ThemeData theme, UtenMenuItem item) {
    final color = !item.enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
        : item.destructive
        ? UtenColors.error
        : theme.colorScheme.onSurface;
    return InkWell(
      onTap: item.enabled ? () => onItemSelected(item) : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UtenControlMetrics.minimumHitExtent(context),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
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
