// 原生端服务器选择：公司内网优先本地后端；本地不可达时才使用构建期固定的云端后端。
// Web Release 始终使用同源 /api，由 split-horizon DNS / 访问入口决定内外网站点；
// Debug 可显式使用开发端点，但两者都不运行无法证明局域网位置的同源探针。
//
// 三种模式（持久化在 SharedPreferences）：
//   auto（默认）—— 本地可达→本地；否则→云端（若已配云端地址）。
//   local        —— 强制本地（排障）。
//   cloud        —— 强制云端（排障；仅当构建已配置可信云端地址时生效）。
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

const _configuredCloudApiBaseUrl = String.fromEnvironment('CLOUD_API_BASE_URL');
const _kCloudUrlKey = 'uten.server_url_override'; // 仅 Debug 显式覆盖，Release 永不读取
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
  bool web = false,
}) {
  // Web Release 的 local 必然是同源 /api（resolveApiBaseUrl 强制）；Debug
  // 可使用显式开发端点。两者均忽略缓存的 cloud 模式和探针结果。
  if (web) return local;
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

/// 纯函数：选择可信云端地址。
///
/// Release 只使用构建期 `CLOUD_API_BASE_URL`，故意完全忽略本地缓存；这避免被
/// 篡改的 SharedPreferences 把登录密码或 Bearer token 引向攻击者主机。Debug
/// 才允许显式覆盖。Web 始终返回 null，因为 Web 必须使用同源 `/api`。
String? resolveTrustedCloudUrl({
  required String configured,
  String? storedOverride,
  required bool releaseMode,
  required bool debugOverridesAllowed,
  required bool web,
}) {
  if (web) return null;

  final configuredValue = configured.trim();
  final overrideValue = storedOverride?.trim() ?? '';
  final selected =
      !releaseMode && debugOverridesAllowed && overrideValue.isNotEmpty
      ? overrideValue
      : configuredValue;
  if (selected.isEmpty) return null;

  return resolveApiBaseUrl(selected, releaseMode: releaseMode, web: false);
}

/// 当前可信云端地址。未配置或配置非法时安全地返回 null，由选择逻辑回退本地。
String? readCloudUrl(SharedPreferences prefs) {
  try {
    return resolveTrustedCloudUrl(
      configured: _configuredCloudApiBaseUrl,
      storedOverride: prefs.getString(_kCloudUrlKey),
      releaseMode: kReleaseMode,
      debugOverridesAllowed: kDebugMode && !kIsWeb,
      web: kIsWeb,
    );
  } on StateError {
    return null;
  }
}

/// 解析云端地址（不落库）；非法抛 StateError，供设置页即时校验。
String resolveCloudUrl(String url) =>
    resolveApiBaseUrl(url.trim(), releaseMode: kReleaseMode, web: kIsWeb);

Future<void> writeCloudUrl(SharedPreferences prefs, String? url) async {
  if (!kDebugMode || kIsWeb) {
    // 清掉旧版本可能遗留的任意 host；生产版本绝不保存用户输入地址。
    await prefs.remove(_kCloudUrlKey);
    return;
  }
  if (url == null || url.trim().isEmpty) {
    await prefs.remove(_kCloudUrlKey);
  } else {
    await prefs.setString(_kCloudUrlKey, url.trim());
  }
}

/// 本地服务器可达性。初始读上次结果（避免启动抖动），随后周期探测更新。
class LocalServerReachabilityNotifier extends StateNotifier<bool> {
  LocalServerReachabilityNotifier(
    this._prefs, {
    bool web = kIsWeb,
    Future<bool> Function()? healthProbe,
  }) : _healthProbe = healthProbe ?? _probeConfiguredLocalServer,
       _web = web,
       super(web ? true : (_prefs.getBool(_kLocalReachableKey) ?? true)) {
    // Web 只能证明当前 origin 可达，无法据此判断局域网，因此不运行自动切换探针。
    if (_web) return;
    // 缓存只服务首帧；下一事件循环立即新鲜探测，避免外网冷启动先请求不可达的本地服务。
    _initialTimer = Timer(Duration.zero, probe);
    _periodicTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => probe(),
    );
  }

  final SharedPreferences _prefs;
  final Future<bool> Function() _healthProbe;
  final bool _web;
  Timer? _initialTimer;
  Timer? _periodicTimer;
  bool _probing = false;

  /// 主动探测本地 /actuator/health；仅在结果变化时写库 + 通知监听者。
  Future<void> probe() async {
    if (_web || _probing) return;
    _probing = true;
    bool reachable;
    try {
      reachable = await _healthProbe();
    } catch (_) {
      reachable = false;
    } finally {
      _probing = false;
    }
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

Future<bool> _probeConfiguredLocalServer() =>
    probeHealth(healthProbeBaseUrl(localApiBaseUrl));

final localServerReachableProvider =
    StateNotifierProvider<LocalServerReachabilityNotifier, bool>(
      (ref) =>
          LocalServerReachabilityNotifier(ref.watch(sharedPreferencesProvider)),
    );
