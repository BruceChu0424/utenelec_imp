// 登录会话纪元：每次「未登录 → 已登录」跃迁 +1（只由 SessionRehydrateGate 推进）。
//
// 重新登录时必须立即校正全局角标，避免延用旧会话缓存：
// 各部门待办/未读通知等全局角标是 ProviderScope 级常驻 StateNotifier，登出不重建、
// 登录后要等 60s 轮询或手动刷新才校正。
//
// 用法：全局角标 provider 在构造里 `ref.watch(sessionEpochProvider);`——纪元变化时
// Riverpod 释放旧实例（含其轮询定时器与迟到响应）并重建：新会话从 0 开始并立即重拉，
// 不需要任何「刷新清单」记住它。登出不推进（避免登出/登录各重建一次）。
import 'package:flutter_riverpod/legacy.dart';

final sessionEpochProvider = StateProvider<int>((ref) => 0);
