// One cancellable long-poll per visible session. A committed replacement wakes
// the old device immediately; legacy servers retain a short automatic probe.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/connection_recovery.dart';
import '../../core/network/server_config.dart';
import '../../core/network/user_activity.dart';
import '../../core/security/secure_storage.dart';
import 'session_provider.dart';

class SessionKeepaliveHost extends ConsumerStatefulWidget {
  const SessionKeepaliveHost({super.key});

  @override
  ConsumerState<SessionKeepaliveHost> createState() =>
      _SessionKeepaliveHostState();
}

class _SessionKeepaliveHostState extends ConsumerState<SessionKeepaliveHost>
    with WidgetsBindingObserver {
  Timer? _retry;
  Timer? _activityTimer;
  bool _probingActivity = false;
  CancelToken? _cancellation;
  int _run = 0;
  DateTime? _legacyUntil;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(sessionProvider, (previous, next) {
      if (previous == null || !next.isSameIdentity(previous)) _restart();
    });
    ref.listenManual(apiBaseUrlProvider, (_, next) {
      _legacyUntil = null;
      _restart();
    });
    ref.listenManual(
      connectionRecoveryProvider.select((value) => value.recoveryEpoch),
      (previous, next) {
        if (next > (previous ?? 0)) _restart();
      },
    );
    _restart();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Minimize/background never logs out. Resume reconnects immediately instead
    // of waiting for a suspended socket or retry timer to expire.
    if (state == AppLifecycleState.resumed) _restart();
  }

  @override
  void dispose() {
    ++_run;
    _retry?.cancel();
    _activityTimer?.cancel();
    _cancellation?.cancel('Session observer disposed');
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _restart() {
    final run = ++_run;
    _retry?.cancel();
    _activityTimer?.cancel();
    _cancellation?.cancel('Session observer restarted');
    if (ref.read(sessionProvider).status != AuthStatus.unauthenticated) {
      // Keep the existing human-activity lease: typing locally still counts as
      // use, while passive session observation must never keep an idle user in.
      _activityTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!UserActivity.userIsIdle) unawaited(_recordActivity(run));
      });
      unawaited(_watch(run));
    }
  }

  Future<void> _recordActivity(int run) async {
    if (_probingActivity || !mounted || run != _run) return;
    _probingActivity = true;
    try {
      final client = ref.read(apiClientProvider);
      final scope = await client.captureRequestScope(
        isCurrent: () =>
            mounted &&
            run == _run &&
            ref.read(sessionProvider).status != AuthStatus.unauthenticated,
      );
      await scope.run(() => client.get('/auth/me'));
    } catch (_) {
      // Definitive rejection follows the ordinary auth interceptor; unavailable
      // networking is never a reason to discard the current form/session.
    } finally {
      _probingActivity = false;
    }
  }

  Future<void> _watch(int run) async {
    if (!mounted || run != _run) return;
    final owner = ref.read(sessionProvider.notifier);
    final epoch = owner.requestIntentEpoch;
    bool current() =>
        mounted &&
        run == _run &&
        identical(owner, ref.read(sessionProvider.notifier)) &&
        owner.requestIntentEpoch == epoch &&
        ref.read(sessionProvider).status != AuthStatus.unauthenticated;
    final cancellation = CancelToken();
    _cancellation = cancellation;
    var retryAfter = const Duration(milliseconds: 250);
    try {
      final client = ref.read(apiClientProvider);
      final scope = await client.captureRequestScope(isCurrent: current);
      final observed = await ref
          .read(secureStorageProvider)
          .getAuthTokenSnapshot();
      if (!current() || !observed.hasTokens) return;
      final legacy = _legacyUntil?.isAfter(DateTime.now()) == true;
      final reply = await scope.run(
        () => client.watchSession(
          cancelToken: cancellation,
          fallbackProbe: legacy,
        ),
      );
      if (!current()) return;
      if (legacy) {
        retryAfter = const Duration(seconds: 3);
      } else {
        final status = reply['status'];
        if (status != 'active' && status != 'replaced' && status != 'expired') {
          throw const FormatException('Invalid session watch response');
        }
        if (status != 'active') {
          final code = reply['code'];
          if (status == 'replaced' && code != 'SESSION_REPLACED' ||
              status == 'expired' && code != 'UNAUTHORIZED') {
            throw const FormatException('Inconsistent session watch response');
          }
          final message = reply['message'];
          await owner.acceptSessionWatchResult(
            observed: observed,
            observedIntentEpoch: epoch,
            status: status as String,
            message: message is String ? message : null,
          );
        }
      }
    } on ApiException catch (error) {
      if (error.httpStatus == 404 || error.httpStatus == 405) {
        _legacyUntil = DateTime.now().add(const Duration(minutes: 1));
        retryAfter = Duration.zero;
      } else {
        retryAfter = const Duration(seconds: 3);
      }
    } catch (_) {
      // Network failures cannot revoke a session. Reconnect without replaying
      // business writes or presenting a false replacement notice.
      retryAfter = const Duration(seconds: 3);
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (current()) {
        _retry = Timer(retryAfter, () => unawaited(_watch(run)));
      } else if (mounted &&
          run == _run &&
          ref.read(sessionProvider).status != AuthStatus.unauthenticated) {
        // An intent can advance without changing the visible user (for example
        // entering impersonation mode or a failed password change).
        _retry = Timer(Duration.zero, _restart);
      }
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
