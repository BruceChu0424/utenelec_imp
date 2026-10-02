// 新建单据「保存前暂存附件」控制器（ADR-074：附件只挂已保存的业务 UUID）。
// 新建页在保存前只把选中的原文件留在内存；保存成功拿到单据 UUID 后逐个
// presign → 直传字节 → confirm，契约与已保存单据的即时上传完全相同。
// 失败项保留在 items 里（带 lastError）供重试，成功项移除。

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'attachment.dart';
import 'attachment_file_rules.dart';
import 'attachment_service.dart';
import 'attachment_upload_attempt.dart';

class PendingAttachment {
  PendingAttachment({
    required this.name,
    required this.contentType,
    required this.bytes,
    this.category,
    String? localUploadId,
    this.legacyUntracked = false,
  }) : localUploadId = localUploadId ?? const Uuid().v4();

  final String localUploadId;
  final bool legacyUntracked;
  final Map<String, AttachmentUploadAttempt> uploadAttempts = {};
  final Map<String, String> confirmedAttachmentIds = {};
  final Set<String> confirmedDeletedOwners = {};

  final String name;
  final String contentType;
  final Uint8List bytes;

  /// 可选分类：加入时不问，加入之后在文件旁边随时可改（flush 时随上传带走）。
  String? category;

  /// 最近一次上传失败原因；成功项会从控制器移除，故非空即「待重试」。
  String? lastError;

  /// 批量拆单时已成功挂上的单据（重试只补漏，不重复上传）。
  final Set<String> uploadedTo = {};
  String? _draftBytes;
  String get draftBytes => _draftBytes ??= base64Encode(bytes);

  int get sizeBytes => bytes.length;
}

class PendingUploadReport {
  const PendingUploadReport({required this.uploaded, required this.failed});

  final List<Attachment> uploaded;
  final List<PendingAttachment> failed;

  bool get allSucceeded => failed.isEmpty;
  int get uploadedCount => uploaded.length;
  int get failedCount => failed.length;
}

class PendingAttachmentController extends ChangeNotifier {
  PendingAttachmentController({
    int? maxFileBytes,
    this.maxTotalBytes = kPendingAttachmentMaxTotalBytes,
  }) : _fileLimitOverride = maxFileBytes;

  /// 显式指定时用指定值 (测试)；否则跟随服务端下发的运行时上限。
  final int? _fileLimitOverride;
  int get maxFileBytes => _fileLimitOverride ?? AttachmentLimits.maxFileBytes;
  final int maxTotalBytes;
  final List<PendingAttachment> _items = [];
  bool _flushing = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  List<PendingAttachment> get items => List.unmodifiable(_items);
  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  bool get isFlushing => _flushing;
  bool hasPendingFor(String ownerId) =>
      _items.any((item) => !item.uploadedTo.contains(ownerId));
  bool needsReceiptFor(String ownerId) => _items.any(
    (item) =>
        !item.uploadedTo.contains(ownerId) &&
        (item.legacyUntracked || item.uploadAttempts.containsKey(ownerId)),
  );

  int get totalBytes => _items.fold(0, (sum, item) => sum + item.sizeBytes);

  /// Receipt adoption may change acknowledgements, never replace local file
  /// input with another tab's newer attachments or silently drop unsaved files.
  bool sameOriginalFiles(Map<String, dynamic> checkpoint) {
    final values = checkpoint['items'] ?? const <Object?>[];
    if (values is! List || values.length != _items.length) return false;
    final originals = <String, Map<String, dynamic>>{};
    for (final value in values) {
      if (value is! Map || value['localUploadId'] is! String) return false;
      final id = value['localUploadId'] as String;
      if (originals.containsKey(id)) return false;
      originals[id] = Map<String, dynamic>.from(value);
    }
    for (final item in _items) {
      final saved = originals[item.localUploadId];
      if (saved == null ||
          saved['name'] != item.name ||
          saved['contentType'] != item.contentType ||
          saved['bytes'] != item.draftBytes ||
          saved['category'] != item.category ||
          jsonEncode(saved['uploadAttempts'] ?? <String, dynamic>{}) !=
              jsonEncode({
                for (final entry in item.uploadAttempts.entries)
                  entry.key: entry.value.toJson(),
              })) {
        return false;
      }
    }
    return true;
  }

  int get failedCount => _items.where((i) => i.lastError != null).length;

  /// Keep original bytes and confirmed upload targets across interrupted editing.
  /// This is local recovery only; uploads still use the server's permission checks.
  Map<String, dynamic> exportDraft() => {
    'items': [
      for (final item in _items)
        {
          'localUploadId': item.localUploadId,
          'uploadTrackingVersion': 1,
          'legacyUntracked': item.legacyUntracked,
          'uploadAttempts': {
            for (final entry in item.uploadAttempts.entries)
              entry.key: entry.value.toJson(),
          },
          'confirmedAttachmentIds': item.confirmedAttachmentIds,
          'confirmedDeletedOwners': item.confirmedDeletedOwners.toList(),
          'name': item.name,
          'contentType': item.contentType,
          'bytes': item.draftBytes,
          'category': item.category,
          'lastError': item.lastError,
          'uploadedTo': item.uploadedTo.toList(),
        },
    ],
  };

  void restoreDraft(Map<String, dynamic> draft) {
    if (_flushing) throw StateError('附件上传过程中不能恢复草稿');
    final restored = <PendingAttachment>[];
    var bytes = 0;
    for (final raw in draft['items'] as List? ?? const []) {
      final data = Map<String, dynamic>.from(raw as Map);
      final file = base64Decode(data['bytes'] as String);
      bytes += file.length;
      if (bytes > maxTotalBytes) throw const FormatException('草稿附件超出总大小限制');
      final item = PendingAttachment(
        name: data['name'] as String,
        contentType: data['contentType'] as String,
        bytes: file,
        category: data['category'] as String?,
        localUploadId: data['localUploadId'] as String?,
        legacyUntracked:
            data['uploadTrackingVersion'] != 1 ||
            data['legacyUntracked'] == true,
      )..lastError = data['lastError'] as String?;
      item.uploadedTo.addAll(
        (data['uploadedTo'] as List? ?? const []).cast<String>(),
      );
      final attempts = data['uploadAttempts'];
      if (attempts is Map) {
        for (final entry in attempts.entries) {
          item.uploadAttempts[entry.key
              as String] = AttachmentUploadAttempt.restore(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
      item.confirmedAttachmentIds.addAll(
        (data['confirmedAttachmentIds'] as Map?)?.cast<String, String>() ??
            const {},
      );
      item.confirmedDeletedOwners.addAll(
        (data['confirmedDeletedOwners'] as List? ?? const []).cast<String>(),
      );

      restored.add(item);
    }
    _items
      ..clear()
      ..addAll(restored);
    notifyListeners();
  }

  /// 接纳一个选中的文件；返回 null 表示已加入，否则返回拒绝原因（直接可展示）。
  String? add(PlatformFile file, {String? category}) {
    final bytes = file.bytes;
    if (bytes == null) return '无法读取「${file.name}」的内容';
    final contentType = guessAttachmentContentType(file.name);
    if (contentType == null) {
      return '「${file.name}」类型不支持（$kAttachmentUploadTypesHint）';
    }
    if (bytes.isEmpty) return '「${file.name}」是空文件';
    if (bytes.length > maxFileBytes) {
      return '「${file.name}」超过单文件 ${formatAttachmentSize(maxFileBytes)} 上限';
    }
    if (totalBytes + bytes.length > maxTotalBytes) {
      return '待上传文件合计超过 ${formatAttachmentSize(maxTotalBytes)}，'
          '请先保存单据，再到详情页补传其余文件';
    }
    _items.add(
      PendingAttachment(
        name: file.name,
        contentType: contentType,
        bytes: bytes,
        category: category,
      ),
    );
    notifyListeners();
    return null;
  }

  /// 设置/清除某个暂存文件的分类（可选标注，保存单据时随该文件一起上传）。
  void setCategoryAt(int index, String? category) {
    if (index < 0 || index >= _items.length) return;
    final normalized = (category == null || category.trim().isEmpty)
        ? null
        : category.trim();
    if (_items[index].category == normalized) return;
    _items[index].category = normalized;
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _items.length) return;
    _items.removeAt(index);
    notifyListeners();
  }

  void remove(PendingAttachment item) {
    if (_items.remove(item)) notifyListeners();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }

  /// 单据保存成功后：把暂存文件逐个上传并确认到 [ownerId]。
  Future<PendingUploadReport> flush(
    AttachmentService service, {
    required String ownerType,
    required String ownerId,
  }) => flushToOwners(service, ownerType: ownerType, ownerIds: [ownerId]);

  /// 批量拆单（一次保存生成多张单据）时，同一份文件挂到每张单据上；
  /// 只有对全部单据都成功的文件才从暂存移除，任一失败保留待重试。
  Future<PendingUploadReport> flushToOwners(
    AttachmentService service, {
    required String ownerType,
    required List<String> ownerIds,
    bool Function()? canContinue,
    AttachmentUploadIdentity? uploadIdentity,
    Future<void> Function()? persistCheckpoint,
  }) async {
    if (_items.isEmpty || ownerIds.isEmpty) {
      return const PendingUploadReport(uploaded: [], failed: []);
    }
    _flushing = true;
    notifyListeners();
    final uploaded = <Attachment>[];
    final failed = <PendingAttachment>[];
    try {
      // 按快照遍历：上传期间不允许并发增删，但仍以副本防御。
      for (final item in List<PendingAttachment>.of(_items)) {
        final done = item.uploadedTo;
        String? error;
        for (final ownerId in ownerIds) {
          if (done.contains(ownerId)) {
            continue;
          }
          try {
            if (uploadIdentity != null &&
                (item.legacyUntracked ||
                    item.uploadAttempts.containsKey(ownerId))) {
              throw StateError('原附件上传结果待只读核对，不能重新上传');
            }
            if (uploadIdentity != null &&
                (canContinue == null || persistCheckpoint == null)) {
              throw StateError('原附件上传缺少持久化或身份保护');
            }
            if (canContinue != null && !canContinue()) {
              throw StateError('身份或上传权限已变化，原附件保留在本机');
            }
            final bytes = Uint8List.fromList(item.bytes);
            final attachment = uploadIdentity != null
                ? await service.uploadCheckpointed(
                    ownerType: ownerType,
                    ownerId: ownerId,
                    fileName: item.name,
                    contentType: item.contentType,
                    bytes: bytes,
                    category: item.category,
                    canContinue: canContinue!,
                    onPresigned: (grant) async {
                      final attempt = AttachmentUploadAttempt.capture(
                        grant: grant,
                        identity: uploadIdentity,
                        ownerType: ownerType,
                        ownerId: ownerId,
                        name: item.name,
                        contentType: item.contentType,
                        bytes: bytes,
                      );
                      if (!attempt.matchesFile(
                        name: item.name,
                        contentType: item.contentType,
                        bytes: item.bytes,
                      )) {
                        throw StateError('原附件在上传准备期间变化，未发送字节');
                      }
                      item.uploadAttempts[ownerId] = attempt;
                      await persistCheckpoint!();
                      if (!attempt.matchesFile(
                        name: item.name,
                        contentType: item.contentType,
                        bytes: item.bytes,
                      )) {
                        throw StateError('原附件在保存检查点期间变化，未发送字节');
                      }
                    },
                  )
                : canContinue == null
                ? await service.upload(
                    ownerType: ownerType,
                    ownerId: ownerId,
                    fileName: item.name,
                    contentType: item.contentType,
                    bytes: item.bytes,
                    category: item.category,
                  )
                : await service.uploadGuarded(
                    ownerType: ownerType,
                    ownerId: ownerId,
                    fileName: item.name,
                    contentType: item.contentType,
                    bytes: item.bytes,
                    category: item.category,
                    canContinue: canContinue,
                  );
            if (uploadIdentity != null &&
                !item.uploadAttempts[ownerId]!.matchesNativeReceipt(
                  attachment,
                )) {
              throw StateError('原附件回执尚未与上传身份和文件指纹一致，保留待核对');
            }
            uploaded.add(attachment);
            done.add(ownerId);
            if (uploadIdentity != null) {
              item.confirmedAttachmentIds[ownerId] = attachment.id;
              if (attachment.deleted) {
                item.confirmedDeletedOwners.add(ownerId);
              }
            }
          } catch (e) {
            error = _describe(e);
            break;
          }
        }
        if (canContinue != null && !canContinue()) {
          error = '身份或上传权限已变化，原附件和已返回回执仍保留';
        }
        if (error == null && done.containsAll(ownerIds)) {
          item.lastError = null;
          _items.remove(item);
        } else {
          item.lastError = error ?? '上传失败';
          failed.add(item);
        }
      }
    } finally {
      _flushing = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
    return PendingUploadReport(uploaded: uploaded, failed: failed);
  }

  static String _describe(Object error) {
    // ApiException.toString() 带类名前缀；优先取其 message 字段。
    try {
      final message = (error as dynamic).message;
      if (message is String && message.isNotEmpty) return message;
    } catch (_) {
      // 非 ApiException：退回通用描述。
    }
    return '上传失败，请稍后重试';
  }
}
