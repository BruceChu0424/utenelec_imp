// 运行时只在两个构建期可信端点之间切换：API_BASE_URL（本地）和
// CLOUD_API_BASE_URL（云端）。Release 绝不从本地存储读取任意 host。
//
// 原生端的 auto 模式探测本地服务，本地可达优先本地，否则才使用固定云端地址；
// Debug 可显式设置开发覆盖。Web Release 始终走当前页面同源 /api，并通过公司
// 内外网的 split-horizon DNS / 不同访问入口落到对应站点；Web 不运行局域网探针。
//
// ADR-183 的日常云入口只转发端到端加密流量，业务仍由公司本地主站处理。
// 灾备接管必须重新认证并撤销旧会话，不向云入口复制业务 JWT 密钥，
// 连接失败也不能自动重放写请求或启用另一份业务写主。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/shared_providers.dart';
import 'api_base_url.dart';
import 'server_selection.dart';

/// 当前生效的后端 base URL：据选择模式 + 云端地址 + 本地可达性决定。
/// - local → 编译期本地地址；
/// - cloud → 云端地址（未配则回落本地）；
/// - auto  → 本地可达用本地，否则用云端（未配云端则回落本地）。
final apiBaseUrlProvider = Provider<String>((ref) {
  // prefs 未注入时 shared_providers 已给出全内存空实现（读全默认），
  // 这里保持对可空读取的容忍以适配测试注入 null 的场景。
  final prefs = ref.watch(sharedPreferencesProvider);
  return effectiveServerUrl(
    mode: readServerMode(prefs),
    local: apiBaseUrl,
    cloud: readCloudUrl(prefs),
    localReachable: ref.watch(localServerReachableProvider),
    web: kIsWeb,
  );
});
