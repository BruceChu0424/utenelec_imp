// Named public parameters intentionally initialize private implementation fields.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_config.dart';
import 'health_probe.dart';
import 'network_policy.dart';

enum ConnectionRecoveryPhase { connected, reconnecting, disconnected, restored }

class ConnectionRecoveryState {
  const ConnectionRecoveryState({
    this.phase = ConnectionRecoveryPhase.connected,
    this.retryAttempt = 0,
    this.recoveryEpoch = 0,
  });

  final ConnectionRecoveryPhase phase;
  final int retryAttempt;

  /// Increments only after a fully disconnected client reaches the server
  /// again. Network-backed Riverpod providers use this to reload themselves.
  final int recoveryEpoch;

  ConnectionRecoveryState copyWith({
    ConnectionRecoveryPhase? phase,
    int? retryAttempt,
    int? recoveryEpoch,
  }) => ConnectionRecoveryState(
    phase: phase ?? this.phase,
    retryAttempt: retryAttempt ?? this.retryAttempt,
    recoveryEpoch: recoveryEpoch ?? this.recoveryEpoch,
  );
}

typedef ConnectionProbe = Future<bool> Function();
typedef ProbeDelayJitter = Duration Function(Duration baseDelay);

final Random _probeJitterRandom = Random();

/// Spreads synchronized clients across the existing delay without extending
/// its upper bound. The production schedule therefore still tops out at about
/// fifteen seconds, while office/NAT clients do not probe in lockstep.
Duration randomizedProbeDelay(Duration baseDelay) {
  if (baseDelay <= Duration.zero) return Duration.zero;
  const minimumFactor = 0.85;
  final factor =
      minimumFactor + (_probeJitterRandom.nextDouble() * (1 - minimumFactor));
  final microseconds = max(1, (baseDelay.inMicroseconds * factor).round());
  return Duration(microseconds: microseconds);
}

/// Owns the app-wide reconnect loop. It probes reachability only and never
/// replays a business write.
class ConnectionRecoveryController
    extends StateNotifier<ConnectionRecoveryState> {
  ConnectionRecoveryController({
    required ConnectionProbe probe,
    List<Duration> probeDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 15),
    ],
    ProbeDelayJitter? probeDelayJitter,
    Duration restoredDisplayDuration = const Duration(seconds: 3),
  }) : _probe = probe,
       _probeDelays = List<Duration>.unmodifiable(probeDelays),
       _probeDelayJitter = probeDelayJitter ?? randomizedProbeDelay,
       _restoredDisplayDuration = restoredDisplayDuration,
       super(const ConnectionRecoveryState());

  final ConnectionProbe _probe;
  final List<Duration> _probeDelays;
  final ProbeDelayJitter _probeDelayJitter;
  final Duration _restoredDisplayDuration;

  Timer? _probeTimer;
  Timer? _restoredTimer;
  var _probeIndex = 0;
  var _probeInFlight = false;
  var _needsRecoveryEpoch = false;

  void markRetrying(int attempt) {
    if (!mounted || state.phase == ConnectionRecoveryPhase.disconnected) {
      return;
    }
    state = state.copyWith(
      phase: ConnectionRecoveryPhase.reconnecting,
      retryAttempt: attempt,
    );
  }

  void markDisconnected() {
    if (!mounted) return;
    _restoredTimer?.cancel();
    _needsRecoveryEpoch = true;
    state = state.copyWith(
      phase: ConnectionRecoveryPhase.disconnected,
      retryAttempt: 0,
    );
    _scheduleProbe();
  }

  void markConnected() {
    if (!mounted) return;
    _probeTimer?.cancel();
    _probeIndex = 0;

    if (_needsRecoveryEpoch) {
      _needsRecoveryEpoch = false;
      state = state.copyWith(
        phase: ConnectionRecoveryPhase.restored,
        retryAttempt: 0,
        recoveryEpoch: state.recoveryEpoch + 1,
      );
      _restoredTimer?.cancel();
      _restoredTimer = Timer(_restoredDisplayDuration, () {
        if (!mounted || state.phase != ConnectionRecoveryPhase.restored) {
          return;
        }
        state = state.copyWith(phase: ConnectionRecoveryPhase.connected);
      });
      return;
    }

    if (state.phase != ConnectionRecoveryPhase.restored) {
      state = state.copyWith(
        phase: ConnectionRecoveryPhase.connected,
        retryAttempt: 0,
      );
    }
  }

  /// Runs an immediate reachability check. Repeated taps are coalesced and the
  /// manual path deliberately bypasses both the base delay and its jitter.
  Future<void> retryNow() async {
    if (!mounted) return;
    _probeTimer?.cancel();
    state = state.copyWith(
      phase: ConnectionRecoveryPhase.reconnecting,
      retryAttempt: 0,
    );
    await _runProbe();
  }

  void _scheduleProbe() {
    if (!mounted || _probeTimer?.isActive == true || _probeInFlight) return;
    final index = _probeDelays.isEmpty
        ? 0
        : _probeIndex < _probeDelays.length
        ? _probeIndex
        : _probeDelays.length - 1;
    final baseDelay = _probeDelays.isEmpty
        ? const Duration(seconds: 5)
        : _probeDelays[index];
    final jitteredDelay = _probeDelayJitter(baseDelay);
    final delay = jitteredDelay.isNegative ? Duration.zero : jitteredDelay;
    _probeTimer = Timer(delay, _runProbe);
  }

  Future<void> _runProbe() async {
    if (!mounted || _probeInFlight) return;
    _probeInFlight = true;
    try {
      if (await _probe()) {
        markConnected();
        return;
      }
    } catch (_) {
      // The business request keeps its original error and recovery path.
    } finally {
      _probeInFlight = false;
    }

    if (!mounted || !_needsRecoveryEpoch) return;
    state = state.copyWith(
      phase: ConnectionRecoveryPhase.disconnected,
      retryAttempt: 0,
    );
    if (_probeDelays.isNotEmpty && _probeIndex < _probeDelays.length - 1) {
      _probeIndex++;
    }
    _scheduleProbe();
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    _restoredTimer?.cancel();
    super.dispose();
  }
}

final connectionRecoveryProvider =
    StateNotifierProvider<
      ConnectionRecoveryController,
      ConnectionRecoveryState
    >((ref) {
      final healthDio = Dio(
        buildApiBaseOptions(healthProbeBaseUrl(ref.watch(apiBaseUrlProvider)))
            .copyWith(
              connectTimeout: const Duration(seconds: 5),
              sendTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
            ),
      );
      ref.onDispose(healthDio.close);

      return ConnectionRecoveryController(
        probe: () async {
          try {
            final response = await healthDio.get<dynamic>('/actuator/health');
            return isHealthyProbeResponse(response.statusCode, response.data);
          } on DioException {
            return false;
          }
        },
      );
    });
