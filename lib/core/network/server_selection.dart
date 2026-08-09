// 服务器自动选择：在公司内网 → 用本地后端；在外网 → 用云端后端（仅 remote_access 授权账号可用，
// 门禁在后端 RemoteAccessGuardFilter）。依据：探测本地 /actuator/health 是否可达。
//
// 三种模式（持久化在 SharedPreferences）：
//   auto（默认）—— 本地可达→本地；否则→云端（若已配云端地址）。
//   local        —— 强制本地（排障）。
//   cloud        —— 强制云端（排障）。
//
// 探测结果也持久化，避免每次启动都先抖到云端：初始读上次结果，随后周期复测，覆盖
// 「带着打开的 App 进出公司」这类场景。与 server_config.apiBaseUrlProvider 协作：
// 本地可达性变化时，watch apiBaseUrlProvider 的 Dio（apiClient / visitorApi / connectionRecovery）
// 自动重建指向新地址。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/providers/shared_providers.dart';
import 'api_base_url.dart';
import 'health_probe.dart';

const _kCloudUrlKey = 'uten.server_url_override'; // 云端地址（复用原 override key，向后兼容）
const _kServerModeKey = 'uten.server_mode'; // auto | local | cloud
const _kLocalReachableKey = 'uten.local_server_reachable';

/// 服务器选择模式。
enum ServerMode {
  /// 自动：本地可达→本地，否则→云端。默认值。
  auto,
  /// 强制本地（排障）。
  local,
  /// 强制云端（排障）。
  cloud,
}

/// 编译期本地（公司内网）地址，来自 --dart-define=API_BASE_URL。
String get localApiBaseUrl => apiBaseUrl;

/// 纯函数：据模式 / 云端地址 / 本地可达性决定生效 URL（抽成纯函数便于单测）。
/// - local → 本地；
/// - cloud → 云端（未配回落本地）；
/// - auto  → 本地可达用本地，否则云端（未配回落本地）。
String effectiveServerUrl({
  required ServerMode mode,
  required String local,
  String? cloud,
  required bool localReachable,
}) {
  switch (mode) {
    case ServerMode.local:
      return local;
    case ServerMode.cloud:
      return cloud ?? local;
    case ServerMode.auto:
      return localReachable ? local : (cloud ?? local);
  }
}

ServerMode readServerMode(SharedPreferences prefs) {
  switch (prefs.getString(_kServerModeKey)) {
    case 'local':
      return ServerMode.local;
    case 'cloud':
      return ServerMode.cloud;
    default:
      return ServerMode.auto;
  }
}

Future<void> writeServerMode(SharedPreferences prefs, ServerMode mode) =>
    prefs.setString(_kServerModeKey, mode.name);

/// 已存的云端地址（经校验），未设置或非法返回 null。
String? readCloudUrl(SharedPreferences prefs) {
  final raw = prefs.getString(_kCloudUrlKey);
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    return resolveApiBaseUrl(raw.trim(), releaseMode: kReleaseMode, web: kIsWeb);
  } on StateError {
    return null;
  }
}

/// 解析云端地址（不落库）；非法抛 StateError，供设置页即时校验。
String resolveCloudUrl(String url) =>
    resolveApiBaseUrl(url.trim(), releaseMode: kReleaseMode, web: kIsWeb);

Future<void> writeCloudUrl(SharedPreferences prefs, String? url) async {
  if (url == null || url.trim().isEmpty) {
    await prefs.remove(_kCloudUrlKey);
  } else {
    await prefs.setString(_kCloudUrlKey, url.trim());
  }
}

/// 本地服务器可达性。初始读上次结果（避免启动抖动），随后周期探测更新。
class LocalServerReachabilityNotifier extends StateNotifier<bool> {
  LocalServerReachabilityNotifier(this._prefs)
      : super(_prefs.getBool(_kLocalReachableKey) ?? true) {
    // 启动稍延迟做一次新鲜探测；随后每 60s 复测，覆盖「App 开着进出公司」。
    _initialTimer = Timer(const Duration(seconds: 2), probe);
    _periodicTimer = Timer.periodic(const Duration(seconds: 60), (_) => probe());
  }

  final SharedPreferences _prefs;
  Timer? _initialTimer;
  Timer? _periodicTimer;
  bool _probing = false;

  /// 主动探测本地 /actuator/health；仅在结果变化时写库 + 通知监听者。
  Future<void> probe() async {
    if (_probing) return;
    _probing = true;
    final reachable =
        await probeHealth(healthProbeBaseUrl(localApiBaseUrl));
    _probing = false;
    if (!mounted) return;
    if (state != reachable) {
      await _prefs.setBool(_kLocalReachableKey, reachable);
      state = reachable;
    }
  }

  /// 排障 / 测试用手动覆盖。
  Future<void> overrideForTest(bool reachable) async {
    await _prefs.setBool(_kLocalReachableKey, reachable);
    if (mounted) state = reachable;
  }

  @override
  void dispose() {
    _initialTimer?.cancel();
    _periodicTimer?.cancel();
    super.dispose();
  }
}

final localServerReachableProvider =
    StateNotifierProvider<LocalServerReachabilityNotifier, bool>(
  (ref) => LocalServerReachabilityNotifier(ref.watch(sharedPreferencesProvider)),
);
