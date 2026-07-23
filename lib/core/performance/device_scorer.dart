// 设备能力检测 + 性能档位打分
// 文档：docs/00-项目准则/07-性能自适应.md

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'performance_tier.dart';

/// 设备能力快照
class DeviceCapability {
  const DeviceCapability({
    required this.platform,
    required this.isMobile,
    required this.isDesktop,
    required this.isWeb,
    this.androidSdk,
    this.iosVersion,
    this.physicalMemoryBytes,
  });

  final TargetPlatform platform;
  final bool isMobile;
  final bool isDesktop;
  final bool isWeb;
  final int? androidSdk;
  final String? iosVersion;
  final int? physicalMemoryBytes;

  static const unknown = DeviceCapability(
    platform: TargetPlatform.android,
    isMobile: false,
    isDesktop: false,
    isWeb: true,
  );
}

/// 设备能力检测器
class DeviceProbe {
  DeviceProbe({DeviceInfoPlugin? deviceInfo})
      : _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _deviceInfo;

  /// 读取设备信息（异步）
  Future<DeviceCapability> probe() async {
    if (kIsWeb) {
      // Web 无法可靠检测，默认 standard
      return DeviceCapability(
        platform: defaultTargetPlatform,
        isMobile: false,
        isDesktop: false,
        isWeb: true,
      );
    }

    if (Platform.isAndroid) {
      final info = await _deviceInfo.androidInfo;
      return DeviceCapability(
        platform: TargetPlatform.android,
        isMobile: true,
        isDesktop: false,
        isWeb: false,
        androidSdk: info.version.sdkInt,
        // Android 的 isLowRamDevice 表示 < 4GB
      );
    }

    if (Platform.isIOS) {
      final info = await _deviceInfo.iosInfo;
      return DeviceCapability(
        platform: TargetPlatform.iOS,
        isMobile: true,
        isDesktop: false,
        isWeb: false,
        iosVersion: info.systemVersion,
      );
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return DeviceCapability(
        platform: defaultTargetPlatform,
        isMobile: false,
        isDesktop: true,
        isWeb: false,
      );
    }

    return DeviceCapability.unknown;
  }
}

/// 根据设备能力打分，映射到 [PerformanceTier]
///
/// 评分规则：
/// - Web：默认 standard（无法可靠检测）
/// - 桌面端：默认 rich
/// - Android：API < 24 或低内存 → lite；否则 standard
/// - iOS：系统版本 < 14 → lite；否则 standard
class DeviceScorer {
  const DeviceScorer();

  PerformanceTier score(DeviceCapability cap) {
    // 桌面端：rich
    if (cap.isDesktop) return PerformanceTier.rich;

    // Web：standard
    if (cap.isWeb) return PerformanceTier.standard;

    // Android
    if (cap.platform == TargetPlatform.android) {
      final sdk = cap.androidSdk ?? 30;
      // Android 7.0 (API 24) 以下或低内存设备 → lite
      if (sdk < 24) return PerformanceTier.lite;
      // 较新设备默认 standard（无法精确读内存，保守一点）
      if (sdk < 26) return PerformanceTier.lite;
      return PerformanceTier.standard;
    }

    // iOS
    if (cap.platform == TargetPlatform.iOS) {
      final version = cap.iosVersion ?? '15.0';
      final major = int.tryParse(version.split('.').first) ?? 15;
      // iOS 14 以下 → lite
      if (major < 14) return PerformanceTier.lite;
      return PerformanceTier.standard;
    }

    return PerformanceTier.standard;
  }
}
