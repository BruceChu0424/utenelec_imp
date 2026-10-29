import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_update_bridge.dart';
import 'package:uten_imp/features/client_update/client_update_controller.dart';
import 'package:uten_imp/features/client_update/software_downloads_controller.dart';
import 'package:uten_imp/features/client_update/software_downloads_presentation.dart';

import '../../support/software_downloads_fixture.dart';

Map<String, dynamic> _legacy(
  SoftwareDownloadsTransport transport, {
  String architecture = 'x64',
  String state = 'PUBLISHED',
}) => transport.installer(
  id: SoftwareDownloadsTransport.arm64Id,
  architecture: architecture,
  mode: 'windows_wpf_setup',
  state: state,
)..['runtimeFamily'] = ClientRuntimeFamily.wpfLegacy;

class _InstalledBridge extends ClientUpdateBridge {
  @override
  Future<ClientInstallContext> context() async => const ClientInstallContext(
    platform: 'windows',
    architecture: 'x64',
    currentVersion: '2.5.31',
    currentBuild: 2531,
    supportsInPlaceUpdate: true,
  );
}

class _UpdateApi extends ApiClient {
  _UpdateApi(this.candidate)
    : super(Dio(BaseOptions(baseUrl: 'https://fixture.test/api')));
  Map<String, dynamic> candidate;
  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/client-updates/check');
    lastQuery = query;
    return {'updateAvailable': true, 'release': candidate};
  }
}

void main() {
  test(
    'old records and installed contexts default to the existing Flutter family',
    () {
      final transport = SoftwareDownloadsTransport();
      final old = ClientRelease.fromJson(transport.installer());
      final nullField = ClientRelease.fromJson(
        transport.installer()..['runtimeFamily'] = null,
      );
      expect(old.runtimeFamily, ClientRuntimeFamily.flutter);
      expect(nullField.runtimeFamily, ClientRuntimeFamily.flutter);
      expect(old.packagePath, '/client-updates/${old.id}/download');
      expect(
        const ClientInstallContext(
          platform: 'windows',
          architecture: 'x64',
          currentVersion: '2.5.31',
          currentBuild: 2531,
        ).runtimeFamily,
        ClientRuntimeFamily.flutter,
      );
    },
  );

  test(
    'one architecture cannot select a package from the other runtime or architecture',
    () {
      final transport = SoftwareDownloadsTransport();
      final flutter = ClientRelease.fromJson(transport.installer());
      final legacy = ClientRelease.fromJson(_legacy(transport));
      final releases = [legacy, flutter];
      expect(
        selectWindowsInstaller(
          releases,
          runtimeFamily: ClientRuntimeFamily.flutter,
          architecture: 'x64',
        ),
        same(flutter),
      );
      expect(
        selectWindowsInstaller(
          releases,
          runtimeFamily: ClientRuntimeFamily.wpfLegacy,
          architecture: 'x64',
        ),
        same(legacy),
      );
      expect(
        selectWindowsInstaller(
          releases,
          runtimeFamily: ClientRuntimeFamily.wpfLegacy,
          architecture: 'x86',
        ),
        isNull,
      );
      expect(windowsDownloadArchitectures(ClientRuntimeFamily.wpfLegacy), [
        'x64',
        'x86',
      ]);
    },
  );

  test(
    'WPF mode, architecture and publication must agree before a download is offered',
    () {
      final transport = SoftwareDownloadsTransport();
      for (final invalid in [
        _legacy(transport, state: 'DRAFT'),
        _legacy(transport, state: 'WITHDRAWN'),
        _legacy(transport, architecture: 'arm64'),
        _legacy(transport)..['installMode'] = 'windows_setup',
        _legacy(transport)..['runtimeFamily'] = 'unreviewed-runtime',
      ]) {
        expect(ClientRelease.fromJson(invalid).isWindowsInstaller, isFalse);
      }
      expect(
        ClientRelease.fromJson(_legacy(transport)).isWindowsInstaller,
        isTrue,
      );
    },
  );

  test(
    'legacy browser hints select the compatibility family without changing modern defaults',
    () {
      for (final version in ['6.1', '6.3']) {
        expect(
          initialWindowsRuntimeFamily(
            'Mozilla/5.0 (Windows NT $version; Win64; x64)',
          ),
          ClientRuntimeFamily.wpfLegacy,
        );
      }
      for (final agent in [
        null,
        'Windows NT 10.0',
        'Macintosh',
        'Windows NT 6.2',
      ]) {
        expect(initialWindowsRuntimeFamily(agent), ClientRuntimeFamily.flutter);
      }
    },
  );

  test(
    'download catalog asks for both families but excludes unpublished and invalid packages',
    () async {
      final transport = SoftwareDownloadsTransport();
      transport.releases = [
        transport.installer(),
        _legacy(transport),
        _legacy(transport, state: 'DRAFT'),
        _legacy(transport)..['sha256'] = '',
        _legacy(transport)..remove('state'),
      ];
      final controller = SoftwareDownloadsController(api: transport.api);
      addTearDown(controller.dispose);
      await controller.load();
      expect(transport.requests.single.queryParameters, {
        'allRuntimeFamilies': true,
        'allPlatforms': true,
      });
      expect(controller.releases.map((release) => release.runtimeFamily), [
        ClientRuntimeFamily.flutter,
        ClientRuntimeFamily.wpfLegacy,
      ]);
    },
  );

  test(
    'WPF verified download retains the runtime selector on the authenticated request',
    () async {
      final transport = SoftwareDownloadsTransport()..releases = [];
      transport.releases.add(_legacy(transport));
      final saver = SoftwarePackageSaveFixture();
      final controller = SoftwareDownloadsController(
        api: transport.api,
        save: saver.save,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(
        controller.releases.single.packagePath,
        endsWith('?runtimeFamily=wpf_legacy'),
      );
      await controller.download(controller.releases.single);
      expect(controller.downloadError, isNull);
      expect(saver.published.single, transport.bytes);
      expect(transport.requests.last.queryParameters, {
        'runtimeFamily': 'wpf_legacy',
      });
      expect(transport.requests.last.followRedirects, isFalse);
    },
  );

  test(
    'native automatic checks keep the old default request and reject a returned WPF update',
    () async {
      final transport = SoftwareDownloadsTransport();
      final api = _UpdateApi(
        _legacy(transport)
          ..['packageKind'] = 'update'
          ..['installMode'] = 'windows_wpf_archive',
      );
      final controller = ClientUpdateController(
        api: api,
        bridge: _InstalledBridge(),
      );
      addTearDown(controller.dispose);
      await controller.check();
      expect(api.lastQuery, {
        'platform': 'windows',
        'architecture': 'x64',
        'currentBuildNumber': 2531,
      });
      expect(controller.release, isNull);
      expect(controller.stage, ClientUpdateStage.idle);
      api.candidate = transport.installer(
        kind: 'update',
        mode: 'windows_archive',
      );
      await controller.check();
      expect(controller.release?.runtimeFamily, ClientRuntimeFamily.flutter);
      expect(controller.stage, ClientUpdateStage.available);
    },
  );
}
