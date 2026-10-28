import 'dart:async';

import 'package:dio/dio.dart';
import '../network/company_tls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/health_probe.dart';
import '../network/http_response_date.dart';
import '../network/server_config.dart';

enum ServerMaintenancePhase { available, scheduled, updating, recoveryRequired }

/// Public host state. A failed request is never evidence of maintenance.
class ServerMaintenanceSnapshot {
  const ServerMaintenanceSnapshot({
    required this.phase,
    required this.serverTime,
    this.noticeId,
    this.startsAt,
    this.targetVersion,
    this.retryAfterSeconds = 10,
  });

  factory ServerMaintenanceSnapshot.fromJson(
    Map<String, dynamic> json, {
    DateTime? observedServerTime,
  }) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported maintenance status');
    }
    final phase = switch (json['state']) {
      'available' => ServerMaintenancePhase.available,
      'scheduled' => ServerMaintenancePhase.scheduled,
      'updating' => ServerMaintenancePhase.updating,
      'recovery_required' => ServerMaintenancePhase.recoveryRequired,
      _ => throw const FormatException('Unknown maintenance state'),
    };
    DateTime? timestamp(Object? value) {
      if (value == null) return null;
      if (value is! String) {
        throw const FormatException('Invalid maintenance timestamp');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null || !parsed.isUtc) {
        throw const FormatException('Maintenance timestamp requires timezone');
      }
      return parsed;
    }

    final serverTime = timestamp(json['serverTime']);
    final startsAt = timestamp(json['startsAt']);
    final notice = json['noticeId'];
    if (serverTime == null ||
        (notice != null &&
            (notice is! String ||
                !RegExp(
                  r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
                ).hasMatch(notice))) ||
        (phase == ServerMaintenancePhase.scheduled &&
            (notice == null || startsAt == null))) {
      throw const FormatException('Incomplete maintenance status');
    }
    final version = json['targetVersion'];
    final retry = json['retryAfterSeconds'];
    return ServerMaintenanceSnapshot(
      phase: phase,
      serverTime: observedServerTime ?? serverTime,
      noticeId: notice as String?,
      startsAt: startsAt,
      targetVersion:
          version is String &&
              RegExp(r'^v?\d{1,4}\.\d{1,4}\.\d{1,4}$').hasMatch(version)
          ? version
          : null,
      retryAfterSeconds: retry is int ? retry.clamp(5, 60) : 10,
    );
  }

  final ServerMaintenancePhase phase;
  final DateTime serverTime;
  final String? noticeId;
  final DateTime? startsAt;
  final String? targetVersion;
  final int retryAfterSeconds;

  String get noticeKey => '$noticeId|${startsAt?.toIso8601String()}';
  bool get blocksWork =>
      phase == ServerMaintenancePhase.updating ||
      phase == ServerMaintenancePhase.recoveryRequired;
}

typedef MaintenanceStatusReader = Future<ServerMaintenanceSnapshot> Function();

/// Nginx serves an atomic status file; its Date header is fresher than the
/// document timestamp. Both sources remain independent of the device clock.
DateTime? maintenanceHttpDate(String? value) => parseHttpResponseDate(value);

/// One bounded read loop shared by every route and every Flutter platform.
/// It does not own credentials, navigation, drafts, or business requests.
class ServerMaintenanceController extends ChangeNotifier {
  ServerMaintenanceController({required this.read, required this.ready});

  final MaintenanceStatusReader read;
  final Future<bool> Function() ready;
  final Stopwatch _elapsed = Stopwatch();
  ServerMaintenanceSnapshot? _snapshot;
  ServerMaintenanceSnapshot? get snapshot => _snapshot;
  bool _disposed = false;
  bool _visible = false;
  bool _checking = false;
  bool get checking => _checking;
  bool _lastCheckFailed = false;
  bool get lastCheckFailed => _lastCheckFailed;
  Timer? _timer;

  DateTime? get serverNow => _snapshot?.serverTime.add(_elapsed.elapsed);
  Duration? get remaining {
    final startsAt = _snapshot?.startsAt;
    final now = serverNow;
    return startsAt == null || now == null ? null : startsAt.difference(now);
  }

  bool get shouldWarn =>
      _snapshot?.phase == ServerMaintenancePhase.scheduled &&
      remaining != null &&
      remaining! <= const Duration(minutes: 10);

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _timer?.cancel();
    if (value) unawaited(checkNow());
  }

  Future<void> checkNow() async {
    if (_disposed || _checking) return;
    _timer?.cancel();
    _checking = true;
    notifyListeners();
    try {
      final next = await read();
      if (_disposed) return;
      // Only confirmed application readiness releases an existing maintenance
      // screen. A stale/cleared host marker cannot expose an unavailable app.
      if (_snapshot?.blocksWork == true &&
          next.phase == ServerMaintenancePhase.available &&
          !await ready()) {
        if (!_disposed) _lastCheckFailed = true;
        return;
      }
      if (_disposed) return;
      _snapshot = next;
      _elapsed
        ..reset()
        ..start();
      _lastCheckFailed = false;
    } catch (_) {
      if (!_disposed) _lastCheckFailed = true;
    } finally {
      if (!_disposed) {
        _checking = false;
        notifyListeners();
        if (_visible) {
          _timer = Timer(
            Duration(seconds: _snapshot?.retryAfterSeconds ?? 15),
            checkNow,
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _elapsed.stop();
    super.dispose();
  }
}

final serverMaintenanceControllerProvider =
    Provider<ServerMaintenanceController>((ref) {
      final apiBase = ref.watch(apiBaseUrlProvider);
      final dio = createCompanyDio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 4),
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
          followRedirects: false,
          headers: const {'Cache-Control': 'no-cache'},
        ),
      );
      final controller = ServerMaintenanceController(
        read: () async {
          final response = await dio.get<Object?>(
            '$apiBase/system/maintenance',
          );
          final data = response.data;
          if (response.statusCode != 200 || data is! Map<String, dynamic>) {
            throw const FormatException('Invalid maintenance response');
          }
          return ServerMaintenanceSnapshot.fromJson(
            data,
            observedServerTime: maintenanceHttpDate(
              response.headers.value('date'),
            ),
          );
        },
        ready: () async {
          try {
            final response = await dio.get<Object?>(
              '${healthProbeBaseUrl(apiBase)}/actuator/health/readiness',
            );
            return isHealthyProbeResponse(response.statusCode, response.data);
          } on DioException {
            return false;
          }
        },
      );
      ref.onDispose(() {
        controller.dispose();
        dio.close(force: true);
      });
      return controller;
    });
