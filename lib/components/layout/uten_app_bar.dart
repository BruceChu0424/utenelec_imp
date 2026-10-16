// UtenAppBar - 自适应顶栏
// 文档：docs/02-组件库/UtenAppBar.md（待写）
//
// 设计原则：
// - 标题层级清晰：标题 17px w600，副标题 12px textTertiary
// - 用发丝级底部分隔线代替阴影分层（elevation 恒为 0）
// - blurred 变体：半透明背景 + 背景模糊，用于内容可从顶栏下方滚过的场景

import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../shared/auth/page_permission_action.dart';
import '../buttons/uten_back_button.dart';
import '../../shared/ai/page_context/ai_page_context.dart';
import 'uten_adaptive_panel.dart';
import 'uten_app_bar_action_scope.dart';
import 'uten_fit_or_compact.dart';
import '../buttons/uten_button.dart';
import '../buttons/uten_app_bar_action_button.dart';

/// Uten 自适应顶栏
///
/// 在手机端显示紧凑标题，在大屏端可以扩展显示副标题/操作区。
class UtenAppBar extends StatefulWidget implements PreferredSizeWidget {
  const UtenAppBar({
    super.key,
    this.title,
    this.subtitle,
    this.leading,
    this.actions,
    this.centerTitle = false,
    this.showBackButton = false,
    this.backgroundColor,
    this.foregroundColor,
    this.bottom,
    this.flexibleSpace,
    this.showBottomBorder = true,
    this.blurred = false,
    this.centerWidget,
    this.titleWidget,
    this.showPagePermissionAction = true,
  });

  final String? title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget>? actions;
  final bool centerTitle;
  final bool showBackButton;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final PreferredSizeWidget? bottom;
  final Widget? flexibleSpace;

  /// 标题区内「居中」部件（如列表页的 [UtenSegmentedFilter]）。
  /// 与 [title] 共存：[title] 文字靠最左，[centerWidget] 在标题区水平居中；
  /// 向部件提供实际可用宽度，由其响应式布局保留可读字号。
  final Widget? centerWidget;

  /// 完全自定义标题区（整体替换 [title] / [centerWidget]，优先级最高）。
  final Widget? titleWidget;

  /// 自动在已登记的员工业务页末尾追加“本页权限”。服务端能力探测为 false 时不占位。
  ///
  /// 登录/个人自助/全局权限页等没有 [PagePermissionScope] 的页面会自动隐藏；
  /// 极少数嵌套 AppBar 可显式关闭，避免重复入口。
  final bool showPagePermissionAction;

  /// 是否显示底部发丝级分隔线（带 TabBar 等 bottom 时可关闭）
  final bool showBottomBorder;

  /// 毛玻璃变体：半透明背景 + BackdropFilter 模糊。
  /// 适合内容从顶栏下方滚过的沉浸式页面；性能敏感场景慎用（blur 有开销）。
  final bool blurred;

  @override
  State<UtenAppBar> createState() => _UtenAppBarState();

  @override
  Size get preferredSize {
    final bottomHeight = bottom?.preferredSize.height ?? 0;
    return Size.fromHeight(
      subtitle != null ? 64 + bottomHeight : 56 + bottomHeight,
    );
  }
}

class _UtenAppBarState extends State<UtenAppBar> {
  int _actionRevision = 0;
  _AppBarActionPanel? _actionPanel;

  String? get title => widget.title;
  String? get subtitle => widget.subtitle;
  Widget? get leading => widget.leading;
  List<Widget>? get actions => widget.actions;
  bool get centerTitle => widget.centerTitle;
  bool get showBackButton => widget.showBackButton;
  Color? get backgroundColor => widget.backgroundColor;
  Color? get foregroundColor => widget.foregroundColor;
  PreferredSizeWidget? get bottom => widget.bottom;
  Widget? get flexibleSpace => widget.flexibleSpace;
  bool get showBottomBorder => widget.showBottomBorder;
  bool get blurred => widget.blurred;
  Widget? get centerWidget => widget.centerWidget;
  Widget? get titleWidget => widget.titleWidget;
  bool get showPagePermissionAction => widget.showPagePermissionAction;

  @override
  void dispose() {
    ++_actionRevision;
    final panel = _actionPanel;
    if (panel != null && !panel.claimed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => panel.dismiss());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final revision = ++_actionRevision;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final baseColor =
        backgroundColor ??
        theme.appBarTheme.backgroundColor ??
        (isDark ? UtenColors.darkBackground : UtenColors.background);
    final dividerColor =
        theme.dividerTheme.color ??
        (isDark ? UtenColors.darkBorder : UtenColors.divider);

    final pageActions = <Widget>[
      ...?actions,
      if (showPagePermissionAction)
        PagePermissionAction(scope: pagePermissionScopeFromContext(context)),
    ];
    Widget textAction(Widget source) {
      if (source is Padding) {
        return Padding(
          key: source.key,
          padding: source.padding,
          child: source.child == null ? null : textAction(source.child!),
        );
      }
      if (source is SizedBox) {
        return SizedBox(
          key: source.key,
          width: source.width,
          height: source.height,
          child: source.child == null ? null : textAction(source.child!),
        );
      }
      if (source is Align) {
        return Align(
          key: source.key,
          alignment: source.alignment,
          widthFactor: source.widthFactor,
          heightFactor: source.heightFactor,
          child: source.child == null ? null : textAction(source.child!),
        );
      }
      if (source is IconButton) {
        final icon = source.icon;
        final label =
            (icon is Icon &&
                (icon.icon == Icons.refresh ||
                    icon.icon == Icons.refresh_rounded)
            ? '刷新'
            : icon is Icon &&
                  (icon.icon == Icons.close || icon.icon == Icons.close_rounded)
            ? '关闭'
            : source.tooltip ?? '操作');
        return UtenAppBarActionButton(
          key: source.key,
          label: label,
          tooltip: source.tooltip,
          onPressed: source.onPressed,
          onLongPress: source.onLongPress,
        );
      }
      if (source is ButtonStyleButton) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: UtenAppBarNativeActionButton(
            source: source,
            onPressed: source.onPressed,
            onLongPress: source.onLongPress,
          ),
        );
      }
      return source;
    }

    final presentedActions = [
      for (final action in pageActions) textAction(action),
    ];
    final panel = _actionPanel;
    if (panel != null && !panel.claimed) {
      // The old controls become inert immediately. Publish after this build so
      // a sibling modal route is never marked dirty during the page's build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            revision != _actionRevision ||
            !identical(panel, _actionPanel) ||
            panel.claimed) {
          return;
        }
        panel.presentation.value = (
          revision: revision,
          actions: presentedActions,
        );
      });
    }
    final appBar = LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        // Reserve readable title space, then measure the actual action labels.
        // A fixed phone breakpoint misses crowded tablet/desktop windows and
        // enlarged text. Hidden presentations retain their state and callbacks.
        final titleBudget = (constraints.maxWidth * 0.35).clamp(
          140 * textScale,
          360 * textScale,
        );
        final availableActionWidth =
            (constraints.maxWidth -
                    (leading != null || showBackButton ? kToolbarHeight : 0))
                .clamp(0.0, constraints.maxWidth);
        final actionBudget = (constraints.maxWidth - titleBudget - 80).clamp(
          (112 * textScale).clamp(0.0, availableActionWidth),
          availableActionWidth,
        );
        final expandedActions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in presentedActions)
              UtenAppBarActionPresentation(child: action),
          ],
        );
        final compactAction = UtenAppBarActionPresentation(
          child: UtenAppBarActionButton(
            key: const Key('uten-app-bar-more-actions'),
            label: actionBudget < 112 * textScale ? '操作' : '更多操作',
            tooltip: '更多操作',
            onPressed: () => _showActions(context, presentedActions, revision),
          ),
        );
        return AppBar(
          title: _buildTitleArea(context, theme, isDark),
          leading:
              leading ??
              (showBackButton
                  ? const UtenBackButton()
                  : const SizedBox.shrink()),
          automaticallyImplyLeading: false,
          leadingWidth: leading == null && !showBackButton ? 0 : null,
          actions: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: actionBudget),
              child: UtenFitOrCompact(
                expanded: expandedActions,
                compact: compactAction,
                forceCompact:
                    (actions?.isNotEmpty ?? false) &&
                    constraints.maxWidth < 600 * textScale,
              ),
            ),
          ],
          centerTitle: centerTitle,
          backgroundColor: blurred
              ? baseColor.withValues(alpha: 0.8)
              : baseColor,
          foregroundColor: foregroundColor ?? theme.appBarTheme.foregroundColor,
          bottom: bottom,
          flexibleSpace: flexibleSpace,
          // 发丝级底部分隔线代替阴影
          shape: showBottomBorder
              ? Border(bottom: BorderSide(color: dividerColor, width: 0.5))
              : null,
        );
      },
    );

    // ADR-150: the page title tells the AI assistant which page it reads.
    final pageTitle = title;
    Widget titled(Widget child) => pageTitle == null || pageTitle.isEmpty
        ? child
        : AiPageRegistrar(
            source: AiPageInfoSource(title: (_) => pageTitle),
            child: child,
          );
    if (!blurred) return titled(appBar);

    // 毛玻璃：裁剪矩形内做背景模糊（AppBar 自身无圆角，ClipRect 即可）
    return titled(
      ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: appBar,
        ),
      ),
    );
  }

  Future<void> _showActions(
    BuildContext context,
    List<Widget> pageActions,
    int revision,
  ) {
    if (!mounted || revision != _actionRevision) return Future<void>.value();
    final panel = _AppBarActionPanel(_actionRevision, pageActions);
    _actionPanel = panel;
    bool claim(int revision) {
      if (!mounted ||
          revision != _actionRevision ||
          panel.claimed ||
          panel.route?.isCurrent != true) {
        return false;
      }
      panel.claimed = true;
      return true;
    }

    void dismiss() => panel.dismiss();

    VoidCallback? before(VoidCallback? callback, int revision) =>
        callback == null
        ? null
        : () {
            if (!claim(revision)) return;
            dismiss();
            callback();
          };
    Widget present(Widget source, BuildContext panelContext, int revision) {
      if (source is Padding) {
        return Padding(
          key: source.key,
          padding: source.padding,
          child: source.child == null
              ? null
              : present(source.child!, panelContext, revision),
        );
      }
      if (source is SizedBox) {
        return SizedBox(
          key: source.key,
          width: source.width,
          height: source.height,
          child: source.child == null
              ? null
              : present(source.child!, panelContext, revision),
        );
      }
      if (source is Align) {
        return Align(
          key: source.key,
          alignment: source.alignment,
          widthFactor: source.widthFactor,
          heightFactor: source.heightFactor,
          child: source.child == null
              ? null
              : present(source.child!, panelContext, revision),
        );
      }
      if (source is IconButton) {
        return IconButton(
          key: source.key,
          icon: source.icon,
          iconSize: source.iconSize,
          visualDensity: source.visualDensity,
          padding: source.padding,
          alignment: source.alignment,
          splashRadius: source.splashRadius,
          color: source.color,
          focusColor: source.focusColor,
          hoverColor: source.hoverColor,
          highlightColor: source.highlightColor,
          splashColor: source.splashColor,
          disabledColor: source.disabledColor,
          onPressed: before(source.onPressed, revision),
          onLongPress: before(source.onLongPress, revision),
          onHover: source.onHover,
          mouseCursor: source.mouseCursor,
          focusNode: source.focusNode,
          autofocus: source.autofocus,
          tooltip: source.tooltip,
          enableFeedback: source.enableFeedback,
          constraints: source.constraints,
          style: source.style,
          isSelected: source.isSelected,
          selectedIcon: source.selectedIcon,
          statesController: source.statesController,
        );
      }
      final native = source;
      if (native is ButtonStyleButton) {
        return UtenAppBarNativeActionButton(
          key: source.key,
          source: native,
          onPressed: before(native.onPressed, revision),
          onLongPress: before(native.onLongPress, revision),
        );
      }
      if (source is UtenButton || source is UtenAppBarActionButton) {
        return UtenAppBarActionPresentation(
          child: UtenAppBarActionScope(
            actionContext: context,
            claimAction: () => claim(revision),
            dismiss: dismiss,
            closeBeforeAction: true,
            child: source,
          ),
        );
      }
      return source;
    }

    return showUtenAdaptivePanel<void>(
      context: context,
      compactHeightFactor: 0.5,
      builder: (panelContext) {
        panel.route = ModalRoute.of<void>(panelContext);
        return ValueListenableBuilder<_AppBarActionPresentation>(
          valueListenable: panel.presentation,
          builder: (_, presentation, _) => UtenAppBarActionScope(
            actionContext: context,
            claimAction: () => claim(presentation.revision),
            dismiss: dismiss,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title ?? '页面操作',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(panelContext).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭操作面板',
                        onPressed: () => Navigator.of(panelContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: UtenAppBarActionPresentation(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 12,
                        children: [
                          for (final action in presentation.actions)
                            present(
                              action,
                              panelContext,
                              presentation.revision,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      if (identical(_actionPanel, panel)) _actionPanel = null;
      panel.presentation.dispose();
    });
  }

  /// 组合标题区，优先级：[titleWidget] > [title]+[centerWidget] > [title]。
  Widget? _buildTitleArea(BuildContext context, ThemeData theme, bool isDark) {
    if (titleWidget != null) return titleWidget;

    final titleCol = title != null
        ? _titleColumn(context, theme, isDark)
        : null;
    if (centerWidget == null) return titleCol;

    // Both receive bounded space, so filters can switch to their compact mode
    // rather than rendering at full width and scaling their text back down.
    return Row(
      children: [
        if (titleCol != null) Flexible(child: titleCol),
        Expanded(child: Center(child: centerWidget!)),
      ],
    );
  }

  Widget _titleColumn(BuildContext context, ThemeData theme, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: subtitle == null ? title! : '$title\n$subtitle',
          child: Text(
            title!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.appBarTheme.titleTextStyle?.copyWith(
              color: foregroundColor ?? theme.colorScheme.onSurface,
            ),
          ),
        ),
        if (subtitle != null &&
            MediaQuery.textScalerOf(context).scale(14) <= 18)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w400,
                height: 1.3,
                color:
                    foregroundColor?.withValues(alpha: 0.7) ??
                    (isDark
                        ? UtenColors.darkTextTertiary
                        : UtenColors.textTertiary),
              ),
            ),
          ),
      ],
    );
  }
}

typedef _AppBarActionPresentation = ({int revision, List<Widget> actions});

class _AppBarActionPanel {
  _AppBarActionPanel(int revision, List<Widget> actions)
    : presentation = ValueNotifier((revision: revision, actions: actions));
  final ValueNotifier<_AppBarActionPresentation> presentation;
  ModalRoute<void>? route;
  bool claimed = false;

  void dismiss() {
    final current = route;
    final navigator = current?.navigator;
    if (current == null || navigator == null || !current.isActive) return;
    if (current.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(current);
    }
  }
}
