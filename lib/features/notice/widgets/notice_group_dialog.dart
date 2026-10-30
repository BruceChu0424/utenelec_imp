// Same-object stacks unfold into full notification cards on a dimmed stage.
//
// 展开舞台（2026-10-29 柔光叠放改版·独立卡片版）：
// - 点叠放卡后：背景逐渐变暗并出现柔和模糊（性能档 lite / 关闭动画时
//   自动退回纯暗化），注意力集中到当前通知组；
// - 展开区**没有容器底板**：每张通知卡都是独立卡片，直接浮在暗化的
//   页面上，单列居中排列、间距收窄；内容多时列表滚动；
// - 每张卡从原叠放位置（组卡矩形）各自飞出到自己的落位——先到的卡
//   先走，柔和启动、接近落位减速（easeInOutCubic），逐张错峰拉开，
//   收起时沿原路反向汇聚回堆叠原位；
// - 头部信息（类型 + 共 N 条 + 全部已读 + 收起）浮在卡列上方，
//   不做底板背景；收起 = 收起按钮 / 点背景空白 / Esc。
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_close_button.dart';
import '../../../components/feedback/uten_motion.dart';
import '../../../core/performance/performance_tier.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/performance_provider.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../models/notice.dart';
import '../models/notice_group.dart';
import '../providers/notice_providers.dart';
import 'notice_card.dart';
import 'notice_detail_dialog.dart';

/// The source rectangle is captured before pushing, in the root overlay's coordinates.
Future<void> showNoticeGroupDialog(
  BuildContext originContext, {
  required NoticeGroup group,
  Rect? originRect,
}) {
  final duration = utenMotionDurationOf(originContext, UtenAnim.slow);
  final isLight = Theme.of(originContext).brightness == Brightness.light;
  return showGeneralDialog<void>(
    context: originContext,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(
      originContext,
    ).modalBarrierDismissLabel,
    // 独立卡片直接浮在页面上，遮罩承担全部「暗下来」的职责：
    // 浅色主题底亮，压得深一档才稳得住白色头部文字。
    barrierColor: Colors.black.withValues(alpha: isLight ? 0.52 : 0.46),
    transitionDuration: duration,
    pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => Center(
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.min(
                  560,
                  math.max(0, constraints.maxWidth - UtenSpacing.s32),
                ),
                maxHeight: math.max(0, constraints.maxHeight - UtenSpacing.s32),
              ),
              child: _NoticeGroupPanel(
                group: group,
                originContext: originContext,
                animation: animation,
                originRect: originRect,
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final blur = _stageBlurOf(context, animation.value);
      if (blur <= 0) return child;
      // 柔和模糊层：不参与命中测试，点击空白仍落到遮罩上收起。
      return Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          child,
        ],
      );
    },
  );
}

/// 展开期背景模糊强度；lite 性能档 / 关闭动画 / 无 provider 作用域时
/// 退回 0（纯暗化遮罩）。随转场进度柔和淡入淡出。
double _stageBlurOf(BuildContext context, double t) {
  if (MediaQuery.disableAnimationsOf(context)) return 0;
  try {
    final tier = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(performanceProvider);
    if (!tier.enableBlur) return 0;
  } on StateError {
    return 0;
  }
  return 14 * Curves.easeOut.transform(t);
}

class _NoticeGroupPanel extends StatefulWidget {
  const _NoticeGroupPanel({
    required this.group,
    required this.originContext,
    required this.animation,
    this.originRect,
  });
  final NoticeGroup group;
  final BuildContext originContext;
  final Animation<double> animation;

  /// 组卡在 overlay 坐标系里的矩形；卡片从这里飞出到落位。
  final Rect? originRect;

  @override
  State<_NoticeGroupPanel> createState() => _NoticeGroupPanelState();
}

class _NoticeGroupPanelState extends State<_NoticeGroupPanel> {
  final Set<String> _readIds = {};
  bool _markingAll = false;
  String? _openingId;

  /// 每张卡的零尺寸布局锚点：读「未受 Transform 影响的真实落位」，
  /// 飞行位移 = 原堆叠中心 - 落位中心。
  final List<GlobalKey> _anchors = [];

  @override
  void initState() {
    super.initState();
    _syncAnchors();
  }

  void _syncAnchors() {
    while (_anchors.length < widget.group.notices.length) {
      _anchors.add(GlobalKey());
    }
  }

  bool _isUnread(Notice notice) =>
      !notice.isRead && !_readIds.contains(notice.id);
  int get _unreadCount => widget.group.notices.where(_isUnread).length;

  Future<void> _openNotice(Notice notice) async {
    if (_openingId != null || _markingAll) return;
    setState(() => _openingId = notice.id);
    final container = ProviderScope.containerOf(
      widget.originContext,
      listen: false,
    );
    try {
      if (_isUnread(notice)) {
        await markNoticeReadContainer(container, notice.id);
        if (!mounted) return;
        setState(() => _readIds.add(notice.id));
      }
      if (!mounted || !widget.originContext.mounted) return;
      await showNoticeDetailDialog(
        widget.originContext,
        noticeId: notice.id,
        // A business action must dismiss both the detail and this group stage.
        onBeforeActionNavigate: () {
          if (mounted && ModalRoute.of(context)?.isCurrent == true) {
            Navigator.of(context).pop();
          }
        },
      );
    } catch (error) {
      if (mounted) context.appError(humanErrorMessage(error) ?? '通知打开失败，请重试');
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  Future<void> _markAllRead() async {
    final targets = widget.group.notices.where(_isUnread).toList();
    if (targets.isEmpty || _markingAll || _openingId != null) return;
    setState(() => _markingAll = true);
    final container = ProviderScope.containerOf(
      widget.originContext,
      listen: false,
    );
    var failed = 0;
    try {
      for (final notice in targets) {
        if (!mounted || !widget.originContext.mounted) break;
        try {
          await markNoticeReadContainer(container, notice.id);
          if (mounted) setState(() => _readIds.add(notice.id));
        } catch (_) {
          failed++;
        }
      }
      if (mounted && failed > 0) context.appError('$failed 条通知未能标为已读，请重试');
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = _unreadCount;
    final notices = [...widget.group.notices]
      ..sort((a, b) {
        if (_isUnread(a) != _isUnread(b)) return _isUnread(a) ? -1 : 1;
        final byTime = b.publishedAt.compareTo(a.publishedAt);
        return byTime == 0 ? a.id.compareTo(b.id) : byTime;
      });
    _syncAnchors();
    return Material(
      key: const ValueKey('notice-group-stage'),
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(unread, notices.length),
          Flexible(
            child: ListView.separated(
              key: const PageStorageKey('notice-group-cards'),
              shrinkWrap: true,
              padding: const EdgeInsets.only(top: UtenSpacing.s12),
              itemCount: notices.length,
              separatorBuilder: (_, index) =>
                  const SizedBox(height: UtenSpacing.s12),
              itemBuilder: (context, index) =>
                  _buildCard(index, notices[index]),
            ),
          ),
        ],
      ),
    );
  }

  /// 浮动头部：类型图标 + 计数/未读副题 + 全部已读 + 收起。
  /// 不做底板背景，文字用白色系压在暗化页面上；卡片就位后再落定。
  Widget _buildHeader(int unread, int total) {
    final typeColor = widget.group.face.type.color;
    return AnimatedBuilder(
      animation: widget.animation,
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: typeColor,
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.45),
                width: 1.5,
              ),
            ),
            child: Icon(
              widget.group.face.type.icon,
              size: 19,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '相关通知',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s2),
                Text(
                  '共 $total 条${unread > 0 ? ' · 未读 $unread 条' : ' · 全部已读'}，未读排在前面',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          if (unread > 0)
            TextButton.icon(
              onPressed: _markingAll || _openingId != null
                  ? null
                  : _markAllRead,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                disabledForegroundColor: Colors.white.withValues(alpha: 0.38),
              ),
              icon: _markingAll
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.done_all_rounded, size: 18),
              label: const Text('全部已读'),
            ),
          UtenCloseButton(
            tooltip: '收起相关通知',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
      builder: (context, child) {
        final fade = const Interval(
          0.45,
          0.82,
          curve: Curves.easeOut,
        ).transform(widget.animation.value);
        return Opacity(
          opacity: fade,
          child: Transform.translate(
            offset: Offset(0, -8 * (1 - fade)),
            child: child,
          ),
        );
      },
    );
  }

  /// 独立卡片：从原叠放位置飞出到落位（先到的卡先走、逐张错峰）。
  /// 锚点零尺寸 SizedBox 与卡同级，读到的全局坐标不含本卡 Transform。
  Widget _buildCard(int index, Notice notice) {
    final anchor = _anchors[index];
    return Stack(
      children: [
        SizedBox(key: anchor, width: 0, height: 0),
        AnimatedBuilder(
          animation: widget.animation,
          child: NoticeCard(
            notice: notice,
            unread: _isUnread(notice),
            showInteractions: false,
            onTap: () => _openNotice(notice),
          ),
          builder: (context, child) {
            final t = widget.animation.value;
            final start = math.min(0.06 + index * 0.07, 0.5);
            final flight = Interval(
              start,
              math.min(start + 0.62, 1.0),
              curve: Curves.easeInOutCubic,
            ).transform(t);
            final fade = Interval(
              start,
              math.min(start + 0.2, 1.0),
              curve: Curves.easeOut,
            ).transform(t);

            var delta = Offset(0, 26 * (1 - flight));
            var scale = 0.97 + 0.03 * flight;
            final anchorObject = anchor.currentContext?.findRenderObject();
            if (widget.originRect != null &&
                anchorObject is RenderBox &&
                anchorObject.hasSize &&
                anchorObject.parent is RenderBox &&
                (anchorObject.parent! as RenderBox).hasSize) {
              final anchorParent = anchorObject.parent! as RenderBox;
              final cardCenter = anchorObject.localToGlobal(
                anchorParent.size.center(Offset.zero),
              );
              final stackCenter =
                  widget.originRect!.center + Offset(0, index * 8.0);
              delta = (stackCenter - cardCenter) * (1 - flight);
              final initialScale =
                  (widget.originRect!.width / anchorParent.size.width).clamp(
                    0.3,
                    0.95,
                  );
              scale = initialScale + (1 - initialScale) * flight;
            }
            return Transform.translate(
              key: ValueKey('notice-unfold-${notice.id}'),
              offset: delta,
              child: Transform.scale(
                scale: scale,
                child: Opacity(opacity: fade, child: child),
              ),
            );
          },
        ),
      ],
    );
  }
}
