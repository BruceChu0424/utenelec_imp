// 转场登记的兜底(ADR-108 修复轮): 某个转场卡在 forward/reverse(例如 ticker 被静音)时,
// 「等转场结束再刷新」最多等 1 秒, 不能让全站的返回刷新无限推迟。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/route_transition_tracker.dart';

/// 永远停在「正向播放中」的动画。
class _StuckAnimation extends Animation<double> {
  @override
  double get value => 0.5;

  @override
  AnimationStatus get status => AnimationStatus.forward;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}
}

class _Plain extends PageTransitionsBuilder {
  const _Plain();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

void main() {
  setUp(RouteTransitionTracker.instance.reset);

  testWidgets('转场卡住时最多等 1 秒也照样执行', (tester) async {
    final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    await tester.pumpWidget(
      Builder(
        builder: (context) => const TrackedPageTransitionsBuilder(_Plain())
            .buildTransitions<void>(
              route,
              context,
              _StuckAnimation(),
              kAlwaysDismissedAnimation,
              const SizedBox(),
            ),
      ),
    );
    expect(RouteTransitionTracker.instance.isIdle, isFalse);

    var runs = 0;
    whenRouteTransitionsSettled(() => runs++);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(runs, 0, reason: '转场还在走, 先等');
    await tester.pump(routeTransitionSettleTimeout);
    expect(runs, 1, reason: '超过兜底时长照样执行');
    await tester.pump(const Duration(seconds: 2));
    expect(runs, 1, reason: '只执行一次');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('没有转场时下一帧就执行, 不留定时器', (tester) async {
    await tester.pumpWidget(const SizedBox());
    var runs = 0;
    whenRouteTransitionsSettled(() => runs++);
    await tester.pump();
    expect(runs, 1);
  });
}
