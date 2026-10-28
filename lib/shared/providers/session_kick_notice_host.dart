// 被顶号下线提示（不渲染，app 根常驻）。
//
// SessionEventBus 发出「账号在其他设备登录」的结束通知时，sessionProvider 已把状态
// 置为未登录、路由跳回登录页；本宿主在同一事件的下一帧弹出居中说明弹窗，把服务端
// 给出的完整原因（在哪台设备登录）讲清楚，用户不再只看到含混的「登录已失效」。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/feedback/uten_motion.dart';
import '../../core/network/session_event_bus.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/uten_anim.dart';

class SessionKickNoticeHost extends StatefulWidget {
  const SessionKickNoticeHost({super.key});

  @override
  State<SessionKickNoticeHost> createState() => _SessionKickNoticeHostState();
}

class _SessionKickNoticeHostState extends State<SessionKickNoticeHost> {
  StreamSubscription<SessionExpiryNotice?>? _subscription;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _subscription = SessionEventBus.instance.onSessionExpired.listen(
      _onExpired,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onExpired(SessionExpiryNotice? notice) {
    if (notice == null || !notice.replacedByOtherDevice || _showing) return;
    _showing = true;
    // 下一帧再弹：让登出置位与跳转先落地，弹窗浮在已就位的登录页上。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _showing = false;
        return;
      }
      _show(notice);
    });
  }

  Future<void> _show(SessionExpiryNotice notice) async {
    final dialogContext = appNavigatorKey.currentContext ?? context;
    final scheme = Theme.of(dialogContext).colorScheme;
    await showDialog<void>(
      context: dialogContext,
      // 与全站确认框同一入场节奏。
      animationStyle: AnimationStyle(
        duration: utenMotionDurationOf(dialogContext, UtenAnim.fast),
        reverseDuration: utenMotionDurationOf(dialogContext, UtenAnim.fast),
        curve: UtenAnim.standard,
        reverseCurve: UtenAnim.exit,
      ),
      builder: (dialogContext) => SelectionArea(
        child: UtenAlertDialog(
          maxWidth: 400,
          title: const UtenDialogHeading(
            title: Text('当前设备已下线'),
            // 主色而非错误红：这是单设备登录保护在生效，不是故障告警。
            icon: Icons.phonelink_erase_rounded,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(notice.message ?? '账号已在其他设备登录，本设备已自动下线'),
              const SizedBox(height: 12),
              Text(
                '同一账号同时只能在一处在线；在新设备登录后，先前登录的设备会自动退出。',
                style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            UtenButton(
              size: UtenButtonSize.large,
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      ),
    );
    _showing = false;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
