// 被顶号下线提示（不渲染，app 根常驻）。
//
// 只展示 sessionProvider 已确认结束的本次可见会话。启动读取旧凭据失败不弹窗。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/feedback/uten_dialog.dart';
import '../../components/feedback/uten_motion.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../../components/inputs/uten_field_hint_icon.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/uten_anim.dart';
import 'session_kick_notice_provider.dart';
import 'session_provider.dart';

class SessionKickNoticeHost extends ConsumerStatefulWidget {
  const SessionKickNoticeHost({super.key});

  @override
  ConsumerState<SessionKickNoticeHost> createState() =>
      _SessionKickNoticeHostState();
}

class _SessionKickNoticeHostState extends ConsumerState<SessionKickNoticeHost> {
  bool _showing = false;
  Route<void>? _dialogRoute;
  NavigatorState? _dialogNavigator;
  SessionKickNotice? _visibleNotice;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sessionKickNoticeProvider, (_, next) => _onNotice(next));
    ref.listenManual(sessionProvider, (_, next) {
      final notice = _visibleNotice;
      if (notice != null && !_isCurrent(notice)) {
        final route = _dialogRoute;
        if (route != null && route.isActive) {
          _dialogNavigator?.removeRoute(route);
        }
      }
    });
  }

  @override
  void dispose() {
    final route = _dialogRoute;
    if (route != null && route.isActive) _dialogNavigator?.removeRoute(route);
    super.dispose();
  }

  bool _isCurrent(SessionKickNotice notice) =>
      mounted &&
      ref.read(sessionProvider).status == AuthStatus.unauthenticated &&
      ref.read(sessionProvider.notifier).requestIntentEpoch ==
          notice.intentEpoch;

  void _onNotice(SessionKickNotice? notice) {
    if (notice == null) return;
    ref.read(sessionKickNoticeProvider.notifier).consume(notice);
    if (_showing || !_isCurrent(notice)) return;
    _showing = true;
    _visibleNotice = notice;
    // 下一帧再弹：让登出置位与跳转先落地，弹窗浮在已就位的登录页上。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrent(notice)) {
        _showing = false;
        _visibleNotice = null;
        return;
      }
      _show(notice);
    });
  }

  Future<void> _show(SessionKickNotice notice) async {
    final dialogContext = appNavigatorKey.currentContext ?? context;
    try {
      await UtenBusyOverlay.yieldWhile(
        () => showDialog<void>(
          context: dialogContext,
          // 与全站确认框同一入场节奏。
          animationStyle: AnimationStyle(
            duration: utenMotionDurationOf(dialogContext, UtenAnim.fast),
            reverseDuration: utenMotionDurationOf(dialogContext, UtenAnim.fast),
            curve: UtenAnim.standard,
            reverseCurve: UtenAnim.exit,
          ),
          builder: (dialogContext) {
            _dialogRoute = ModalRoute.of(dialogContext);
            _dialogNavigator = Navigator.of(dialogContext);
            return SelectionArea(
              child: UtenAlertDialog(
                maxWidth: 400,
                showCloseButton: true,
                onClose: () => Navigator.pop(dialogContext),
                title: const UtenDialogHeading(
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text('当前设备已下线')),
                      UtenFieldHintIcon(
                        dense: true,
                        info: '同一账号同时只能在一处在线；在新设备登录后，先前登录的设备会自动退出。',
                      ),
                    ],
                  ),
                  // 主色而非错误红：这是单设备登录保护在生效，不是故障告警。
                  icon: Icons.phonelink_erase_rounded,
                ),
                content: Text(notice.message ?? '账号已在其他设备登录，本设备已自动下线'),
              ),
            );
          },
        ),
      );
    } finally {
      _showing = false;
      _visibleNotice = null;
      _dialogRoute = null;
      _dialogNavigator = null;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
