// 本机空闲计时 (ADR-110)：权威在服务端，本机只负责到点及时回登录页。
//
// 钉住：根导航器上的弹窗里的输入 (守卫的 Listener 收不到，只有全局输入采集能看到)
// 同样推迟本机空闲超时——不能出现「人一直在弹窗里填东西，页面却把他登出」。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/user_activity.dart';
import 'package:uten_imp/shared/providers/idle_timeout_controller.dart';

void main() {
  testWidgets('全局采集到的输入同样推迟本机空闲超时', (tester) async {
    var now = DateTime(2026, 9, 23, 9);
    UserActivity.reset();
    UserActivity.clock = () => now;
    addTearDown(UserActivity.reset);
    // 容器在用例末尾显式释放：空闲检查的周期定时器必须在测试框架核对前撤掉。
    final container = ProviderContainer();
    container.listen(idleTimeoutProvider, (_, _) {});
    container.read(idleTimeoutProvider.notifier).setThreshold(1);

    // 50 秒时在弹窗里输入：守卫收不到，全局采集记下
    now = now.add(const Duration(seconds: 50));
    UserActivity.record();

    // 第 90 秒：距最近输入 40 秒，未到 1 分钟阈值
    now = now.add(const Duration(seconds: 40));
    await tester.pump(const Duration(seconds: 90));
    expect(container.read(idleTimeoutProvider).timedOut, isFalse);

    // 第 120 秒：距最近输入 70 秒，超时
    now = now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(container.read(idleTimeoutProvider).timedOut, isTrue);
    container.dispose();
  });

  testWidgets('没有任何输入：按阈值超时', (tester) async {
    var now = DateTime(2026, 9, 23, 9);
    UserActivity.reset();
    UserActivity.clock = () => now;
    addTearDown(UserActivity.reset);
    // 容器在用例末尾显式释放：空闲检查的周期定时器必须在测试框架核对前撤掉。
    final container = ProviderContainer();
    container.listen(idleTimeoutProvider, (_, _) {});
    container.read(idleTimeoutProvider.notifier).setThreshold(1);

    now = now.add(const Duration(seconds: 61));
    await tester.pump(const Duration(seconds: 90));
    expect(container.read(idleTimeoutProvider).timedOut, isTrue);
    container.dispose();
  });
}
