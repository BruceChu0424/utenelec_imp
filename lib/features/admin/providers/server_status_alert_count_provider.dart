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
// 常驻不 autoDispose + 60s 自失效：与全站徽章口径一致（见
// docs/00-项目准则/14-徽章与计数口径.md §四之三），否则离开页面再回来会先闪一下 0。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../models/server_status.dart';
import '../repositories/server_status_repository.dart';

const Duration _pollInterval = Duration(seconds: 60);

final serverStatusAlertCountProvider = FutureProvider<int>((ref) async {
  final permissions = ref.watch(currentPermissionsProvider);
  if (!ref.watch(isSuperAdminProvider) &&
      !permissions.contains(Perm.serverStatusView)) {
    return 0;
  }
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final snapshot = await ref.watch(serverStatusRepositoryProvider).load();
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
