// UtenSlidingTabView - 主 Tab 滑动转场容器（替代 PageView，消除跳页闪烁）
// 文档：docs/03-页面/App外壳.md
//
// 为什么不用 PageView：PageView 的 animateToPage 在非相邻页之间会「滚过」中间页
// （工作台→我的 会闪过通知；工作台→设置 会闪过中间两页），无法做到「只滑当前页与新页」。
// 本容器改用 Stack 常驻所有页 + 离散方向滑动转场：
//   - 点击 / 路由变更 index → 新页从一侧滑入、当前页向对侧滑出，绝不经过别的页
//   - 方向：去更靠右的 Tab = 新页从右进、当前页左移（forward，即用户描述的效果）；
//     反向同理镜像（去更左的 Tab = 新页从左进），与旧 PageView 手势方向一致
//   - 首次访问才初始化；已访问页常驻树，非参与页用Offstage隐藏并保留状态，
//     切回 Tab 时各页状态不丢（不回顶）
//   - 可选横滑手势：手指左右滑切到相邻 Tab（与主 Tab 内纵向滚动不冲突；
//     主 Tab 页无横向滚动控件，故无抢手势风险）
//   - 连续 position（喂胶囊滑块）随转场 lerp，转场时滑块跟手滑动

import 'package:flutter/material.dart';

import '../../../core/theme/uten_anim.dart';

/// 主 Tab 滑动转场容器。
///
/// [index] 来自路由的目标页码；变化时触发一次离散滑动转场。null 表示保持当前页
/// 不动（如外壳进入业务子页面时把本容器 Offstage 隐藏，传入 null 即不动画）。
///
/// [position] 是连续页位置（0..n-1），随转场在 _from.._to 之间 lerp；
/// 外壳把它喂给胶囊导航，使滑块随转场滑动。
class UtenSlidingTabView extends StatefulWidget {
  const UtenSlidingTabView({
    super.key,
    required this.index,
    required this.position,
    required this.children,
    this.onChanged,
    this.swipeEnabled = true,
    this.animated = true,
  });

  /// 目标页码（来自路由）。null = 保持当前页不动。
  final int? index;

  /// 连续页位置（0..n-1），随转场 lerp；外壳用来驱动胶囊滑块。
  final ValueNotifier<double> position;

  /// Tabs mount on first visit, then keep their state across navigation.
  final List<Widget> children;

  /// 横滑切到相邻 Tab 时回调（外壳用它同步路由）。
  final ValueChanged<int>? onChanged;

  /// 是否开启横滑切页手势（compact 触屏开；rail 桌面关——桌面用点击切 Tab）。
  final bool swipeEnabled;

  /// 是否在切换 Tab 时播放左右滑动转场。
  /// compact 触屏开（符合手机 PageView 直觉）；rail 桌面关——改即时切换，
  /// 避免大屏整页横移幅度过大、突兀（给人「盖住导航」的错觉）。
  /// 关闭时 index 变化直接落位新页、无动画。
  final bool animated;

  @override
  State<UtenSlidingTabView> createState() => _UtenSlidingTabViewState();
}

class _UtenSlidingTabViewState extends State<UtenSlidingTabView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final CurvedAnimation _curve;

  /// 当前展示页（转场结束时 _from 会追平到 _to）
  int _to = 0;

  /// 转场中的来源页（转场期间与 _to 同时可见；结束 post-frame 追平 _to）
  int _from = 0;
  final Set<int> _visited = {};

  /// 转场方向：+1 = 去更右的 Tab（forward，新页从右进），-1 = 去更左的 Tab
  int _dir = 1;

  /// 横滑累计位移（onHorizontalDragUpdate 累加 primaryDelta），慢速大位移也切页
  double _dragExtent = 0;

  @override
  void initState() {
    super.initState();
    final n = widget.children.length;
    _to = (widget.index ?? 0).clamp(0, n > 0 ? n - 1 : 0);
    _from = _to;
    _ctrl = AnimationController(
      vsync: this,
      duration: UtenAnim.normal,
      value: 1, // 初始处于静止（已落到 _to）
    );
    _curve = CurvedAnimation(parent: _ctrl, curve: UtenAnim.standard);
    _ctrl.addListener(_onCtrlTick);
    _syncPosition();
  }

  /// 控制器每帧回调：更新连续 position；转场结束 post-frame 退场来源页。
  /// （_animateTo 仅在 post-frame 或手势回调里调用，故本回调不会在 build 期触发）
  void _onCtrlTick() {
    _syncPosition();
    if (_ctrl.value >= 1.0 && _from != _to) {
      // 转场结束：post-frame 把 _from 追平 _to，让来源页退场（仅留 _to）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _from != _to) setState(() => _from = _to);
      });
    }
  }

  double _lerpPos() => _from + (_to - _from) * _ctrl.value;

  void _syncPosition() {
    final n = widget.children.length;
    widget.position.value = _lerpPos().clamp(
      0.0,
      n > 1 ? (n - 1).toDouble() : 0.0,
    );
  }

  /// 启动一次到 [to] 的转场（仅动画，不通知路由）。
  void _animateTo(int to) {
    final n = widget.children.length;
    if (to < 0 || to >= n || to == _to) return;
    // Gestures can lead the router update (or have no route callback). Mount
    // the target before its first animation frame, not only on widget.index.
    _visited.add(to);
    // 若上次转场未完，先停掉并把上次的目标 _to 落位为新的出发点，
    // 再开新转场，避免两条转场叠加造成视觉错乱（快速连点场景）。
    _ctrl.stop();
    _from = _to;
    _dir = to > _to ? 1 : -1;
    _to = to;
    _ctrl.value = 0;
    _ctrl.forward();
  }

  /// 即时切到 [to]（不播转场）：直接落位 _to==_from，新页显示、其余 Offstage 隐藏。
  /// 供大屏 rail（animated=false）用，避免整页左右横移。
  void _setTo(int to) {
    final n = widget.children.length;
    if (to < 0 || to >= n || to == _to) return;
    setState(() {
      _visited.add(to);
      _to = to;
      _from = to;
    });
    _ctrl.value = 1; // 保持静止（_from==_to 时 _offsetFor 对其返回 Offset.zero）
    _syncPosition();
  }

  /// 横滑驱动的切页：转场 + 通知外壳同步路由。
  void _goTo(int to) {
    if (to < 0 || to >= widget.children.length || to == _to) return;
    _animateTo(to);
    widget.onChanged?.call(to);
  }

  @override
  void dispose() {
    _curve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // ===== 横滑手势（仅 swipeEnabled 时挂载） =====

  void _onHorizontalDragStart(DragStartDetails _) {
    _dragExtent = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    _dragExtent += d.primaryDelta ?? 0;
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final width = context.size?.width ?? 1;
    int? target;
    // 手指向左（负速度 / 负位移）→ 下一页（更右 Tab）；向右 → 上一页（更左 Tab）
    if (v <= -350 || _dragExtent <= -width / 3) {
      target = _to + 1;
    } else if (v >= 350 || _dragExtent >= width / 3) {
      target = _to - 1;
    }
    _dragExtent = 0;
    if (target != null) _goTo(target);
  }

  /// 计算第 i 页的 fractional 偏移：
  ///   入场页（_to）：从 _dir 侧 → 0；出场页（_from）：0 → -_dir 侧；静止页：0。
  Offset _offsetFor(int i) {
    if (i == _to && i != _from) {
      return Offset(_dir * (1 - _curve.value), 0);
    }
    if (i == _from && i != _to) {
      return Offset(-_dir * _curve.value, 0);
    }
    return Offset.zero;
  }

  Widget _pageAt(int index, {required bool ancestorTickersEnabled}) {
    // A cold business deep link must not initialize the dashboard, notices,
    // profile and settings behind it. Keep a stable slot so a visited tab is
    // never remounted when another tab is first opened.
    if (!_visited.contains(index)) {
      return Positioned.fill(key: ValueKey(index), child: const SizedBox());
    }
    final participatesInTransition = index == _to || index == _from;
    final isActiveMainTab = widget.index != null && participatesInTransition;
    return Positioned.fill(
      key: ValueKey(index),
      child: ExcludeFocus(
        // Offstage 保留 State 时也可能保留焦点；隐藏页不得继续接收键盘事件。
        excluding: !isActiveMainTab,
        child: TickerMode(
          // 内层 TickerMode 会成为最近祖先，必须显式合并外层 Shell 的状态。
          // 静止时只允许当前页推进；转场时允许来源页与目标页共同推进。
          enabled: ancestorTickersEnabled && isActiveMainTab,
          child: Offstage(
            offstage: !participatesInTransition,
            child: FractionalTranslation(
              translation: _offsetFor(index),
              child: widget.children[index],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ancestorTickersEnabled = TickerMode.valuesOf(context).enabled;
    // 路由驱动：目标页码变化时，post-frame 启动转场（与旧 animateToPage 同模式，
    // 避免在 build 期操纵 AnimationController）。
    final idx = widget.index;
    if (idx != null && idx >= 0 && idx < widget.children.length) {
      _visited.add(idx);
    }
    if (idx != null && idx != _to) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || idx != widget.index || idx == _to) return;
        // animated=false（大屏 rail）：即时落位，不播横滑转场
        if (widget.animated) {
          _animateTo(idx);
        } else {
          _setTo(idx);
        }
      });
    }

    final stack = AnimatedBuilder(
      animation: _curve,
      builder: (context, _) {
        return Stack(
          children: [
            for (var i = 0; i < widget.children.length; i++)
              _pageAt(i, ancestorTickersEnabled: ancestorTickersEnabled),
          ],
        );
      },
    );

    if (!widget.swipeEnabled) return stack;

    // translucent：不拦截子树点击/纵向滚动，仅参与横向手势竞技；
    // 主 Tab 页无横向滚动控件，故横向手势不会与之抢。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onHorizontalDragStart,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: stack,
    );
  }
}
