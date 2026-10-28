// 登录在线心跳（不渲染，app 根常驻）。
//
// 单设备顶号天然是「懒感知」：被顶设备要等下一次人为请求才会撞上 401，人不在场时
// 界面就一直停在原地。本心跳在员工登录期间每 [interval] 轻探一次 /auth/me——请求
// 经 AutomaticRequestInterceptor 打标（用户不在场时为自动请求，不续期服务端会话，
// ADR-110），因此不会把空闲超时变成摆设。被顶/空闲超时/改密吊销都在一个心跳周期内
// 被 401 → 刷新拒绝 → SessionEventBus.expire 的既有链路送回登录页，无需新增协议。
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import 'session_provider.dart';

class SessionKeepaliveHost extends ConsumerStatefulWidget {
  const SessionKeepaliveHost({super.key});

  @override
  ConsumerState<SessionKeepaliveHost> createState() =>
      _SessionKeepaliveHostState();
}

class _SessionKeepaliveHostState extends ConsumerState<SessionKeepaliveHost> {
  static const interval = Duration(seconds: 30);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sessionProvider.select((s) => s.isLoggedIn), (
      previous,
      next,
    ) {
      _sync(next);
    });
    _sync(ref.read(sessionProvider).isLoggedIn);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _sync(bool loggedIn) {
    if (loggedIn) {
      // 登录刚成功不必立即探测，从第一个完整周期开始。
      _timer ??= Timer.periodic(interval, (_) => _probe());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _probe() async {
    if (!mounted) return;
    try {
      // 401 时 AuthInterceptor 会走刷新 → 明确拒绝 → expire 登出链路；探测本身的
      // 结果不需要，网络故障静默放过（连接横幅自有其机制）。
      await ref.read(apiClientProvider).get(ApiEndpoints.authMe);
    } catch (_) {
      // 心跳只负责触发感知，不承担错误呈现。
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
