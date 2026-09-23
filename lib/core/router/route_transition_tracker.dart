// 路由转场进行中的全局登记 —— 「返回即刷新」等后台重拉推迟到转场结束之后(ADR-108)。
//
// 背景: 返回键一按, go_router 立刻通知落点变化, 此时返回动画才刚起步; 列表页若在这时
// 重拉并整页重建, 就和转场抢同一批帧(Web 上尤甚)。全局转场由 [TrackedPageTransitionsBuilder]
// 包一层, 任一路由的 animation / secondaryAnimation 在走时计数 +1, 走完 -1;
// [whenRouteTransitionsSettled] 等计数归零再下一帧执行; 最多等 [routeTransitionSettleTimeout],
// 某个转场卡住(如 ticker 被 TickerMode 静音)也不会让全站的返回刷新无限推迟。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 正在走转场动画的路由数(0 = 静止)。
class RouteTransitionTracker extends ChangeNotifier {
  RouteTransitionTracker._();

  static final RouteTransitionTracker instance = RouteTransitionTracker._();

  final Set<Object> _animating = <Object>{};

  bool get isIdle => _animating.isEmpty;

  void _set(Object token, bool animating) {
    final changed = animating
        ? _animating.add(token)
        : _animating.remove(token);
    if (changed) notifyListeners();
  }

  /// 测试用: 清空登记(测试间隔离)。
  @visibleForTesting
  void reset() {
    if (_animating.isEmpty) return;
    _animating.clear();
    notifyListeners();
  }
}

/// 转场最多等这么久(正常转场约 150-300ms); 超时照样执行, 只是可能和残余动画挤一帧。
const routeTransitionSettleTimeout = Duration(seconds: 1);

/// 等当前(及紧接着开始的)路由转场全部走完, 再在下一帧执行 [action]。
///
/// 先等一帧: 落点通知在导航器重建之前发出, 那一刻转场还没登记。
/// 最多等 [routeTransitionSettleTimeout]。
void whenRouteTransitionsSettled(VoidCallback action) {
  final tracker = RouteTransitionTracker.instance;
  // 动作(通常是发起重拉)跑完再要一帧: 请求回来前界面照常可交互, 回来后的 setState
  // 有帧可落; 测试里 pumpAndSettle 也会因此继续推进时间, 让网络层的零延时任务跑完。
  void runAction() {
    action();
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void runAfterFrame() {
    SchedulerBinding.instance.addPostFrameCallback((_) => runAction());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (tracker.isIdle) {
      runAction();
      return;
    }
    var settled = false;
    Timer? fallback;
    late final VoidCallback listener;
    void settle({required bool timedOut}) {
      if (settled) return;
      settled = true;
      fallback?.cancel();
      tracker.removeListener(listener);
      timedOut ? runAction() : runAfterFrame();
    }

    listener = () {
      if (tracker.isIdle) settle(timedOut: false);
    };
    tracker.addListener(listener);
    fallback = Timer(
      routeTransitionSettleTimeout,
      () => settle(timedOut: true),
    );
  });
  SchedulerBinding.instance.ensureVisualUpdate();
}

/// 给任意 [PageTransitionsBuilder] 加上转场登记(外观、时长、联动动画都不变)。
class TrackedPageTransitionsBuilder extends PageTransitionsBuilder {
  const TrackedPageTransitionsBuilder(this.inner);

  final PageTransitionsBuilder inner;

  @override
  Duration get transitionDuration => inner.transitionDuration;

  @override
  Duration get reverseTransitionDuration => inner.reverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      inner.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _TransitionActivity(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: inner.buildTransitions<T>(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      ),
    );
  }
}

class _TransitionActivity extends StatefulWidget {
  const _TransitionActivity({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_TransitionActivity> createState() => _TransitionActivityState();
}

class _TransitionActivityState extends State<_TransitionActivity> {
  @override
  void initState() {
    super.initState();
    _attach(widget);
    _report();
  }

  @override
  void didUpdateWidget(covariant _TransitionActivity oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      _detach(oldWidget);
      _attach(widget);
      _report();
    }
  }

  @override
  void dispose() {
    _detach(widget);
    RouteTransitionTracker.instance._set(this, false);
    super.dispose();
  }

  void _attach(_TransitionActivity target) {
    target.animation.addStatusListener(_onStatus);
    target.secondaryAnimation.addStatusListener(_onStatus);
  }

  void _detach(_TransitionActivity target) {
    target.animation.removeStatusListener(_onStatus);
    target.secondaryAnimation.removeStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus _) => _report();

  void _report() {
    bool moving(Animation<double> animation) =>
        animation.status == AnimationStatus.forward ||
        animation.status == AnimationStatus.reverse;
    RouteTransitionTracker.instance._set(
      this,
      moving(widget.animation) || moving(widget.secondaryAnimation),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
