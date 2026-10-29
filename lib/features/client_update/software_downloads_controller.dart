import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/io/file_saver.dart' as files;
import '../../core/network/api_client.dart';
import '../../shared/providers/authenticated_scope_provider.dart';
import 'client_release.dart';
import 'client_package_integrity.dart';
import 'software_download_target.dart';

typedef SoftwareStoreOpener = Future<bool> Function(Uri uri);
Future<bool> _openStore(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

typedef SoftwarePackageSaver =
    Future<String> Function(
      Stream<Uint8List> chunks,
      String filename, {
      required bool Function() stillCurrent,
      required Future<void> Function() verifyScope,
      required int maxBytes,
    });

final softwareDownloadsControllerProvider =
    Provider.autoDispose<SoftwareDownloadsController>((ref) {
      final owner = ref.watch(authenticatedScopeProvider);
      final controller = SoftwareDownloadsController(
        api: ref.watch(apiClientProvider),
        enabled: owner != null,
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// Uses the same authenticated package stream and atomic file saver as other
/// downloads. A completed file is published only after size and SHA verification.
class SoftwareDownloadsController extends ChangeNotifier {
  SoftwareDownloadsController({
    required this.api,
    this.enabled = true,
    this.save = files.saveStream,
    this.openStore = _openStore,
  });

  final ApiClient api;
  final bool enabled;
  final SoftwarePackageSaver save;
  final SoftwareStoreOpener openStore;
  List<ClientRelease> releases = const [];
  bool loading = false;
  bool loaded = false;
  Object? loadError;
  Object? downloadError;
  String? downloadingId;
  String? savedPath;
  bool storeOpened = false;
  double progress = 0;
  bool _disposed = false;
  int _read = 0, _transfer = 0;
  CancelToken? _cancel;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    if (_disposed || !enabled || loading) return;
    final operation = ++_read;
    bool current() => !_disposed && operation == _read;
    loading = true;
    loadError = null;
    _notify();
    try {
      final scope = await api.captureRequestScope(isCurrent: current);
      final list = await scope.run(
        () => api.getList(
          '/client-updates/downloads',
          query: {'allRuntimeFamilies': true, 'allPlatforms': true},
        ),
      );
      await scope.verify();
      if (!current()) return;
      releases = list
          // A download catalog must affirm publication explicitly; legacy
          // update-check responses may retain their existing model defaults.
          .where((json) => json['state'] == 'PUBLISHED')
          .map(ClientRelease.fromJson)
          .where(isSoftwareDownloadRelease)
          .toList(growable: false);
      loaded = true;
    } catch (error) {
      if (current()) loadError = error;
    } finally {
      if (current()) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> download(
    ClientRelease release, {
    SoftwareDownloadTarget? target,
  }) async {
    if (_disposed || !enabled || downloadingId != null) return;
    if (!isSoftwareDownloadRelease(release) ||
        (target != null && !isSoftwareInstallerForTarget(release, target)) ||
        !releases.any(
          (item) =>
              item.id == release.id &&
              item.platform == release.platform &&
              item.installMode == release.installMode &&
              item.packageKind == release.packageKind &&
              item.version == release.version &&
              item.buildNumber == release.buildNumber &&
              item.storeUrl == release.storeUrl &&
              item.runtimeFamily == release.runtimeFamily &&
              item.architecture == release.architecture &&
              item.sha256 == release.sha256 &&
              item.sizeBytes == release.sizeBytes,
        ) ||
        (release.installMode != 'store' &&
            !hasValidClientPackageMetadata(release))) {
      downloadError = const FormatException('安装包信息不完整，请刷新版本列表后重试');
      _notify();
      return;
    }
    final operation = ++_transfer;
    bool current() => !_disposed && operation == _transfer;
    final cancellation = CancelToken();
    _cancel = cancellation;
    downloadingId = release.id;
    savedPath = null;
    storeOpened = false;
    downloadError = null;
    progress = 0;
    _notify();
    try {
      final scope = await api.captureRequestScope(isCurrent: current);
      if (release.installMode == 'store') {
        final uri = release.trustedStoreUri;
        if (uri == null) throw const FormatException('应用商店地址无效');
        await scope.verify();
        if (!current()) return;
        final opened = await openStore(uri);
        await scope.verify();
        if (!opened) throw StateError('无法打开应用商店，请稍后重试');
        if (current()) storeOpened = true;
        return;
      }
      final stream = await scope.run(
        () => api.getPackageStream(
          release.packagePath,
          cancelToken: cancellation,
        ),
      );
      final digest = _PackageDigest();
      final hashing = sha256.startChunkedConversion(digest);
      Stream<Uint8List> verified() async* {
        var received = 0;
        try {
          await for (final chunk in stream) {
            if (!current()) throw StateError('下载已取消');
            received += chunk.length;
            requireClientPackageLength(release, received);
            hashing.add(chunk);
            progress = received / release.sizeBytes;
            _notify();
            yield chunk;
          }
        } finally {
          hashing.close();
        }
        requireClientPackageLength(release, received, complete: true);
        requireClientPackageDigest(release, digest.value?.toString() ?? '');
        await scope.verify();
      }

      final path = await save(
        verified(),
        softwareDownloadFilename(release, target: target),
        stillCurrent: current,
        verifyScope: scope.verify,
        maxBytes: maxClientPackageBytes,
      );
      if (current()) savedPath = path;
    } catch (error) {
      if (current()) downloadError = error;
    } finally {
      if (current()) {
        _cancel = null;
        downloadingId = null;
        _notify();
      }
    }
  }

  void cancelDownload() {
    ++_transfer;
    _cancel?.cancel('Software download cancelled');
    _cancel = null;
    downloadingId = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_read;
    ++_transfer;
    _cancel?.cancel('Software download owner retired');
    super.dispose();
  }
}

class _PackageDigest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
