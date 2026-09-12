// 服务器状态告警数（工作台「服务器状态」卡的红徽章）。
//
// 2026-09-11 用户反馈：磁盘越过 80%/90% 的告警此前**只存在于状态页内部**——
// 不主动点开那个页面就永远不知道。后端已补站内通知推送
// （ServerStatusAlertScheduler，接收人由 server_status:alert:receive 控制）；
// 这里补工作台那一眼：卡上直接显示当前有几条告警。
//
// 口径：alerts 里状态非 NORMAL 的条数（后端已把磁盘/内存/数据库/备份/定时任务
// 的越线统一折算成 alerts）。徽章是「要人去处理」的红徽章，计入工作台累计。
//
// 权限自卫：没有 server_status:view 的账号直接 0 且不发请求——那张卡本来也不给他看。
// 常驻不 autoDispose + 定时自失效：与全站徽章口径一致（见
// docs/00-项目准则/14-徽章与计数口径.md §四之三），否则离开页面再回来会先闪一下 0。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../models/server_status.dart';
import '../repositories/server_status_repository.dart';
import 'server_status_snapshot_cache.dart';

/// 轮询间隔。
///
/// 除了徽章本身的新鲜度，它还决定共享缓存对状态页**有没有用**：快照的过期窗口是
/// `sampledAt + pollSeconds×2`（后端 pollSeconds 10–15s，最窄 30s），而进页面那一刻
/// 缓存的实际年龄 = 后端采样年龄（0–15s，后端每 15s 采一次）＋ 本地缓存年龄
/// （0 到本间隔）。所以**做不到"保证不过期"**，只能把期望值压进窗口内：
/// 18s 下平均约 9+7.5≈17s（窗口 30s，通常可用），原来的 60s 下平均约 38s（基本都过期，
/// 缓存等于白放）。
///
/// 端点本身只是读后端内存里的一份采样快照（AtomicReference，不探磁盘不查库），
/// 且只有持 server_status:view 的少数账号会订阅，这个频率的代价可以接受。
const Duration _pollInterval = Duration(seconds: 18);

final serverStatusAlertCountProvider = FutureProvider<int>((ref) async {
  final permissions = ref.watch(currentPermissionsProvider);
  if (!ref.watch(isSuperAdminProvider) &&
      !permissions.contains(Perm.serverStatusView)) {
    return 0;
  }
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final snapshot = await ref.watch(serverStatusRepositoryProvider).load();
  // 顺手喂共享缓存：状态页进页面第一帧就能拿这份读数把总览画出来。
  ref.read(serverStatusSnapshotCacheProvider.notifier).state = snapshot;
  // 只数 warning / critical。unknown 表示「探测不到」——它已经在页面上以
  // UNKNOWN 卡片示人，但拿不到数的指标不该被当成「有 N 件事要办」催人。
  return snapshot.alerts
      .where(
        (alert) =>
            alert.status == ServerHealthStatus.warning ||
            alert.status == ServerHealthStatus.critical,
      )
      .length;
});
