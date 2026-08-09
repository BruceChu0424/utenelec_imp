// 运行时可切换的后端服务器地址（本地 / 云端自动选择）。
//
// 默认用编译期 API_BASE_URL（公司内网本地后端）。授权用户可在「服务器」设置页填云端地址并选模式：
// server_selection 依据「本地是否可达」在本地/云端之间自动选择（auto），或强制其一（排障）。
// 模式与云端地址持久化在 SharedPreferences；切换后所有 watch apiBaseUrlProvider 的客户端
// （apiClient / visitorApi / connectionRecovery）自动重建 Dio 指向新地址。
//
// 不同服务器（本地/云端）若 JWT issuer/secret 不同，切换后需重新登录；为「自动模式」无缝切换，
// 建议本地与云端部署用相同的 UTEN_JWT_ISSUER 与 UTEN_JWT_SECRET（两者共享同一份数据库副本，
// 故同一 token 可在两端校验通过）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/shared_providers.dart';
import 'api_base_url.dart';
import 'server_selection.dart';

/// 当前生效的后端 base URL：据选择模式 + 云端地址 + 本地可达性决定。
/// - local → 编译期本地地址；
/// - cloud → 云端地址（未配则回落本地）；
/// - auto  → 本地可达用本地，否则用云端（未配云端则回落本地）。
final apiBaseUrlProvider = Provider<String>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return effectiveServerUrl(
    mode: readServerMode(prefs),
    local: apiBaseUrl,
    cloud: readCloudUrl(prefs),
    localReachable: ref.watch(localServerReachableProvider),
  );
});
