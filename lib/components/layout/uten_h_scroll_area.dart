// UtenHScrollArea - 表格横向滚动区（content-tall 横滚条）。
//
// 给自绘表格提供统一的左右滚动条行为（一处实现，所有表共用，页面零重复代码）：
// - 内容不超高（表格整体在视口内）：横滚条紧贴在内容（末行）下方——滑块上缘距
//   末行约 1px（[gap] 默认 11 = 滑块厚 10 + 1px 空隙）；
// - 内容超高（表格比屏幕长）：横滚条钉在最近祖先滚动视口底，随页滑动始终可用，
//   不随内容沉到最底；表格滚出视口后横滚条自动让位，回到末行下的自然位。
//   与 UtenEditableGrid 钉底横滚条同款机制（Stack 覆盖层 + 全局位置测量）。
//
// 用法：把裸的 SingleChildScrollView(scrollDirection: Axis.horizontal, child: 表格)
// 换成 UtenHScrollArea(child: 表格)。横滚 offset 由本组件持有；需要与表头等外部
// 视图同步横滚时，经 [controller] 注入共用控制器。

import 'package:flutter/material.dart';

/// 横向滚动区：内容矮 → 横滚条贴内容底（隔 [gap]）；内容高 → 横滚条钉视口底。
class UtenHScrollArea extends StatefulWidget {
  const UtenHScrollArea({
    super.key,
    required this.child,
    this.controller,
    this.gap = _kDefaultGap,
  });

  /// 默认间距：滑块厚度（主题 thickness 10）+ 1px 视觉空隙——滑块紧贴末行下方、
  /// 不压行底线。
  static const double _kDefaultGap = 11;

  final Widget child;

  /// 外部注入的横滚控制器（与表头横滚同步等场景）；null 时组件自持并随 dispose 释放。
  final ScrollController? controller;

  /// 内容底边（末行）到滚动条 box 底边的距离（含滑块厚度 10）：默认 11，
  /// 即滑块上缘距末行约 1px。
  final double gap;

  @override
  State<UtenHScrollArea> createState() => _UtenHScrollAreaState();
}

class _UtenHScrollAreaState extends State<UtenHScrollArea> {
  /// 钉底横滚条高度（thumb 在其底部绘制）。
  static const double _barHeight = 11;

  ScrollController? _own;
  ScrollController get _h => widget.controller ?? (_own ??= ScrollController());
  late final ScrollController _pinnedH = ScrollController();
  bool _syncing = false;

  /// 挂在当前 [_h] 上的稳定监听（换注入控制器时拆旧挂新；方法 tear-off 同源相等，
  /// removeListener 能正确匹配）。
  void _onHChanged() => _syncFrom(_h);
  ScrollController? _attachedH;

  /// 滚动区 Stack / 内容 的测量键（post-frame 量全局位置与内容宽用）。
  final GlobalKey _areaKey = GlobalKey();
  final GlobalKey _contentKey = GlobalKey();

  /// 钉底横滚条底边的 local top；null=不钉（内容不超高或已滚出视口，
  /// 用末行下的自然滚动条）。
  final ValueNotifier<double?> _pinnedY = ValueNotifier<double?>(null);

  /// 钉底假滚动的内容宽（post-frame 实测内容真实宽度）。
  final ValueNotifier<double> _contentWidth = ValueNotifier<double>(0);

  /// 页面滚动监听（最近的祖先 Scrollable 的 position）。
  ScrollPosition? _pagePos;

  @override
  void initState() {
    super.initState();
    _ensureHListened();
    _pinnedH.addListener(() => _syncFrom(_pinnedH));
    _scheduleUpdate();
  }

  @override
  void didUpdateWidget(covariant UtenHScrollArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换注入控制器：拆旧监听、挂到新控制器上（自持的不动）。
    _ensureHListened();
    _scheduleUpdate();
  }

  /// [_onHChanged] 挂到当前生效的自然条控制器上（已是当前挂载对象则跳过）。
  void _ensureHListened() {
    final cur = _h;
    if (identical(cur, _attachedH)) return;
    _attachedH?.removeListener(_onHChanged);
    cur.addListener(_onHChanged);
    _attachedH = cur;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 页面上下滑（最近的祖先 Scrollable）时驱动钉底位置重算。
    final pos = Scrollable.maybeOf(context)?.position;
    if (!identical(pos, _pagePos)) {
      _pagePos?.removeListener(_scheduleUpdate);
      _pagePos = pos;
      _pagePos?.addListener(_scheduleUpdate);
    }
  }

  @override
  void dispose() {
    _pagePos?.removeListener(_scheduleUpdate);
    _attachedH?.removeListener(_onHChanged);
    _own?.dispose();
    _pinnedH.dispose();
    _pinnedY.dispose();
    _contentWidth.dispose();
    super.dispose();
  }

  /// 双向横滚同步：自然条 / 钉底条 任一滚动 → 另一个 jumpTo 跟随
  /// （[_syncing] 防回环；未挂载的控制器跳过，挂上后由下一次同步追平）。
  void _syncFrom(ScrollController src) {
    if (_syncing || !src.hasClients) return;
    _syncing = true;
    for (final d in [_h, _pinnedH]) {
      if (!identical(d, src) && d.hasClients) d.jumpTo(src.offset);
    }
    _syncing = false;
  }

  /// 布局完成后重算钉底位置（渲染对象须完成 layout 才能量）。
  void _scheduleUpdate() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updatePinned();
    });
  }

  /// 量滚动区与页面视口的全局位置：区域底在视口底之下（末行下的自然滚动条看不
  /// 到）且区域仍可见时，钉底横滚条钉视口底；否则隐藏，由自然滚动条接管。
  void _updatePinned() {
    final areaCtx = _areaKey.currentContext;
    final areaBox = areaCtx?.findRenderObject() as RenderBox?;
    final contentBox =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (areaCtx == null ||
        areaBox == null ||
        !areaBox.attached ||
        contentBox == null ||
        !contentBox.attached) {
      return;
    }
    // 内容实测宽 → 钉底假滚动宽（内容变化时随帧更新）。
    final w = contentBox.size.width;
    if (w > 0 && _contentWidth.value != w) _contentWidth.value = w;

    final scrollable = Scrollable.maybeOf(areaCtx);
    final vpBox = scrollable?.context.findRenderObject() as RenderBox?;
    if (vpBox == null || !vpBox.attached || !vpBox.hasSize) {
      if (_pinnedY.value != null) _pinnedY.value = null;
      return;
    }
    final areaTop = areaBox.localToGlobal(Offset.zero).dy;
    final areaBottom = areaTop + areaBox.size.height;
    final vpTop = vpBox.localToGlobal(Offset.zero).dy;
    final vpBottom = vpTop + vpBox.size.height;

    final double? pinnedY = (areaBottom > vpBottom && areaTop < vpBottom)
        ? vpBottom - areaTop
        : null;
    if (_pinnedY.value != pinnedY) _pinnedY.value = pinnedY;
  }

  @override
  Widget build(BuildContext context) {
    // 首帧/数据/布局变化后，post-frame 重算钉底位置。
    _scheduleUpdate();
    return Stack(
      key: _areaKey,
      children: [
        // 自然横滚条：内容底边之下垫 [gap]，滑块落在末行下方紧贴处（约 1px 空隙）；
        // 内容超高时这条随内容沉底（视口外），由钉底条接管。
        Scrollbar(
          controller: _h,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: EdgeInsets.only(bottom: widget.gap),
              child: KeyedSubtree(key: _contentKey, child: widget.child),
            ),
          ),
        ),
        // 钉底横滚条覆盖层：[_pinnedY] 非空（区域底在视口外且区域可见）时钉视口底；
        // 为空时 Offstage 但保持挂载——横滚 offset 不丢，重新钉上时立即对齐。
        ValueListenableBuilder<double?>(
          valueListenable: _pinnedY,
          builder: (context, y, _) => Positioned(
            left: 0,
            right: 0,
            top: (y ?? 0) - _barHeight,
            child: Offstage(
              offstage: y == null,
              child: SizedBox(
                height: _barHeight,
                child: Scrollbar(
                  controller: _pinnedH,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _pinnedH,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: ValueListenableBuilder<double>(
                      valueListenable: _contentWidth,
                      builder: (context, w, _) => SizedBox(width: w, height: 1),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
