import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/software_downloads_controller.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../support/software_downloads_fixture.dart';

void main() {
  test(
    'only published complete Windows installers enter the download catalog',
    () async {
      final transport = SoftwareDownloadsTransport();
      transport.releases = [
        transport.installer(),
        transport.installer(platform: 'android'),
        transport.installer(platform: 'ios', mode: 'store'),
        transport.installer(platform: 'macos', mode: 'store'),
        transport.installer(kind: 'update', mode: 'windows_archive'),
        transport.installer()..remove('packageKind'),
        transport.installer(mode: 'windows_archive'),
        transport.installer(state: 'DRAFT'),
        transport.installer(state: 'WITHDRAWN'),
      ];
      final controller = SoftwareDownloadsController(api: transport.api);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.loaded, isTrue);
      expect(controller.loadError, isNull);
      expect(controller.releases, hasLength(1));
      expect(controller.releases.single.isWindowsInstaller, isTrue);
      expect(transport.requests.single.path, '/client-updates/downloads');
    },
  );

  test('a Windows installer never qualifies as an in-place update', () {
    final transport = SoftwareDownloadsTransport();
    final installer = ClientRelease.fromJson(transport.installer());
    expect(
      installer.matches(
        const ClientInstallContext(
          platform: 'windows',
          architecture: 'x64',
          currentVersion: '2.5.31',
          currentBuild: 2531,
        ),
      ),
      isFalse,
    );
    final legacy = ClientRelease.fromJson(
      transport.installer(kind: 'update', mode: 'windows_archive')
        ..remove('packageKind'),
    );
    expect(legacy.packageKind, 'update');
    expect(legacy.isWindowsInstaller, isFalse);
  });

  test(
    'empty catalog, initial failure, and failed refresh preserve distinct states',
    () async {
      final transport = SoftwareDownloadsTransport()..releases = [];
      final controller = SoftwareDownloadsController(api: transport.api);
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.loaded, isTrue);
      expect(controller.loadError, isNull);
      expect(controller.releases, isEmpty);
      transport.releases = [transport.installer()];
      await controller.load();
      expect(controller.releases, hasLength(1));
      transport.listStatus = 503;
      await controller.load();
      expect(controller.loadError, isNotNull);
      expect(controller.releases, hasLength(1));
      expect(controller.loading, isFalse);
      final fresh = SoftwareDownloadsController(api: transport.api);
      addTearDown(fresh.dispose);
      await fresh.load();
      expect(fresh.loaded, isFalse);
      expect(fresh.loadError, isNotNull);
      expect(fresh.releases, isEmpty);
    },
  );

  test(
    'real API parsing and verified stream publish the exact installer bytes once',
    () async {
      final transport = SoftwareDownloadsTransport();
      final saver = SoftwarePackageSaveFixture();
      final controller = SoftwareDownloadsController(
        api: transport.api,
        save: saver.save,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.download(controller.releases.single);
      expect(saver.published.single, transport.bytes);
      expect(saver.filenames.single, endsWith('windows10-11-x64-setup.exe'));
      expect(
        controller.savedPath,
        'fixture-downloads/${saver.filenames.single}',
      );
      expect(controller.downloadError, isNull);
      expect(controller.progress, 1);
      expect(controller.downloadingId, isNull);
      expect(
        transport.requests.last.path,
        '/client-updates/${SoftwareDownloadsTransport.x64Id}/download',
      );
      expect(transport.requests.last.followRedirects, isFalse);
    },
  );

  for (final problem in ['hash', 'truncated', 'oversize', 'network', 'save']) {
    test('$problem failure never publishes a partial installer', () async {
      final transport = SoftwareDownloadsTransport();
      final saver = SoftwarePackageSaveFixture();
      if (problem == 'hash') {
        transport.streamFactory = () =>
            Stream.value(Uint8List(transport.bytes.length));
      } else if (problem == 'truncated') {
        transport.streamFactory = () =>
            Stream.value(Uint8List.sublistView(transport.bytes, 1));
      } else if (problem == 'oversize') {
        transport.streamFactory = () =>
            Stream.value(Uint8List(transport.bytes.length + 1));
      } else if (problem == 'network') {
        transport.packageStatus = 503;
      } else {
        saver.failure = StateError('Fixture destination unavailable');
      }
      final controller = SoftwareDownloadsController(
        api: transport.api,
        save: saver.save,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.download(controller.releases.single);
      expect(saver.published, isEmpty);
      expect(controller.savedPath, isNull);
      expect(controller.downloadError, isNotNull);
      expect(controller.downloadingId, isNull);
    });
  }

  test(
    'a foreign release or incomplete metadata never starts a network download',
    () async {
      final transport = SoftwareDownloadsTransport();
      final saver = SoftwarePackageSaveFixture();
      final controller = SoftwareDownloadsController(
        api: transport.api,
        save: saver.save,
      );
      addTearDown(controller.dispose);
      await controller.load();
      for (final metadata in [
        transport.installer(id: SoftwareDownloadsTransport.arm64Id),
        transport.installer(kind: 'update', mode: 'windows_archive'),
        transport.installer()..['sizeBytes'] = 0,
        transport.installer()..['sha256'] = 'invalid',
      ]) {
        await controller.download(ClientRelease.fromJson(metadata));
        expect(controller.downloadError, isNotNull);
      }
      expect(transport.requests, hasLength(1));
      expect(saver.attempts, 0);
    },
  );

  test(
    'cancelled downloads do not publish and can be explicitly retried',
    () async {
      final transport = SoftwareDownloadsTransport();
      final chunks = StreamController<Uint8List>();
      transport.streamFactory = () => chunks.stream;
      final saver = SoftwarePackageSaveFixture();
      final controller = SoftwareDownloadsController(
        api: transport.api,
        save: saver.save,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final release = controller.releases.single;
      final pending = controller.download(release);
      await transport.packageRequested.future;
      await Future<void>.delayed(Duration.zero);
      await controller.download(release);
      expect(
        transport.requests.where(
          (request) => request.path.endsWith('/download'),
        ),
        hasLength(1),
      );
      controller.cancelDownload();
      chunks.add(transport.bytes);
      await chunks.close();
      await pending;
      expect(saver.published, isEmpty);
      expect(controller.savedPath, isNull);
      expect(controller.downloadingId, isNull);
      expect(transport.cancellationObserved, isTrue);
      transport.streamFactory = null;
      await controller.download(release);
      expect(saver.published.single, transport.bytes);
      expect(controller.downloadError, isNull);
    },
  );

  test('retired owners cannot accept a delayed catalog result', () async {
    final transport = SoftwareDownloadsTransport()
      ..delayedList = Completer<ResponseBody>();
    final controller = SoftwareDownloadsController(api: transport.api);
    final pending = controller.load();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    transport.delayedList!.complete(
      ResponseBody.fromString(
        jsonEncode(transport.releases),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    await pending;
    expect(controller.loaded, isFalse);
    expect(controller.releases, isEmpty);
  });

  test(
    'logout retires the real provider controller and its pending request',
    () async {
      final transport = SoftwareDownloadsTransport()
        ..delayedList = Completer<ResponseBody>();
      final owner = StateProvider<AuthenticatedScope?>(
        (_) => const AuthenticatedScope(userId: 'employee-a'),
      );
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(transport.api),
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(owner)),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        softwareDownloadsControllerProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      final previous = container.read(softwareDownloadsControllerProvider);
      final pending = previous.load();
      await Future<void>.delayed(Duration.zero);
      container.read(owner.notifier).state = null;
      await container.pump();
      final next = container.read(softwareDownloadsControllerProvider);
      expect(next, isNot(same(previous)));
      transport.delayedList!.complete(
        ResponseBody.fromString(
          jsonEncode(transport.releases),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await pending;
      await next.load();
      expect(previous.releases, isEmpty);
      expect(next.releases, isEmpty);
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'disposing a download retires its stream before the save boundary',
    () async {
      final transport = SoftwareDownloadsTransport();
      final chunks = StreamController<Uint8List>();
      transport.streamFactory = () => chunks.stream;
      final saver = SoftwarePackageSaveFixture();
      final controller = SoftwareDownloadsController(
        api: transport.api,
        save: saver.save,
      );
      await controller.load();
      final pending = controller.download(controller.releases.single);
      await transport.packageRequested.future;
      controller.dispose();
      chunks.add(transport.bytes);
      await chunks.close();
      await pending;
      expect(saver.published, isEmpty);
      expect(controller.savedPath, isNull);
      expect(transport.cancellationObserved, isTrue);
    },
  );

  test(
    'switching the real API provider rejects a prior server catalog',
    () async {
      final previousTransport = SoftwareDownloadsTransport()
        ..delayedList = Completer<ResponseBody>();
      final nextTransport = SoftwareDownloadsTransport()..releases = [];
      final endpoint = StateProvider<ApiClient>((_) => previousTransport.api);
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWith((ref) => ref.watch(endpoint)),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'employee-a'),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        softwareDownloadsControllerProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      final previous = container.read(softwareDownloadsControllerProvider);
      final pending = previous.load();
      await Future<void>.delayed(Duration.zero);
      container.read(endpoint.notifier).state = nextTransport.api;
      await container.pump();
      final next = container.read(softwareDownloadsControllerProvider);
      expect(next, isNot(same(previous)));
      await next.load();
      previousTransport.delayedList!.complete(
        ResponseBody.fromString(
          jsonEncode(previousTransport.releases),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await pending;
      expect(previous.releases, isEmpty);
      expect(next.loaded, isTrue);
      expect(next.releases, isEmpty);
    },
  );
}
