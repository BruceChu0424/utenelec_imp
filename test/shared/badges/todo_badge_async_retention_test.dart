// 徽章计数在**刷新期间保留旧值**（todo_badge_registry 的 _async 口径）。
//
// 用户 2026-09-11 原话：「品质任务中心的徽章 会突然消失下又出现 然后又消失 又出现
// 里面的卡片也是 保持稳定」。根因是 _async 曾写成 `loading: () => 0`：
// 每 60 秒自失效轮询一进 loading 就把徽章打回 0，数据回来再弹出来。
//
// AsyncValue 在 refresh/invalidate 期间会带住上一次的值（copyWithPrevious），
// 用 valueOrNull 就能取到。本文件锁死这条：**刷新不清零、报错不清零、
// 从没成功过才按 0**。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/todo_badge_registry.dart';
import 'package:uten_imp/shared/providers/production_fqc_pending_count_provider.dart';

void main() {
  /// 用真实注册表的取值函数跑：拿一个已登记的入口做载体，
  /// 只把它背后的 provider 换成受控源。
  int read(ProviderContainer container) => todoEntryCount(
    TodoEntry.qualityFqcPending,
    <T>(ProviderListenable<T> listenable) => container.read(listenable),
  );

  ProviderContainer containerWith(FutureOr<int> Function(Ref ref) load) {
    final container = ProviderContainer(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionQualityInspectionView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        productionFqcPendingCountProvider.overrideWith(load),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('刷新期间保留上一次的数，不会先掉到 0 再弹回来', () async {
    var round = 0;
    var gate = Completer<int>();
    final container = containerWith((ref) {
      round++;
      if (round == 1) return 7;
      return gate.future;
    });

    await container.read(productionFqcPendingCountProvider.future);
    expect(read(container), 7);

    // 轮询自失效：进入 loading，但旧值必须还在。
    container.invalidate(productionFqcPendingCountProvider);
    expect(read(container), 7, reason: 'loading 期间掉到 0 就是用户看到的「徽章闪一下」');

    gate.complete(9);
    await container.read(productionFqcPendingCountProvider.future);
    expect(read(container), 9);
    gate = Completer<int>(); // 避免未完成的 Completer 悬着
  });

  test('请求出错也保留旧值——一次网络抖动不该清空整列徽章', () async {
    var round = 0;
    final container = containerWith((ref) {
      round++;
      if (round == 1) return 7;
      throw Exception('network down');
    });

    await container.read(productionFqcPendingCountProvider.future);
    expect(read(container), 7);

    container.invalidate(productionFqcPendingCountProvider);
    await expectLater(
      container.read(productionFqcPendingCountProvider.future),
      throwsException,
    );
    expect(read(container), 7);
  });

  test('从没成功过时按 0（不渲染徽章）', () {
    final container = containerWith((ref) => Completer<int>().future);
    expect(read(container), 0);
  });
}
