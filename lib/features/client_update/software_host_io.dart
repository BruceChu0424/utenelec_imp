import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'client_update_bridge.dart';
import 'software_download_target.dart';
import 'software_host_info.dart';

String? softwareWindowsUserAgent() => null;

Future<SoftwareHostInfo> readSoftwareHostInfo() async {
  try {
    // Additive, side-effect-free host probe. getInstallContext must retain the
    // process target for the existing in-place updater, so never reinterpret it.
    final value = await ClientUpdateBridge.channel
        .invokeMapMethod<dynamic, dynamic>('getSoftwareDownloadHost')
        .timeout(const Duration(milliseconds: 1200));
    if (value != null) return softwareHostFromNative(value);
  } on MissingPluginException {
    // Old runners remain usable and let the employee select a destination.
  } on PlatformException {
    // Detection is optional; a failure does not prevent manual downloads.
  } on TimeoutException {
    // Keep an unresponsive older plugin from blocking the page.
  }
  final platform = SoftwareDownloadPlatform.fromName(Platform.operatingSystem);
  return SoftwareHostInfo(
    platform: platform,
    osLabel: platform?.label ?? '系统待确认',
    osCertainty: platform == null
        ? SoftwareDetectionCertainty.unknown
        : SoftwareDetectionCertainty.hint,
    source: 'nativeFallback',
    certaintyExplanation: '此客户端尚未提供完整的系统识别，请手动选择下载目标；不会把进程架构当作系统架构。',
  );
}
