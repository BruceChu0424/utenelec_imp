import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/software_downloads_controller.dart';
import 'package:uten_imp/features/client_update/software_download_target.dart';

import '../../support/software_downloads_fixture.dart';

void main() {
  test(
    'Android APK uses the verified stream and explicit target filename',
    () async {
      final transport = SoftwareDownloadsTransport();
      transport.releases = [
        transport.installer(
          platform: 'android',
          architecture: 'arm64',
          mode: 'android_package',
          kind: 'update',
        )..['fileName'] = 'uten-android.apk',
      ];
      final saver = SoftwarePackageSaveFixture();
      final controller = SoftwareDownloadsController(
        api: transport.api,
        save: saver.save,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(transport.requests.first.queryParameters['allPlatforms'], true);
      expect(
        transport.requests.first.queryParameters['allRuntimeFamilies'],
        true,
      );
      await controller.download(
        controller.releases.single,
        target: const SoftwareDownloadTarget(
          platform: SoftwareDownloadPlatform.android,
          architecture: 'arm64',
        ),
      );
      expect(saver.published.single, transport.bytes);
      expect(saver.filenames.single, endsWith('android-arm64-setup.apk'));
      expect(controller.downloadError, isNull);
    },
  );

  test(
    'official store opens its trusted URL without a binary or file save',
    () async {
      final transport = SoftwareDownloadsTransport();
      transport.releases = [
        transport.installer(
          platform: 'ios',
          architecture: 'arm64',
          mode: 'store',
        )..['storeUrl'] = 'https://apps.apple.com/cn/app/fixture/id123456789',
      ];
      final saver = SoftwarePackageSaveFixture();
      final opened = <Uri>[];
      final controller = SoftwareDownloadsController(
        api: transport.api,
        save: saver.save,
        openStore: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.download(controller.releases.single);
      expect(opened.single.host, 'apps.apple.com');
      expect(controller.storeOpened, true);
      expect(controller.savedPath, isNull);
      expect(saver.attempts, 0);
      expect(transport.requests, hasLength(1));
    },
  );

  test('an unsupported store URL is excluded rather than forwarded', () async {
    final transport = SoftwareDownloadsTransport();
    transport.releases = [
      transport.installer(platform: 'ios', architecture: 'arm64', mode: 'store')
        ..['storeUrl'] = 'https://apps.apple.com.evil.test/app/fixture',
    ];
    final controller = SoftwareDownloadsController(api: transport.api);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.releases, isEmpty);
  });

  test(
    'same ID with forged target, version or store metadata cannot download',
    () async {
      final transport = SoftwareDownloadsTransport();
      final controller = SoftwareDownloadsController(api: transport.api);
      addTearDown(controller.dispose);
      await controller.load();
      for (final field in [
        'platform',
        'installMode',
        'version',
        'buildNumber',
        'storeUrl',
      ]) {
        final json = transport.installer();
        json[field] = field == 'buildNumber' ? 9999 : 'forged';
        await controller.download(ClientRelease.fromJson(json));
        expect(controller.downloadError, isNotNull, reason: field);
      }
      await controller.download(
        controller.releases.single,
        target: const SoftwareDownloadTarget(
          platform: SoftwareDownloadPlatform.windows,
          runtimeFamily: ClientRuntimeFamily.wpfLegacy,
          architecture: 'x64',
        ),
      );
      expect(controller.downloadError, isNotNull);
      expect(transport.requests, hasLength(1));
    },
  );
}
