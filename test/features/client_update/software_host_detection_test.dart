import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_update_bridge.dart';
import 'package:uten_imp/features/client_update/software_downloads_presentation.dart';
import 'package:uten_imp/features/client_update/software_windows_host.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _HostEpoch extends Notifier<int> {
  @override
  int build() => 0;
  void advance() => state++;
}

Map<String, Object?> _windows({
  int major = 10,
  int minor = 0,
  int build = 22631,
  int sp = 0,
  String architecture = 'x64',
  bool server = false,
}) => {
  'platform': 'windows',
  'architecture': architecture,
  'osMajor': major,
  'osMinor': minor,
  'osBuild': build,
  'servicePackMajor': sp,
  'isServer': server,
};

ClientRelease _release({
  String platform = 'windows',
  String architecture = 'x64',
  String family = ClientRuntimeFamily.flutter,
  String state = 'PUBLISHED',
  String kind = 'installer',
  String? mode,
  String? storeUrl,
  int build = 2534,
}) => ClientRelease(
  id: '00000000-0000-0000-0000-000000000101',
  platform: platform,
  architecture: architecture,
  version: '2.5.34',
  buildNumber: build,
  releaseNotes: '',
  installMode:
      mode ??
      (family == ClientRuntimeFamily.wpfLegacy
          ? 'windows_wpf_setup'
          : 'windows_setup'),
  sha256: 'a' * 64,
  sizeBytes: 1234,
  runtimeFamily: family,
  state: state,
  packageKind: kind,
  fileName: platform == 'android' ? 'old.apk' : 'old.exe',
  storeUrl: storeUrl,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native OS facts separate real system architecture from updater process target',
    () {
      final host = softwareHostFromNative(_windows(architecture: 'arm64'));
      final installed = ClientInstallContext.fromJson({
        'platform': 'windows',
        'architecture': 'x86',
        'currentVersion': '2.5.34',
        'currentBuild': 2534,
      });
      expect(host.architecture, 'arm64');
      expect(host.osLabel, 'Windows 11');
      expect(
        host.architectureCertainty,
        SoftwareDetectionCertainty.nativeConfirmed,
      );
      expect(installed.architecture, 'x86');
      expect(installed.runtimeFamily, ClientRuntimeFamily.flutter);
    },
  );
  test('Win7 SP1, RTM and Win8.1 are distinct requirements', () {
    final sp1 = softwareHostFromNative(
      _windows(major: 6, minor: 1, build: 7601, sp: 1),
    );
    expect(sp1.osVersion, 'windows7_sp1');
    expect(sp1.suggestedTarget?.displayLabel, 'Windows 7 SP1 · X64 兼容版');
    final rtm = softwareHostFromNative(
      _windows(major: 6, minor: 1, build: 7600),
    );
    expect(rtm.osVersion, 'windows7_rtm');
    expect(rtm.requiresManualConfirmation, isTrue);
    expect(rtm.suggestedTarget, isNull);
    final win81 = softwareHostFromNative(
      _windows(major: 6, minor: 3, build: 9600, architecture: 'x86'),
    );
    expect(win81.suggestedTarget?.displayLabel, 'Windows 8.1 · X86 兼容版');
  });
  test(
    'Win8 and Windows Server never masquerade as supported desktop edition',
    () {
      final win8 = softwareHostFromNative(
        _windows(major: 6, minor: 2, build: 9200),
      );
      expect(win8.windowsRuntimeFamily, isNull);
      expect(win8.suggestedTarget, isNull);
      final server = softwareHostFromNative(
        _windows(server: true, build: 20348),
      );
      expect(server.isServer, isTrue);
      expect(server.osVersion, 'windows_server');
      expect(server.suggestedTarget, isNull);
    },
  );
  test('package universal is not a detected CPU', () {
    expect(
      softwareHostFromNative(_windows(architecture: 'universal')).architecture,
      isNull,
    );
    expect(
      softwareHostFromNative(_windows(architecture: 'unknown')).suggestedTarget,
      isNull,
    );
  });
  test(
    'frozen Windows NT10 UA cannot identify Windows11 or the real ARM host',
    () {
      final host = softwareHostFromBrowser(
        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140.0.0.0',
      );
      expect(host.osVersion, 'windows10_or_11');
      expect(host.osLabel, contains('无法区分'));
      expect(host.architecture, isNull);
      expect(host.requiresManualConfirmation, isTrue);
    },
  );
  test(
    'high entropy Windows API version and ARM bitness override frozen UA',
    () {
      final host = softwareHostFromBrowser(
        userAgent: 'Windows NT 10.0; Win64; x64',
        clientHints: {
          'platform': 'Windows',
          'platformVersion': '13.0.0',
          'architecture': 'arm',
          'bitness': '64',
        },
      );
      expect(host.osVersion, 'windows11_or_later');
      expect(host.architecture, 'arm64');
      expect(host.osCertainty, SoftwareDetectionCertainty.reported);
      expect(
        host.suggestedTarget?.windowsVersion,
        SoftwareWindowsVersion.windows11,
      );
    },
  );
  test('WOW64 says OS64 even when browser bitness is32', () {
    final host = softwareHostFromBrowser(
      clientHints: {
        'platform': 'Windows',
        'platformVersion': '10.0.0',
        'architecture': 'x86',
        'bitness': '32',
        'wow64': true,
      },
    );
    expect(host.architecture, 'x64');
    expect(host.osVersion, 'windows10');
    final native32 = softwareHostFromBrowser(
      clientHints: {
        'platform': 'Windows',
        'platformVersion': '10.0.0',
        'architecture': 'x86',
        'bitness': '32',
        'wow64': false,
      },
    );
    expect(native32.architecture, 'x86');
  });
  test('legacy UA may hint x64 but never prove Win7 service pack', () {
    final host = softwareHostFromBrowser(userAgent: 'Windows NT 6.1; WOW64');
    expect(host.architecture, 'x64');
    expect(host.osVersion, 'windows7');
    expect(host.requiresManualConfirmation, isTrue);
    expect(host.certaintyExplanation, contains('SP1'));
    expect(
      softwareHostFromBrowser(userAgent: 'Windows NT 6.1; Win32').architecture,
      isNull,
    );
  });
  test(
    'Intel Safari UA cannot distinguish Apple Silicon and desktop iPad stays iOS',
    () {
      final mac = softwareHostFromBrowser(
        userAgent: 'Macintosh; Intel Mac OS X 10_15_7',
        navigatorPlatform: 'MacIntel',
      );
      expect(mac.platform, SoftwareDownloadPlatform.macos);
      expect(mac.architecture, isNull);
      final ipad = softwareHostFromBrowser(
        userAgent: 'Macintosh; Intel Mac OS X 10_15_7',
        navigatorPlatform: 'MacIntel',
        maxTouchPoints: 5,
      );
      expect(ipad.platform, SoftwareDownloadPlatform.ios);
    },
  );
  test(
    'native Apple Android Linux payloads and simulator have honest targets',
    () {
      for (final platform in ['macos', 'android', 'linux', 'ios']) {
        final host = softwareHostFromNative({
          'platform': platform,
          'architecture': 'arm64',
          'osVersion': '14.0',
          'osLabel': '$platform 14.0',
        });
        expect(host.platform?.name, platform);
        expect(host.architecture, 'arm64');
      }
      expect(
        softwareHostFromNative({
          'platform': 'ios',
          'architecture': 'arm64',
          'isSimulator': true,
        }).suggestedTarget,
        isNull,
      );
    },
  );
  test('target matrix never offers Win11x86 or legacy ARM64', () {
    final targets = softwareDownloadTargets(SoftwareDownloadPlatform.windows);
    expect(targets.every((target) => target.isSupported), isTrue);
    expect(
      targets
          .where(
            (target) =>
                target.windowsVersion == SoftwareWindowsVersion.windows11,
          )
          .every((target) => target.architecture != 'x86'),
      isTrue,
    );
    expect(
      targets
          .where(
            (target) => target.runtimeFamily == ClientRuntimeFamily.wpfLegacy,
          )
          .every((target) => target.architecture != 'arm64'),
      isTrue,
    );
    expect(
      softwareDownloadArchitectures(SoftwareDownloadPlatform.android),
      contains('armeabi-v7a'),
    );
  });
  test(
    'selection is strict by platform family architecture and publication',
    () {
      const legacy = SoftwareDownloadTarget(
        platform: SoftwareDownloadPlatform.windows,
        runtimeFamily: ClientRuntimeFamily.wpfLegacy,
        architecture: 'x86',
        windowsVersion: SoftwareWindowsVersion.windows7Sp1,
      );
      expect(
        selectSoftwareInstaller([
          _release(family: ClientRuntimeFamily.wpfLegacy),
        ], target: legacy),
        isNull,
      );
      expect(
        selectSoftwareInstaller([
          _release(architecture: 'x86'),
        ], target: legacy),
        isNull,
      );
      expect(
        selectSoftwareInstaller([
          _release(
            family: ClientRuntimeFamily.wpfLegacy,
            architecture: 'x86',
            state: 'DRAFT',
          ),
        ], target: legacy),
        isNull,
      );
      expect(
        selectSoftwareInstaller([
          _release(family: ClientRuntimeFamily.wpfLegacy, architecture: 'x86'),
        ], target: legacy),
        isNotNull,
      );
    },
  );
  test(
    'Android full update APK and trusted store are supported without cross arch fallback',
    () {
      final apk = _release(
        platform: 'android',
        architecture: 'arm64',
        mode: 'android_package',
        kind: 'update',
      );
      const arm = SoftwareDownloadTarget(
        platform: SoftwareDownloadPlatform.android,
        architecture: 'arm64',
      );
      expect(isSoftwareInstallerForTarget(apk, arm), isTrue);
      final store = _release(
        platform: 'ios',
        architecture: 'universal',
        mode: 'store',
        kind: 'update',
        storeUrl: 'https://apps.apple.com/app/id123',
      );
      expect(isSoftwareDownloadRelease(store), isTrue);
      expect(
        isSoftwareDownloadRelease(
          _release(
            platform: 'ios',
            architecture: 'universal',
            mode: 'store',
            storeUrl: 'https://apps.apple.com/app/id123',
            build: 0,
          ),
        ),
        isFalse,
      );
      expect(
        selectSoftwareInstaller(
          [store],
          target: const SoftwareDownloadTarget(
            platform: SoftwareDownloadPlatform.ios,
            architecture: 'arm64',
          ),
        ),
        isNotNull,
      );
      expect(
        isSoftwareDownloadRelease(
          _release(
            platform: 'ios',
            architecture: 'universal',
            mode: 'store',
            storeUrl: 'https://evil.test/app',
          ),
        ),
        isFalse,
      );
      expect(
        isSoftwareDownloadRelease(
          _release(platform: 'linux', mode: 'linux_archive'),
        ),
        isFalse,
      );
    },
  );
  test('filename names the selected OS and architecture with safe ASCII', () {
    final release = _release(family: ClientRuntimeFamily.wpfLegacy);
    final name = softwareDownloadFilename(
      release,
      target: const SoftwareDownloadTarget(
        platform: SoftwareDownloadPlatform.windows,
        runtimeFamily: ClientRuntimeFamily.wpfLegacy,
        architecture: 'x64',
        windowsVersion: SoftwareWindowsVersion.windows7Sp1,
      ),
    );
    expect(name, contains('windows7sp1-x64'));
    expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name), isTrue);
    expect(
      softwareDownloadFilename(
        _release(
          platform: 'android',
          architecture: 'arm64',
          mode: 'android_package',
          kind: 'update',
        ),
      ),
      endsWith('android-arm64-setup.apk'),
    );
  });
  test(
    'nonWindows exact package wins and declared universal keeps its real name',
    () {
      const target = SoftwareDownloadTarget(
        platform: SoftwareDownloadPlatform.android,
        architecture: 'arm64',
      );
      final exact = _release(
        platform: 'android',
        architecture: 'arm64',
        mode: 'android_package',
        kind: 'update',
        build: 1,
      );
      final universal = _release(
        platform: 'android',
        architecture: 'universal',
        mode: 'android_package',
        kind: 'update',
        build: 99,
      );
      expect(
        selectSoftwareInstaller([universal, exact], target: target),
        same(exact),
      );
      expect(
        selectSoftwareInstaller([exact, universal], target: target),
        same(exact),
      );
      expect(
        selectSoftwareInstaller([universal], target: target),
        same(universal),
      );
      expect(
        softwareDownloadFilename(universal, target: target),
        contains('android-universal'),
      );
      expect(
        softwareDownloadFilename(universal, target: target),
        isNot(contains('android-arm64')),
      );
    },
  );
  test(
    'native resolver only calls additive read host method, never old staging context',
    () async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ClientUpdateBridge.channel, (call) async {
            methods.add(call.method);
            return _windows();
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ClientUpdateBridge.channel, null),
      );
      expect((await readSoftwareHostInfo()).architecture, 'x64');
      expect(methods, ['getSoftwareDownloadHost']);
    },
  );
  test('old runner without additive host method leaves CPU unknown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ClientUpdateBridge.channel, (call) async {
          throw MissingPluginException('old runner');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ClientUpdateBridge.channel, null),
    );
    final host = await readSoftwareHostInfo();
    expect(host.architecture, isNull);
    expect(host.suggestedTarget, isNull);
    expect(host.source, 'nativeFallback');
  });
  test('async old owner result cannot publish into the new owner', () async {
    final epoch = NotifierProvider<_HostEpoch, int>(_HostEpoch.new);
    final pending = [
      Completer<SoftwareHostInfo>(),
      Completer<SoftwareHostInfo>(),
    ];
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        authenticatedScopeProvider.overrideWith(
          (ref) => AuthenticatedScope(userId: 'owner-${ref.watch(epoch)}'),
        ),
        apiBaseUrlProvider.overrideWithValue('https://host.test'),
        softwareHostReaderProvider.overrideWithValue(
          () => pending[reads++].future,
        ),
      ],
    );
    addTearDown(container.dispose);
    final seen = <String>[];
    final subscription = container.listen(softwareHostInfoProvider, (
      previous,
      next,
    ) {
      next.whenData((host) => seen.add(host.osLabel));
    });
    addTearDown(subscription.close);
    container.read(epoch.notifier).advance();
    await container.pump();
    pending[0].complete(const SoftwareHostInfo(osLabel: 'old owner'));
    pending[1].complete(const SoftwareHostInfo(osLabel: 'new owner'));
    await container.read(softwareHostInfoProvider.future);
    await container.pump();
    expect(seen, ['new owner']);
  });
  testWidgets('disposed consumer does not apply late host detection', (
    tester,
  ) async {
    final pending = Completer<SoftwareHostInfo>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          apiBaseUrlProvider.overrideWithValue('https://host.test'),
          softwareHostReaderProvider.overrideWithValue(() => pending.future),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) => Text(
              ref.watch(softwareHostInfoProvider).value?.osLabel ?? 'pending',
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(const SoftwareHostInfo(osLabel: 'late'));
    await tester.pump();
    expect(find.text('late'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
