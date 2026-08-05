// UtenTopBannerCard —— 顶部横幅统一视觉外壳
// 文档：docs/02-组件库/UtenNotify.md §四 / AppNotification.md §四
//
// 连接恢复横幅（ConnectionRecoveryBanner）与普通通知横幅（_AppNotificationBanner）
// 共用本组件，保证两者"居中 / 最大宽 720 / 圆角 14 / elevation 4 / 柔和容器色"
// 完全同款。各调用方只负责自己的生命周期（动画、自动消失、相位切换、重试按钮），
// 把背景色、前景色、图标、正文、可选尾部件交给本卡片渲染。
//
// 不要在业务代码里直接用本组件；通知走 UtenNotify 门面，连接态走 ConnectionRecoveryBanner。

import 'package:flutter/material.dart';

/// 两条顶部横幅共用的视觉外壳。
///
/// 渲染：`SafeArea(minimum 12,8,12,0)` → `Center` → `ConstrainedBox(maxWidth)` →
/// `Semantics(container + liveRegion)` → `Material(elevation 4, 圆角 14)` →
/// `Column[ Row[图标, 正文, 尾部件], 可选底部进度条 ]`。
///
/// - [semanticLabel] 非 null 时整条作为一句播报（连接横幅）；为 null 时走
///   `explicitChildNodes`，让标题/正文子节点被分别朗读（普通通知多行文案场景）。
/// - [key] 透传给 super，供 `AnimatedSwitcher` 用 `ValueKey` 区分相位时切换。
class UtenTopBannerCard extends StatelessWidget {
  const UtenTopBannerCard({
    super.key,
    required this.background,
    required this.foreground,
    required this.icon,
    required this.content,
    this.iconSize = 24,
    this.trailing,
    this.progress = false,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.semanticLabel,
    this.maxWidth = 720,
    this.onTap,
  });

  /// 卡片背景色（柔和容器色：*Container）。
  final Color background;

  /// 前景色（文字 / 图标 / 进度条，对应 on*Container）。
  final Color foreground;

  /// 左侧语义图标。
  final IconData icon;

  /// 图标尺寸，默认 24（与连接横幅一致）。
  final double iconSize;

  /// 中间正文（消息 / 标题+正文+字段错误列）。
  final Widget content;

  /// 右侧尾部件（重试按钮 / 关闭按钮），null 时不渲染。
  final Widget? trailing;

  /// 是否显示底部 LinearProgressIndicator（连接重连/断开时用）。
  final bool progress;

  /// 正文行的纵向对齐：连接横幅用默认 center；普通通知多行用 start。
  final CrossAxisAlignment crossAxisAlignment;

  /// 整条无障碍标签：非 null→label 模式；null→explicitChildNodes 模式。
  final String? semanticLabel;

  /// 最大宽度，默认 720（宽屏不无限拉伸，与连接横幅一致）。
  final double maxWidth;

  /// 点击整张卡片（普通通知：执行跳转/动作后自动关闭）。null 时不可点（连接横幅）。
  /// 提供 [onTap] 时，正文会包裹在 `InkWell` 中（位于彩色 Material 之上，水波纹正常）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Semantics(
            container: true,
            liveRegion: true,
            label: semanticLabel,
            explicitChildNodes: semanticLabel == null,
            child: Material(
              color: background,
              elevation: 4,
              shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: _body(),
            ),
          ),
        ),
      ),
    );
  }

  /// 正文列；提供 [onTap] 时包一层 InkWell（位于彩色 Material 之上，水波纹正常）。
  Widget _body() {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(
            crossAxisAlignment: crossAxisAlignment,
            children: [
              Icon(icon, color: foreground, size: iconSize),
              const SizedBox(width: 12),
              Expanded(child: content),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
        if (progress)
          LinearProgressIndicator(
            minHeight: 3,
            color: foreground,
            backgroundColor: Colors.transparent,
          ),
      ],
    );
    if (onTap == null) return column;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: column,
    );
  }
}
