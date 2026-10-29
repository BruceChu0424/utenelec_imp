import 'client_release.dart';
import 'software_download_target.dart';

enum SoftwareDetectionCertainty { unknown, hint, reported, nativeConfirmed }

class SoftwareHostInfo {
  const SoftwareHostInfo({
    this.platform,
    this.osVersion,
    this.osLabel = '系统待确认',
    this.architecture,
    this.windowsRuntimeFamily,
    this.osCertainty = SoftwareDetectionCertainty.unknown,
    this.architectureCertainty = SoftwareDetectionCertainty.unknown,
    this.source = 'unknown',
    this.certaintyExplanation = '',
    this.isServer = false,
    this.isSimulator = false,
  });

  final SoftwareDownloadPlatform? platform;
  final String? osVersion, architecture, windowsRuntimeFamily;
  final String osLabel, source, certaintyExplanation;
  final SoftwareDetectionCertainty osCertainty, architectureCertainty;
  final bool isServer;
  final bool isSimulator;

  bool get requiresManualConfirmation =>
      architecture == null ||
      isSimulator ||
      osCertainty == SoftwareDetectionCertainty.unknown ||
      osVersion == 'windows7' ||
      osVersion == 'windows7_rtm' ||
      osVersion == 'windows10_or_11' ||
      platform == SoftwareDownloadPlatform.windows &&
          windowsRuntimeFamily == null;

  SoftwareDownloadTarget? get suggestedTarget {
    final targetPlatform = platform;
    final arch = architecture;
    if (targetPlatform == null ||
        arch == null ||
        isSimulator ||
        osVersion == 'windows7_rtm') {
      return null;
    }
    final family = targetPlatform == SoftwareDownloadPlatform.windows
        ? windowsRuntimeFamily
        : ClientRuntimeFamily.flutter;
    if (family == null) return null;
    final version = switch (osVersion) {
      'windows7' || 'windows7_sp1' => SoftwareWindowsVersion.windows7Sp1,
      'windows81' => SoftwareWindowsVersion.windows81,
      'windows10' => SoftwareWindowsVersion.windows10,
      'windows11' || 'windows11_or_later' => SoftwareWindowsVersion.windows11,
      _ => null,
    };
    final target = SoftwareDownloadTarget(
      platform: targetPlatform,
      runtimeFamily: family,
      architecture: arch,
      windowsVersion: version,
    );
    return target.isSupported ? target : null;
  }
}

String? softwareCanonicalArchitecture(String? value) =>
    switch (value?.trim().toLowerCase()) {
      'x64' || 'x86_64' || 'amd64' => 'x64',
      'x86' || 'i386' || 'i686' => 'x86',
      'arm64' || 'aarch64' || 'arm64-v8a' => 'arm64',
      'armeabi-v7a' || 'armv7l' => 'armeabi-v7a',
      // "universal" describes a package, never an observed CPU architecture.
      _ => null,
    };

SoftwareHostInfo softwareHostFromNative(Map<dynamic, dynamic> value) {
  final platform = SoftwareDownloadPlatform.fromName(
    value['platform'] as String?,
  );
  final architecture = softwareCanonicalArchitecture(
    value['architecture'] as String?,
  );
  final major = value['osMajor'] is int ? value['osMajor'] as int : null;
  final minor = value['osMinor'] is int ? value['osMinor'] as int : null;
  final build = value['osBuild'] is int ? value['osBuild'] as int : null;
  final servicePack = value['servicePackMajor'] is int
      ? value['servicePackMajor'] as int
      : null;
  final server = value['isServer'] == true;
  final simulator = value['isSimulator'] == true;
  String? version, family;
  var label = platform?.label ?? '系统待确认';
  var certainty = SoftwareDetectionCertainty.unknown;
  if (platform == SoftwareDownloadPlatform.windows) {
    if (server) {
      version = 'windows_server';
      label = value['osLabel'] as String? ?? 'Windows Server';
      certainty = SoftwareDetectionCertainty.nativeConfirmed;
    } else if (major == 6 && minor == 1) {
      final sp1 = servicePack != null
          ? servicePack >= 1
          : build != null && build >= 7601;
      final rtm = !sp1 && servicePack == 0 && build != null && build <= 7600;
      version = sp1
          ? 'windows7_sp1'
          : rtm
          ? 'windows7_rtm'
          : 'windows7';
      label = sp1
          ? 'Windows 7 SP1'
          : rtm
          ? 'Windows 7（未安装 SP1）'
          : 'Windows 7（SP1 未确认）';
      family = rtm ? null : ClientRuntimeFamily.wpfLegacy;
      certainty = SoftwareDetectionCertainty.nativeConfirmed;
    } else if (major == 6 && minor == 3) {
      version = 'windows81';
      label = 'Windows 8.1';
      family = ClientRuntimeFamily.wpfLegacy;
      certainty = SoftwareDetectionCertainty.nativeConfirmed;
    } else if (major == 6 && minor == 2) {
      version = 'windows8';
      label = 'Windows 8';
      certainty = SoftwareDetectionCertainty.nativeConfirmed;
    } else if (major == 10 && build != null && build > 0) {
      version = build >= 22000 ? 'windows11' : 'windows10';
      label = build >= 22000 ? 'Windows 11' : 'Windows 10';
      family = ClientRuntimeFamily.flutter;
      certainty = SoftwareDetectionCertainty.nativeConfirmed;
    }
  } else if (platform != null) {
    version = value['osVersion'] as String?;
    final reportedLabel = value['osLabel'] as String?;
    if (reportedLabel != null && reportedLabel.isNotEmpty) {
      label = reportedLabel;
    }
    certainty = SoftwareDetectionCertainty.nativeConfirmed;
  }
  final explanations = <String>[
    if (platform == SoftwareDownloadPlatform.windows &&
        const {'windows7', 'windows7_rtm'}.contains(version))
      '兼容版要求 Windows 7 SP1，请核对目标电脑的服务包。',
    if (platform == SoftwareDownloadPlatform.windows && family == null)
      '尚未确认此系统对应的已支持客户端，请手动选择下载目标。',
    if (architecture == null) '未确认系统架构，请手动选择；不会以进程位数代替系统位数。',
    if (simulator) '当前运行于模拟器，不能据此确认真实设备的安装目标。',
  ];
  return SoftwareHostInfo(
    platform: platform,
    osVersion: version,
    osLabel: label,
    architecture: architecture,
    windowsRuntimeFamily: family,
    osCertainty: certainty,
    architectureCertainty: architecture == null
        ? SoftwareDetectionCertainty.unknown
        : SoftwareDetectionCertainty.nativeConfirmed,
    source: 'nativeSystem',
    certaintyExplanation: explanations.join(' '),
    isServer: server,
    isSimulator: simulator,
  );
}

/// Pure browser resolver. UA-CH is a browser report, not an installation check.
/// Windows platformVersion is the API contract version (13+ means 11 or later),
/// not an NT version: https://learn.microsoft.com/en-us/microsoft-edge/web-platform/how-to-detect-win11
SoftwareHostInfo softwareHostFromBrowser({
  String? userAgent,
  String? navigatorPlatform,
  int? maxTouchPoints,
  Map<String, Object?>? clientHints,
}) {
  final ua = userAgent ?? '';
  var platform = SoftwareDownloadPlatform.fromName(
    switch (clientHints?['platform']) {
      'Windows' => 'windows',
      'macOS' => 'macos',
      'Android' => 'android',
      'Linux' => 'linux',
      'iOS' => 'ios',
      _ => null,
    },
  );
  platform ??= switch (ua) {
    _ when RegExp(r'iPhone|iPad|iPod', caseSensitive: false).hasMatch(ua) =>
      SoftwareDownloadPlatform.ios,
    _
        when (navigatorPlatform == 'MacIntel' || ua.contains('Macintosh')) &&
            (maxTouchPoints ?? 0) > 1 =>
      SoftwareDownloadPlatform.ios,
    _ when ua.contains('Android') => SoftwareDownloadPlatform.android,
    _ when ua.contains('Windows NT') => SoftwareDownloadPlatform.windows,
    _ when ua.contains('Macintosh') || ua.contains('Mac OS X') =>
      SoftwareDownloadPlatform.macos,
    _ when ua.contains('Linux') || ua.contains('X11') =>
      SoftwareDownloadPlatform.linux,
    _ => null,
  };
  String? version, family, architecture;
  var label = platform?.label ?? '系统待确认';
  var osCertainty = platform == null
      ? SoftwareDetectionCertainty.unknown
      : SoftwareDetectionCertainty.hint;
  var archCertainty = SoftwareDetectionCertainty.unknown;
  final hintArchitecture = clientHints?['architecture'];
  final bitness = clientHints?['bitness'];
  if (hintArchitecture is String) {
    if (hintArchitecture == 'x86' && clientHints?['wow64'] == true) {
      architecture = 'x64';
    } else if (hintArchitecture == 'x86' && bitness == '64') {
      architecture = 'x64';
    } else if (hintArchitecture == 'x86' && bitness == '32') {
      architecture = 'x86';
    } else if (hintArchitecture == 'arm' && bitness == '64') {
      architecture = 'arm64';
    } else if (hintArchitecture == 'arm' &&
        bitness == '32' &&
        platform == SoftwareDownloadPlatform.android) {
      architecture = 'armeabi-v7a';
    }
    architecture ??= switch (hintArchitecture) {
      'arm64' || 'aarch64' => 'arm64',
      'x86_64' || 'amd64' => 'x64',
      _ => null,
    };
    if (architecture != null) {
      archCertainty = SoftwareDetectionCertainty.reported;
    }
  }
  if (platform == SoftwareDownloadPlatform.windows) {
    final nt = RegExp(
      r'Windows NT (\d+)\.(\d+)',
      caseSensitive: false,
    ).firstMatch(ua);
    final reportedVersion = clientHints?['platformVersion'];
    final apiMajor = reportedVersion is String
        ? int.tryParse(reportedVersion.split('.').first)
        : null;
    if (apiMajor != null && apiMajor >= 13) {
      version = 'windows11_or_later';
      label = 'Windows 11 或更新版本';
      family = ClientRuntimeFamily.flutter;
      osCertainty = SoftwareDetectionCertainty.reported;
    } else if (apiMajor != null && apiMajor >= 1 && apiMajor <= 10) {
      version = 'windows10';
      label = 'Windows 10';
      family = ClientRuntimeFamily.flutter;
      osCertainty = SoftwareDetectionCertainty.reported;
    } else if (nt?.group(1) == '6' && nt?.group(2) == '1') {
      version = 'windows7';
      label = 'Windows 7（SP1 未确认）';
      family = ClientRuntimeFamily.wpfLegacy;
    } else if (nt?.group(1) == '6' && nt?.group(2) == '3') {
      version = 'windows81';
      label = 'Windows 8.1';
      family = ClientRuntimeFamily.wpfLegacy;
    } else if (nt?.group(1) == '6' && nt?.group(2) == '2') {
      version = 'windows8';
      label = 'Windows 8';
    } else if (nt?.group(1) == '10' && apiMajor != 0) {
      version = 'windows10_or_11';
      label = 'Windows 10 / 11（浏览器无法区分）';
      family = ClientRuntimeFamily.flutter;
    }
  } else if (platform != null) {
    final reported = clientHints?['platformVersion'];
    if (reported is String &&
        RegExp(r'^\d+(?:\.\d+){0,3}$').hasMatch(reported)) {
      version = reported;
      label = '${platform.label} $reported';
      osCertainty = SoftwareDetectionCertainty.reported;
    }
  }
  // A positive ARM64 token is useful. Win32/Intel/armv7 can describe an emulated
  // browser, and never prove that the OS is 32-bit or an Intel Mac.
  if (architecture == null &&
      RegExp(r'\b(?:ARM64|aarch64)\b', caseSensitive: false).hasMatch(ua)) {
    architecture = 'arm64';
    archCertainty = SoftwareDetectionCertainty.hint;
  }
  if (architecture == null &&
      platform == SoftwareDownloadPlatform.windows &&
      const {'windows7', 'windows81'}.contains(version) &&
      RegExp(r'\b(?:WOW64|Win64|x64)\b', caseSensitive: false).hasMatch(ua)) {
    architecture = 'x64';
    archCertainty = SoftwareDetectionCertainty.hint;
  }
  final notes = <String>[
    if (version == 'windows10_or_11') '旧版浏览器标识无法区分 Windows 10 与 Windows 11。',
    if (version == 'windows7') '浏览器无法确认 SP1，兼容版最低要求 Windows 7 SP1。',
    if (platform == SoftwareDownloadPlatform.windows && family == null)
      '请手动确认已支持的 Windows 版本。',
    if (architecture == null) '未确认系统架构，请手动选择；浏览器位数不等于系统位数。',
    if (architecture != null) '系统信息来自浏览器报告，可手动改选其他电脑的下载目标。',
  ];
  return SoftwareHostInfo(
    platform: platform,
    osVersion: version,
    osLabel: label,
    architecture: architecture,
    windowsRuntimeFamily: family,
    osCertainty: osCertainty,
    architectureCertainty: archCertainty,
    source: clientHints == null ? 'userAgent' : 'userAgentClientHints',
    certaintyExplanation: notes.join(' '),
  );
}
