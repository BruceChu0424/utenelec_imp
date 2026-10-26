import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_info.dart';

enum SoftwareDownloadPlatform {
  windows('Windows', Icons.window_rounded),
  android('Android', Icons.android_rounded),
  macos('macOS', Icons.desktop_mac_outlined),
  ios('iOS', Icons.phone_iphone_rounded);

  const SoftwareDownloadPlatform(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Flutter resolves the native host OS and the browser host OS on Web.
final softwareDevicePlatformProvider = Provider<SoftwareDownloadPlatform?>((
  ref,
) {
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => SoftwareDownloadPlatform.windows,
    TargetPlatform.android => SoftwareDownloadPlatform.android,
    TargetPlatform.macOS => SoftwareDownloadPlatform.macos,
    TargetPlatform.iOS => SoftwareDownloadPlatform.ios,
    _ => null,
  };
});

String softwareProductName(Locale locale) => AppInfo.displayName;
