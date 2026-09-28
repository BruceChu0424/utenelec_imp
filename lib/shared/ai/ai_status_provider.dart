import 'package:flutter_riverpod/flutter_riverpod.dart';

/// `GET /ai/status`: 当前账号能否使用 AI(ADR-133)。不含服务商/模型等配置细节。
class AiStatus {
  const AiStatus({
    required this.available,
    required this.aiAllowedForMe,
    required this.supportsVision,
  });

  factory AiStatus.fromJson(Map<String, dynamic> json) => AiStatus(
        available: json['available'] == true,
        aiAllowedForMe: json['aiAllowedForMe'] == true,
        supportsVision: json['supportsVision'] == true,
      );

  static const unavailable =
      AiStatus(available: false, aiAllowedForMe: false, supportsVision: false);

  /// 管理员已配置并启用可用的 AI 服务。
  final bool available;

  /// 当前账号有 `ai:use` 权限。
  final bool aiAllowedForMe;

  /// 当前 AI 服务能识别图片/扫描件。
  final bool supportsVision;

  /// 本账号本次能否真正用上 AI。
  bool get usable => available && aiAllowedForMe;
}

/// fl-platform: 用 ApiClient 实现; 失败时返回 [AiStatus.unavailable](不打扰用户)。
final aiStatusProvider = FutureProvider.autoDispose<AiStatus>((ref) async {
  throw UnimplementedError('aiStatusProvider');
});
