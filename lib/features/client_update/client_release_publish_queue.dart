import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/performance/ui_work_budget.dart';
import '../../shared/drafts/form_draft.dart';
import 'client_package_integrity.dart';
import 'client_release.dart';

enum ClientReleaseQueueStage {
  needsFile,
  ready,
  validating,
  prepared,
  uploading,
  uploaded,
  publishing,
  published,
  withdrawn,
  rejected,
  unknown,
}

enum ClientReleaseQueueOperation { prepare, upload, publish }

enum ClientReleaseWithdrawState { sending, unknown, ready, confirmed }

/// Admin receipts must state their lifecycle explicitly. The global update
/// model keeps its historical default for existing update-check responses.
ClientRelease _parseAdminRecord(Map<String, dynamic> json) {
  if (!const {'DRAFT', 'PUBLISHED', 'WITHDRAWN'}.contains(json['state'])) {
    throw const FormatException('服务器管理记录缺少明确有效的发布状态，原记录已保留');
  }
  return ClientRelease.fromJson(json);
}

@immutable
class ClientReleasePublishMetadata {
  const ClientReleasePublishMetadata({
    this.platform = 'windows',
    this.runtimeFamily = ClientRuntimeFamily.flutter,
    this.architecture = 'x64',
    this.packageKind = 'update',
    this.version = '',
    this.buildNumber = '',
    this.releaseNotes = '',
    this.storeUrl = '',
  });
  final String platform, runtimeFamily, architecture, packageKind;
  final String version, buildNumber, releaseNotes, storeUrl;
  bool get isStore =>
      const {'ios', 'macos'}.contains(platform) || storeUrl.isNotEmpty;
  String get groupKey =>
      '$platform/$runtimeFamily/$architecture/$version/$buildNumber';
  String get kindKey => '$groupKey/$packageKind';
  String? get validationError {
    if (!const {'windows', 'android', 'ios', 'macos'}.contains(platform)) {
      return '此平台尚未提供发布服务。';
    }
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      return '版本号使用三段数字，例如 2.5.34。';
    }
    final number = int.tryParse(buildNumber);
    if (number == null || number <= 0 || number > 2147483647) {
      return '请填写有效的构建号。';
    }
    if (platform == 'windows') {
      if (!ClientRuntimeFamily.supportsWindowsArchitecture(
        runtimeFamily,
        architecture,
      )) {
        return '客户端类型与架构不匹配。';
      }
      if (!const {'installer', 'update'}.contains(packageKind) || isStore) {
        return 'Windows 必须使用安装包或更新 ZIP。';
      }
    } else {
      if (runtimeFamily != ClientRuntimeFamily.flutter ||
          packageKind != 'update') {
        return '该平台不支持此运行时或安装类型。';
      }
      final supported = switch (platform) {
        'android' => const {'arm64', 'armeabi-v7a', 'x64', 'universal'},
        'ios' => const {'arm64', 'universal'},
        'macos' => const {'arm64', 'x64', 'universal'},
        _ => const <String>{},
      };
      if (!supported.contains(architecture)) return '此平台不支持所选架构。';
      if (isStore) {
        final release = ClientRelease(
          id: '',
          platform: platform,
          architecture: architecture,
          version: version,
          buildNumber: number,
          releaseNotes: '',
          installMode: 'store',
          storeUrl: storeUrl,
        );
        if (release.trustedStoreUri == null) return '请填写该平台的官方商店链接。';
      }
    }
    if (releaseNotes.length > 10000) return '发布说明最多 10000 字。';
    return null;
  }

  ClientReleasePublishMetadata copyWith({
    String? platform,
    String? runtimeFamily,
    String? architecture,
    String? packageKind,
    String? version,
    String? buildNumber,
    String? releaseNotes,
    String? storeUrl,
  }) => ClientReleasePublishMetadata(
    platform: platform ?? this.platform,
    runtimeFamily: runtimeFamily ?? this.runtimeFamily,
    architecture: architecture ?? this.architecture,
    packageKind: packageKind ?? this.packageKind,
    version: version ?? this.version,
    buildNumber: buildNumber ?? this.buildNumber,
    releaseNotes: releaseNotes ?? this.releaseNotes,
    storeUrl: storeUrl ?? this.storeUrl,
  );
  Map<String, dynamic> toJson() => {
    'platform': platform,
    'runtimeFamily': runtimeFamily,
    'architecture': architecture,
    'packageKind': packageKind,
    'version': version,
    'buildNumber': buildNumber,
    'releaseNotes': releaseNotes,
    'storeUrl': storeUrl,
  };
  factory ClientReleasePublishMetadata.fromJson(Map<String, dynamic> json) =>
      ClientReleasePublishMetadata(
        platform: json['platform'] as String,
        runtimeFamily:
            json['runtimeFamily'] as String? ?? ClientRuntimeFamily.flutter,
        architecture: json['architecture'] as String,
        packageKind: json['packageKind'] as String? ?? 'update',
        version: json['version'] as String? ?? '',
        buildNumber: json['buildNumber']?.toString() ?? '',
        releaseNotes: json['releaseNotes'] as String? ?? '',
        storeUrl: json['storeUrl'] as String? ?? '',
      );
}

/// Picker content stays lazy and is never part of a durable draft.
class ClientReleasePickedFile {
  ClientReleasePickedFile({
    required this.name,
    required this.size,
    required this._openRead,
  });
  factory ClientReleasePickedFile.bytes(String name, Uint8List bytes) {
    final owned = Uint8List.fromList(bytes);
    return ClientReleasePickedFile(
      name: name,
      size: owned.length,
      openRead: () => Stream.value(owned),
    );
  }
  final String name;
  final int size;
  final Stream<List<int>> Function() _openRead;
  Stream<List<int>> openRead() => _openRead();
}

class ClientReleaseQueueItem {
  ClientReleaseQueueItem({
    required this.localId,
    required this._metadata,
    this.file,
  }) : fileName = file?.name,
       sizeBytes = file?.size ?? 0;
  final String localId;
  ClientReleasePublishMetadata _metadata;
  ClientReleasePublishMetadata get metadata => _metadata;
  ClientReleasePickedFile? file;
  String? fileName, requestId, sha256, releaseId, error;
  int sizeBytes;
  ClientReleaseQueueStage stage = ClientReleaseQueueStage.ready;
  ClientReleaseQueueOperation? pendingOperation;
  double progress = 0;
  ClientRelease? publishedRelease;
  bool retentionPending = false;
  bool publishAcknowledged = false;
  bool _dispatched = false;
  bool get frozen => requestId != null;
  bool get uncertain =>
      stage == ClientReleaseQueueStage.unknown || pendingOperation != null;
  bool get published => stage == ClientReleaseQueueStage.published;
  bool get terminal => published || stage == ClientReleaseQueueStage.withdrawn;
  bool get needsFile =>
      !metadata.isStore &&
      file == null &&
      const {
        ClientReleaseQueueStage.needsFile,
        ClientReleaseQueueStage.ready,
        ClientReleaseQueueStage.validating,
        ClientReleaseQueueStage.prepared,
        ClientReleaseQueueStage.rejected,
      }.contains(stage);
  Map<String, dynamic> toDraft() => {
    'localId': localId,
    'metadata': metadata.toJson(),
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'requestId': requestId,
    'sha256': sha256,
    'releaseId': releaseId,
    'stage': stage.name,
    'pendingOperation': pendingOperation?.name,
    'retentionPending': retentionPending,
    'publishAcknowledged': publishAcknowledged,
    // Error text and bytes/path/credentials are deliberately not retained.
  };
  factory ClientReleaseQueueItem.restore(Map<String, dynamic> json) {
    final item = ClientReleaseQueueItem(
      localId: json['localId'] as String,
      metadata: ClientReleasePublishMetadata.fromJson(
        Map<String, dynamic>.from(json['metadata'] as Map),
      ),
    );
    item.fileName = json['fileName'] as String?;
    item.sizeBytes = json['sizeBytes'] as int? ?? 0;
    item.requestId = json['requestId'] as String?;
    item.sha256 = json['sha256'] as String?;
    item.releaseId = json['releaseId'] as String?;
    item.retentionPending = json['retentionPending'] == true;
    item.publishAcknowledged = json['publishAcknowledged'] == true;
    for (final id in [item.requestId, item.releaseId].whereType<String>()) {
      ClientReleasePublishQueue.requireId(id);
    }
    item.pendingOperation = json['pendingOperation'] == null
        ? null
        : ClientReleaseQueueOperation.values.byName(
            json['pendingOperation'] as String,
          );
    final stored = ClientReleaseQueueStage.values.byName(
      json['stage'] as String,
    );
    if (stored == ClientReleaseQueueStage.published) {
      item.pendingOperation = ClientReleaseQueueOperation.publish;
    }
    item.stage = item.pendingOperation != null
        ? ClientReleaseQueueStage.unknown
        : const {
            ClientReleaseQueueStage.validating,
            ClientReleaseQueueStage.uploading,
            ClientReleaseQueueStage.publishing,
          }.contains(stored)
        ? ClientReleaseQueueStage.unknown
        : stored;
    if (item.requestId == null && !item.metadata.isStore) {
      item.stage = ClientReleaseQueueStage.needsFile;
    }
    return item;
  }
}

abstract interface class ClientReleasePublishGateway {
  Future<void> begin(bool Function() isCurrent);
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> body);
  Future<void> upload(
    String id,
    Uint8List bytes,
    void Function(int, int) onProgress,
  );
  Future<Map<String, dynamic>> publish(String id);
  Future<Map<String, dynamic>> read(String id);
  Future<List<ClientRelease>> list();
  Future<Map<String, dynamic>> withdraw(String id);
}

class ApiClientReleasePublishGateway implements ClientReleasePublishGateway {
  ApiClientReleasePublishGateway(this.api);
  final ApiClient api;
  AuthenticatedRequestScope? _scope;
  @override
  Future<void> begin(bool Function() isCurrent) async {
    _scope = await api.captureRequestScope(isCurrent: isCurrent);
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final scope = _scope;
    if (scope == null) throw StateError('尚未绑定本次发布身份');
    return scope.run(action);
  }

  @override
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> body) =>
      _run(() => api.post('/admin/client-releases', body: body));
  @override
  Future<void> upload(
    String id,
    Uint8List bytes,
    void Function(int, int) progress,
  ) => _run(
    () => api.uploadClientPackage(
      '/admin/client-releases/$id/package',
      bytes,
      onProgress: progress,
    ),
  );
  @override
  Future<Map<String, dynamic>> publish(String id) =>
      _run(() => api.post('/admin/client-releases/$id/publish'));
  @override
  Future<Map<String, dynamic>> read(String id) =>
      _run(() => api.get('/admin/client-releases/$id'));
  @override
  Future<Map<String, dynamic>> withdraw(String id) =>
      _run(() => api.post('/admin/client-releases/$id/withdraw'));
  @override
  Future<List<ClientRelease>> list() async => (await _run(
    () => api.getList('/admin/client-releases'),
  )).map(_parseAdminRecord).toList(growable: false);
}

typedef ClientReleaseQueueCheckpoint =
    Future<void> Function(Map<String, dynamic> snapshot);

class ClientReleasePublishQueue extends ChangeNotifier {
  ClientReleasePublishQueue({
    required this.gateway,
    required bool Function() isCurrent,
    required this.checkpoint,
  }) : _ownerCurrent = isCurrent;
  static const maximumFiles = 100;
  final ClientReleasePublishGateway gateway;
  final bool Function() _ownerCurrent;
  final ClientReleaseQueueCheckpoint checkpoint;
  final List<ClientReleaseQueueItem> _items = [];
  final Map<String, ClientReleaseWithdrawState> withdrawals = {};
  List<ClientReleaseQueueItem> get items => List.unmodifiable(_items);
  List<ClientRelease> releases = [];
  bool busy = false, retired = false, _disposed = false;
  StreamIterator<List<int>>? _reader;
  bool get current => !_disposed && !retired && _ownerCurrent();
  bool get hasUnknown =>
      _items.any((item) => item.uncertain) ||
      withdrawals.values.any(
        (state) =>
            state == ClientReleaseWithdrawState.sending ||
            state == ClientReleaseWithdrawState.unknown,
      );
  bool get hasWork => _items.any((item) => !item.terminal);
  int get confirmedCount => _items.where((item) => item.published).length;
  String? error;
  Map<String, dynamic> snapshot() => {
    'schemaVersion': 1,
    'rows': _items.map((item) => item.toDraft()).toList(),
    'withdrawals': [
      for (final entry in withdrawals.entries)
        {'id': entry.key, 'state': entry.value.name},
    ],
    formDraftUnknownSubmissionKey: hasUnknown,
  };
  void restore(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 || json['rows'] is! List) {
      throw const FormatException('发布草稿格式不受支持');
    }
    final rows = (json['rows'] as List)
        .map(
          (row) => ClientReleaseQueueItem.restore(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList();
    if (rows.length > maximumFiles ||
        rows.map((item) => item.localId).toSet().length != rows.length) {
      throw const FormatException('发布队列无效');
    }
    _items
      ..clear()
      ..addAll(rows);
    withdrawals.clear();
    for (final raw in json['withdrawals'] as List? ?? const []) {
      final row = Map<String, dynamic>.from(raw as Map);
      final id = row['id'] as String;
      requireId(id);
      final state = ClientReleaseWithdrawState.values.byName(
        row['state'] as String,
      );
      withdrawals[id] = state == ClientReleaseWithdrawState.sending
          ? ClientReleaseWithdrawState.unknown
          : state;
    }
    _notify();
  }

  void addFiles(
    Iterable<ClientReleasePickedFile> files,
    ClientReleasePublishMetadata defaults,
  ) {
    if (!current || busy) return;
    final selected = files.toList(growable: false);
    if (_items.length + selected.length > maximumFiles) {
      throw StateError('一个发布队列最多100项，请分批添加；原队列未变更。');
    }
    for (final file in selected) {
      if (file.size <= 0 || file.size > maxClientPackageBytes) {
        throw StateError('文件必须非空且不超过512 MiB；原队列未变更。');
      }
    }
    for (final file in selected) {
      // Only a visible format hint; target authority comes from server inspection.
      final extension = file.name.split('.').last.toLowerCase();
      final kind = defaults.platform == 'windows'
          ? extension == 'exe'
                ? 'installer'
                : extension == 'zip'
                ? 'update'
                : defaults.packageKind
          : defaults.packageKind;
      _items.add(
        ClientReleaseQueueItem(
          localId: const Uuid().v4(),
          metadata: defaults.copyWith(packageKind: kind),
          file: file,
        ),
      );
    }
    _notify();
  }

  void addStore(ClientReleasePublishMetadata metadata) {
    if (!current || busy) return;
    if (_items.length >= maximumFiles) throw StateError('发布队列已满。');
    _items.add(
      ClientReleaseQueueItem(localId: const Uuid().v4(), metadata: metadata),
    );
    _notify();
  }

  void edit(
    ClientReleaseQueueItem item,
    ClientReleasePublishMetadata metadata,
  ) {
    if (!current || busy || item.frozen || !_items.contains(item)) return;
    item._metadata = metadata;
    item.error = null;
    item.stage = item.file == null && !metadata.isStore
        ? ClientReleaseQueueStage.needsFile
        : ClientReleaseQueueStage.ready;
    _notify();
  }

  void replaceFile(ClientReleaseQueueItem item, ClientReleasePickedFile file) {
    if (!current ||
        busy ||
        item.terminal ||
        item.uncertain ||
        !_items.contains(item)) {
      return;
    }
    if (file.size <= 0 || file.size > maxClientPackageBytes) {
      throw StateError('文件必须非空且不超过512 MiB。');
    }
    item.file = file;
    if (!item.frozen) {
      item.fileName = file.name;
      item.sizeBytes = file.size;
    }
    item.error = null;
    _notify();
  }

  void remove(ClientReleaseQueueItem item) {
    if (!current ||
        busy ||
        item.uncertain ||
        item.published ||
        item.frozen &&
            !const {
              ClientReleaseQueueStage.rejected,
              ClientReleaseQueueStage.withdrawn,
            }.contains(item.stage)) {
      return;
    }
    _items.remove(item);
    _notify();
  }

  Future<void> load() async {
    if (!current) return;
    await gateway.begin(() => current);
    final records = await gateway.list();
    if (current) {
      releases = records;
      _notify();
    }
  }

  Future<void> _save() => checkpoint(snapshot());
  Map<String, dynamic> _body(ClientReleaseQueueItem item) {
    final metadata = item.metadata;
    return {
      'requestId': item.requestId,
      'platform': metadata.platform,
      'architecture': metadata.architecture,
      if (metadata.runtimeFamily != ClientRuntimeFamily.flutter)
        'runtimeFamily': metadata.runtimeFamily,
      'version': metadata.version,
      'buildNumber': int.parse(metadata.buildNumber),
      'releaseNotes': metadata.releaseNotes.trim(),
      'mandatory': false,
      'packageKind': metadata.packageKind,
      if (metadata.isStore)
        'storeUrl': metadata.storeUrl.trim()
      else ...{
        'fileName': item.fileName,
        'expectedSha256': item.sha256,
      },
    };
  }

  ClientRelease _validateRecord(
    ClientReleaseQueueItem item,
    Map<String, dynamic> json,
  ) {
    final record = _parseAdminRecord(json), metadata = item.metadata;
    if (record.id != item.requestId ||
        record.platform != metadata.platform ||
        record.runtimeFamily != metadata.runtimeFamily ||
        record.architecture != metadata.architecture ||
        record.packageKind != metadata.packageKind ||
        record.version != metadata.version ||
        record.buildNumber != int.parse(metadata.buildNumber) ||
        record.releaseNotes != metadata.releaseNotes.trim() ||
        record.mandatory) {
      throw const FormatException('服务器返回的发布目标与本项目不一致，原编号已保留');
    }
    final expectedMode = metadata.isStore
        ? 'store'
        : metadata.platform == 'android'
        ? 'android_package'
        : metadata.runtimeFamily == ClientRuntimeFamily.wpfLegacy
        ? metadata.packageKind == 'installer'
              ? 'windows_wpf_setup'
              : 'windows_wpf_archive'
        : metadata.packageKind == 'installer'
        ? 'windows_setup'
        : 'windows_archive';
    if (record.installMode != expectedMode ||
        (metadata.isStore
            ? record.trustedStoreUri == null ||
                  record.storeUrl != metadata.storeUrl.trim()
            : record.fileName != item.fileName ||
                  json['expectedSha256'] != item.sha256 ||
                  (record.storeUrl != null && record.storeUrl!.isNotEmpty))) {
      throw const FormatException('服务器返回的包类型、文件或商店链接与原意图不一致，原编号已保留');
    }
    // A published record, and any uploaded DRAFT, must describe the exact bytes.
    if (!metadata.isStore &&
        (record.state == 'PUBLISHED' ||
            record.sha256.isNotEmpty ||
            record.sizeBytes != 0) &&
        (record.sha256 != item.sha256 || record.sizeBytes != item.sizeBytes)) {
      throw const FormatException('服务器记录的文件大小或SHA-256与原文件不一致，原编号已保留');
    }
    if (metadata.platform == 'windows' &&
        json['deliveryContract'] != 'paired_v1') {
      throw StateError('服务器尚未启用同组合双包发布契约，请先升级发布服务。');
    }
    if (metadata.platform == 'android' &&
        !metadata.isStore &&
        json['deliveryContract'] != 'audited_v1') {
      throw StateError('服务器尚未启用APK内容校验，请先升级发布服务。');
    }
    return record;
  }

  Future<({Uint8List bytes, String sha})> _read(
    ClientReleaseQueueItem item,
  ) async {
    final file = item.file;
    if (file == null) throw StateError('请重新选择原文件后继续。');
    final data = BytesBuilder(copy: false), digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    final iterator = StreamIterator(file.openRead());
    _reader = iterator;
    var count = 0;
    final work = UiWorkBudget(
      maxItems: 1,
      isCurrent: () => current,
      debugLabel: 'client-release-file',
    );
    try {
      while (await iterator.moveNext()) {
        if (!current) throw AuthenticatedRequestScope.changed();
        final chunk = Uint8List.fromList(iterator.current);
        count += chunk.length;
        if (count > file.size || count > maxClientPackageBytes) {
          throw const FormatException('文件实际大小与选择结果不一致');
        }
        hash.add(chunk);
        data.add(chunk);
        await work.checkpoint();
      }
      if (count != file.size) throw const FormatException('原文件读取不完整，请重新选择');
      hash.close();
      return (bytes: data.takeBytes(), sha: digest.value!.toString());
    } finally {
      await iterator.cancel();
      if (identical(_reader, iterator)) _reader = null;
    }
  }

  Future<void> run() async {
    if (!current || busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      await gateway.begin(() => current);
      // First prepare/upload all files. Every item keeps its own durable outcome.
      for (final item in _items.toList(growable: false)) {
        if (!current) break;
        if (item.terminal ||
            item.uncertain ||
            item.stage == ClientReleaseQueueStage.uploaded) {
          continue;
        }
        try {
          await _prepareAndUpload(item);
        } catch (failure) {
          await _recordFailure(item, failure);
        }
      }
      for (final item in _items.toList(growable: false)) {
        if (!current) break;
        if (item.stage != ClientReleaseQueueStage.uploaded || item.uncertain) {
          continue;
        }
        try {
          item.stage = ClientReleaseQueueStage.publishing;
          item.pendingOperation = ClientReleaseQueueOperation.publish;
          item._dispatched = false;
          _notify();
          await _save();
          item._dispatched = true;
          final record = _validateRecord(
            item,
            await gateway.publish(item.releaseId!),
          );
          if (!current) break;
          if (record.state != 'PUBLISHED') {
            throw const FormatException('服务器未返回明确的已发布状态');
          }
          item.publishedRelease = record;
          item.stage = ClientReleaseQueueStage.published;
          item.pendingOperation = null;
          item.file = null;
          item.progress = 1;
          item.retentionPending = false;
          item.publishAcknowledged = true;
          await _save();
          _notify();
        } catch (failure) {
          await _recordFailure(item, failure);
        }
      }
      if (current) {
        try {
          releases = await gateway.list();
        } catch (_) {
          error = '发布结果已逐项保留，列表刷新暂未完成。';
        }
      }
    } catch (failure) {
      if (current) error = _message(failure);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _prepareAndUpload(ClientReleaseQueueItem item) async {
    final invalid = item.metadata.validationError;
    if (invalid != null) throw StateError(invalid);
    if (_items.any(
      (other) =>
          !identical(other, item) &&
          other.metadata.kindKey == item.metadata.kindKey &&
          !other.published,
    )) {
      throw StateError('同一组合、版本和包类型存在多个项目，请核对后保留一个。');
    }
    Uint8List? bytes;
    item.error = null;
    if (!item.metadata.isStore) {
      final extension = (item.file?.name ?? item.fileName ?? '')
          .split('.')
          .last
          .toLowerCase();
      final allowed = item.metadata.platform == 'windows'
          ? item.metadata.packageKind == 'installer'
                ? const {'exe'}
                : const {'zip'}
          : const {'apk'};
      if (!allowed.contains(extension)) throw StateError('所选文件格式与声明的目标类型不匹配。');
      item.stage = ClientReleaseQueueStage.validating;
      _notify();
      final loaded = await _read(item);
      bytes = loaded.bytes;
      if (!current) return;
      if (item.sha256 != null && item.sha256 != loaded.sha) {
        throw StateError('重选文件与原提交SHA-256不同，不能替换原发布意图。');
      }
      item.sha256 = loaded.sha;
      item.sizeBytes = bytes.length;
    }
    if (!current) return;
    item.requestId ??= const Uuid().v4();
    item.pendingOperation = ClientReleaseQueueOperation.prepare;
    item._dispatched = false;
    await _save();
    item._dispatched = true;
    final json = await gateway.prepare(_body(item));
    if (!current) return;
    final draft = _validateRecord(item, json);
    item.releaseId = draft.id;
    item.pendingOperation = null;
    if (draft.state == 'WITHDRAWN') {
      item.publishedRelease = draft;
      item.stage = ClientReleaseQueueStage.withdrawn;
      item.retentionPending = false;
      item.file = null;
      await _save();
      return;
    }
    if (draft.state == 'PUBLISHED') {
      item.publishedRelease = draft;
      item.retentionPending =
          item.metadata.platform == 'windows' && !item.publishAcknowledged;
      item.stage = item.retentionPending
          ? ClientReleaseQueueStage.uploaded
          : ClientReleaseQueueStage.published;
      item.file = null;
      await _save();
      return;
    }
    if (!item.metadata.isStore &&
        draft.sha256 == item.sha256 &&
        draft.sizeBytes == item.sizeBytes) {
      item.stage = ClientReleaseQueueStage.uploaded;
      item.file = null;
      await _save();
      return;
    }
    item.stage = ClientReleaseQueueStage.prepared;
    await _save();
    if (!item.metadata.isStore) {
      item.stage = ClientReleaseQueueStage.uploading;
      item.pendingOperation = ClientReleaseQueueOperation.upload;
      item._dispatched = false;
      _notify();
      await _save();
      item._dispatched = true;
      await gateway.upload(draft.id, bytes!, (sent, total) {
        if (current &&
            item.stage == ClientReleaseQueueStage.uploading &&
            total > 0) {
          item.progress = (sent / total).clamp(0, 1);
          _notify();
        }
      });
      if (!current) return;
      final uploaded = _validateRecord(item, await gateway.read(draft.id));
      if (uploaded.sha256 != item.sha256 ||
          uploaded.sizeBytes != item.sizeBytes) {
        throw const FormatException('服务器尚未确认原文件的大小和SHA-256');
      }
    }
    if (!current) return;
    item.pendingOperation = null;
    item.stage = ClientReleaseQueueStage.uploaded;
    item.file = null;
    await _save();
    _notify();
  }

  Future<void> _recordFailure(
    ClientReleaseQueueItem item,
    Object failure,
  ) async {
    // Keep a confirmed publication even when a local checkpoint failed.
    if (!item.published) {
      final definite =
          failure is ApiException &&
          failure.hasResponseCode &&
          (failure.httpStatus ?? 0) >= 400 &&
          (failure.httpStatus ?? 999) < 500;
      item.stage =
          item.pendingOperation != null && item._dispatched && !definite
          ? ClientReleaseQueueStage.unknown
          : item.pendingOperation == ClientReleaseQueueOperation.publish
          ? ClientReleaseQueueStage.uploaded
          : ClientReleaseQueueStage.rejected;
      if (definite || !item._dispatched) item.pendingOperation = null;
    }
    item.error = _message(failure);
    item.file =
        null; // Each browser/native stream is one-shot; reselect only after a read reconciliation.
    try {
      await _save();
    } catch (_) {
      error = '本机草稿尚未保存，请保留此页面并重试保全。';
    }
    _notify();
  }

  Future<void> reconcile(ClientReleaseQueueItem item) async {
    if (!current || busy || item.requestId == null || item.terminal) return;
    busy = true;
    item.error = null;
    _notify();
    try {
      await gateway.begin(() => current);
      final record = _validateRecord(
        item,
        await gateway.read(item.releaseId ?? item.requestId!),
      );
      if (!current) return;
      item.releaseId = record.id;
      if (record.state == 'PUBLISHED') {
        item.publishedRelease = record;
        item.retentionPending =
            item.metadata.platform == 'windows' && !item.publishAcknowledged;
        item.stage = item.retentionPending
            ? ClientReleaseQueueStage.uploaded
            : ClientReleaseQueueStage.published;
        if (item.retentionPending) {
          item.error = '文件已发布，保留检查尚待完成。请明确继续原发布，不会重新创建或上传。';
        }
        item.progress = 1;
        item.file = null;
      } else if (record.state == 'DRAFT') {
        item.stage =
            item.metadata.isStore ||
                record.sha256 == item.sha256 &&
                    record.sizeBytes == item.sizeBytes
            ? ClientReleaseQueueStage.uploaded
            : ClientReleaseQueueStage.prepared;
      } else if (record.state == 'WITHDRAWN') {
        item.publishedRelease = record;
        item.stage = ClientReleaseQueueStage.withdrawn;
        item.retentionPending = false;
        item.file = null;
      } else {
        throw StateError('原发布记录已撤回或状态不匹配，请人工核对，不能复用。');
      }
      item.pendingOperation = null;
      await _save();
    } catch (failure) {
      if (failure is ApiException &&
          failure.hasResponseCode &&
          failure.httpStatus == 404 &&
          item.stage == ClientReleaseQueueStage.unknown &&
          item.pendingOperation == ClientReleaseQueueOperation.prepare) {
        // A read is not proof that a timed-out create can never commit. Only
        // explicitly continuing the SAME idempotent UUID/body is allowed.
        item.pendingOperation = null;
        item.stage = ClientReleaseQueueStage.prepared;
        item.error = '原编号暂未找到记录。可重选同SHA原文件，再明确继续原准备；不会更换编号。';
        await _save();
      } else {
        item.error = _message(failure);
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> withdraw(ClientRelease record) async {
    if (!current || busy || record.state != 'PUBLISHED') return;
    requireId(record.id);
    if (withdrawals[record.id] == ClientReleaseWithdrawState.unknown) return;
    busy = true;
    error = null;
    var dispatched = false;
    try {
      await gateway.begin(() => current);
      withdrawals[record.id] = ClientReleaseWithdrawState.sending;
      _notify();
      await _save();
      dispatched = true;
      final response = _parseAdminRecord(await gateway.withdraw(record.id));
      if (!current) return;
      if (response.id != record.id || response.state != 'WITHDRAWN') {
        throw const FormatException('服务器未确认原版本已撤回');
      }
      withdrawals[record.id] = ClientReleaseWithdrawState.confirmed;
      _updateRecord(response);
      releases = [
        for (final item in releases)
          if (item.id == response.id) response else item,
      ];
      await _save();
    } catch (failure) {
      if (withdrawals[record.id] != ClientReleaseWithdrawState.confirmed) {
        final definite =
            failure is ApiException &&
            failure.hasResponseCode &&
            (failure.httpStatus ?? 0) >= 400 &&
            (failure.httpStatus ?? 999) < 500;
        withdrawals[record.id] = !dispatched || definite
            ? ClientReleaseWithdrawState.ready
            : ClientReleaseWithdrawState.unknown;
      }
      error = _message(failure);
      try {
        await _save();
      } catch (_) {}
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> reconcileWithdrawal(String id) async {
    if (!current || busy) return;
    requireId(id);
    busy = true;
    _notify();
    try {
      await gateway.begin(() => current);
      final response = _parseAdminRecord(await gateway.read(id));
      if (!current) return;
      if (response.id != id ||
          !const {'PUBLISHED', 'WITHDRAWN'}.contains(response.state)) {
        throw const FormatException('原撤回记录状态不匹配');
      }
      withdrawals[id] = response.state == 'WITHDRAWN'
          ? ClientReleaseWithdrawState.confirmed
          : ClientReleaseWithdrawState.ready;
      _updateRecord(response);
      releases = [
        for (final item in releases)
          if (item.id == id) response else item,
      ];
      await _save();
    } catch (failure) {
      if (current) error = _message(failure);
    } finally {
      busy = false;
      _notify();
    }
  }

  static void requireId(String id) {
    if (!RegExp(
      r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
    ).hasMatch(id)) {
      throw const FormatException('发布记录编号无效');
    }
  }

  void _updateRecord(ClientRelease response) {
    for (final item in _items) {
      if (item.releaseId == response.id && item.publishedRelease != null) {
        // Preserve the confirmed operation, while presenting the latest
        // authoritative withdrawal state in both ledger and pair summary.
        item.publishedRelease = response;
        if (response.state == 'WITHDRAWN') {
          item.stage = ClientReleaseQueueStage.withdrawn;
          item.pendingOperation = null;
          item.retentionPending = false;
        }
      }
    }
  }

  void retire() {
    if (retired) return;
    retired = true;
    unawaited(_reader?.cancel());
    for (final item in _items) {
      item.file = null;
      item.publishedRelease = null;
      item.error = null;
      if (item.pendingOperation != null) {
        item.stage = ClientReleaseQueueStage.unknown;
      }
    }
    releases = [];
    withdrawals.updateAll(
      (id, state) => state == ClientReleaseWithdrawState.sending
          ? ClientReleaseWithdrawState.unknown
          : state,
    );
    unawaited(_save().catchError((Object _) {}));
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    retire();
    _disposed = true;
    super.dispose();
  }

  static String _message(Object error) => error is ApiException
      ? error.message
      : error is StateError
      ? error.message.toString()
      : error is FormatException
      ? error.message
      : '操作未确认完成，请先核对原记录；不要换编号重复提交。';
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
