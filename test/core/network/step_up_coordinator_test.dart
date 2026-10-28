import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/step_up_coordinator.dart';

void main() {
  late DateTime now;
  late StepUpCoordinator coordinator;
  late int prompts;
  setUp(() {
    now = DateTime.utc(2026, 10, 28);
    coordinator = StepUpCoordinator(clock: () => now);
    prompts = 0;
    coordinator.register(() async => 'proof-${++prompts}');
    coordinator.bindIdentity(('server-a', 'session-a'));
  });

  test('停止五分钟后第一次输入也不能恢复旧凭证', () async {
    expect(await coordinator.obtain(), 'proof-1');
    now = now.add(const Duration(minutes: 5));
    coordinator.recordActivity();
    expect(coordinator.cachedToken, isNull);
    expect(await coordinator.obtain(), 'proof-2');
  });

  test('连续编辑十分钟由实际输入续期，定时器自身不续期', () async {
    await coordinator.obtain();
    var renewals = 0;
    for (var index = 0; index < 20; index++) {
      now = now.add(const Duration(seconds: 31));
      coordinator.recordActivity();
      await coordinator.keepAliveIfActive((token) async {
        expect(token, 'proof-1');
        renewals++;
      });
    }
    expect(renewals, 20);
    expect(await coordinator.obtain(), 'proof-1');
    expect(prompts, 1);
    now = now.add(const Duration(minutes: 5));
    await coordinator.keepAliveIfActive((_) async => renewals++);
    expect(renewals, 20);
    expect(coordinator.cachedToken, isNull);
  });

  test('活动保活按30秒节流，不发送没有新输入的请求', () async {
    await coordinator.obtain();
    var renewals = 0;
    Future<void> renew(String _) async => renewals++;
    await coordinator.keepAliveIfActive(renew);
    expect(renewals, 0);
    now = now.add(const Duration(seconds: 1));
    coordinator.recordActivity();
    await coordinator.keepAliveIfActive(renew);
    now = now.add(const Duration(seconds: 5));
    coordinator.recordActivity();
    await coordinator.keepAliveIfActive(renew);
    expect(renewals, 1);
    now = now.add(const Duration(seconds: 26));
    coordinator.recordActivity();
    await coordinator.keepAliveIfActive(renew);
    expect(renewals, 2);
    now = now.add(const Duration(seconds: 31));
    await coordinator.keepAliveIfActive(renew);
    expect(renewals, 2);
  });

  test('保活故障不能延长服务端确认的期限', () async {
    await coordinator.obtain();
    now = now.add(const Duration(minutes: 4));
    coordinator.recordActivity();
    await coordinator.keepAliveIfActive(
      (_) async => throw StateError('offline'),
    );
    now = now.add(const Duration(minutes: 1, seconds: 1));
    coordinator.recordActivity();
    expect(coordinator.cachedToken, isNull);
  });

  test('服务器、会话或模拟身份改变会丢弃凭证', () async {
    await coordinator.obtain();
    coordinator.bindIdentity(('server-b', 'session-a'));
    expect(coordinator.cachedToken, isNull);
    await coordinator.obtain();
    coordinator.bindIdentity(('server-b', 'session-b'));
    expect(coordinator.cachedToken, isNull);
    expect(prompts, 2);
  });

  test('身份切换后迟到的密码验证结果不得进入新身份缓存', () async {
    final pending = Completer<String?>();
    coordinator.register(() => pending.future);
    final result = coordinator.obtain();
    coordinator.bindIdentity(('server-a', 'other-session'));
    pending.complete('old-session-proof');
    expect(await result, isNull);
    expect(coordinator.cachedToken, isNull);
  });

  test('旧请求被拒不会清掉刚签发的新凭证', () async {
    await coordinator.obtain();
    coordinator.invalidate('proof-1');
    await coordinator.obtain();
    coordinator.invalidate('proof-1');
    expect(coordinator.cachedToken, 'proof-2');
  });
}
