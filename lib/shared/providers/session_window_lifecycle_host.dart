import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/feedback/uten_busy_overlay.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/platform/desktop_window.dart';
import '../../core/router/app_router.dart';
import '../../core/web_update/web_update_safety.dart';
import '../../features/auth/services/pending_refresh_revocation_drainer.dart';
import '../drafts/form_draft_navigation.dart';
import 'session_provider.dart';

/// The final desktop window closes only after existing leave guards and draft
/// checkpoints finish. Focus loss, minimization and mobile backgrounding never
/// end a login. The engine sends native close/Alt+F4 through this same callback.
class SessionWindowLifecycleHost extends ConsumerStatefulWidget {
  const SessionWindowLifecycleHost({
    super.key,
    required this.router,
    required this.child,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<SessionWindowLifecycleHost> createState() =>
      _SessionWindowLifecycleHostState();
}

class _SessionWindowLifecycleHostState
    extends ConsumerState<SessionWindowLifecycleHost> {
  AppLifecycleListener? _listener;
  Future<AppExitResponse>? _closing;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (supportsDesktopWindow) {
      _listener = AppLifecycleListener(onExitRequested: _requestExit);
    }
  }

  Future<AppExitResponse> _requestExit() {
    final active = _closing;
    if (active != null) return active;
    late final Future<AppExitResponse> pending;
    pending = _close().whenComplete(() {
      if (identical(_closing, pending)) _closing = null;
    });
    _closing = pending;
    return pending;
  }

  Future<AppExitResponse> _close() async {
    try {
      if (!await FormDraftNavigation.confirmRouterExit(widget.router)) {
        return AppExitResponse.cancel;
      }
      if (!mounted) return AppExitResponse.cancel;
      setState(() => _busy = true);
      if (!await webUpdateSafety.prepareServerReload().timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      )) {
        if (mounted) setState(() => _busy = false);
        await _notice('请先完成当前操作再关闭窗口');
        return AppExitResponse.cancel;
      }
      if (!mounted) return AppExitResponse.cancel;
      await ref.read(sessionProvider.notifier).logout();
      // Logout has already persisted its encrypted revocation queue. Give the
      // public idempotent endpoint a bounded chance to finish before shutdown;
      // an offline close retains the queue for the next startup/recovery.
      await ref
          .read(pendingRefreshRevocationDrainerProvider)
          .drain()
          .timeout(const Duration(seconds: 3), onTimeout: () {});
      return AppExitResponse.exit;
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      await _notice('退出未完成，请重试');
      return AppExitResponse.cancel;
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<void> _notice(String title) async {
    if (!mounted) return;
    final target = appNavigatorKey.currentContext;
    if (target == null) return;
    await showDialog<void>(
      context: target,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(title),
        showCloseButton: true,
        onClose: () => Navigator.pop(dialogContext),
      ),
    );
  }

  @override
  void dispose() {
    _listener?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _listener == null
      ? widget.child
      : Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_busy)
              const UtenBusyOverlay(title: '正在关闭窗口', showDoNotLeaveHint: false),
          ],
        );
}
