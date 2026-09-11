// 新建单据「保存前暂存附件」控制器（ADR-074：附件只挂已保存的业务 UUID）。
// 新建页在保存前只把选中的原文件留在内存；保存成功拿到单据 UUID 后逐个
// presign → 直传字节 → confirm，契约与已保存单据的即时上传完全相同。
// 失败项保留在 items 里（带 lastError）供重试，成功项移除。

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'attachment.dart';
import 'attachment_file_rules.dart';
import 'attachment_service.dart';

class PendingAttachment {
  PendingAttachment({
    required this.name,
    required this.contentType,
    required this.bytes,
    this.category,
  });

  final String name;
  final String contentType;
  final Uint8List bytes;

  /// 可选分类：加入时不问，加入之后在文件旁边随时可改（flush 时随上传带走）。
  String? category;

  /// 最近一次上传失败原因；成功项会从控制器移除，故非空即「待重试」。
  String? lastError;

  /// 批量拆单时已成功挂上的单据（重试只补漏，不重复上传）。
  final Set<String> uploadedTo = {};

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
    this.maxFileBytes = kAttachmentMaxFileBytes,
    this.maxTotalBytes = kPendingAttachmentMaxTotalBytes,
  });

  final int maxFileBytes;
  final int maxTotalBytes;
  final List<PendingAttachment> _items = [];
  bool _flushing = false;

  List<PendingAttachment> get items => List.unmodifiable(_items);
  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  bool get isFlushing => _flushing;
  int get totalBytes => _items.fold(0, (sum, item) => sum + item.sizeBytes);
  int get failedCount => _items.where((i) => i.lastError != null).length;

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
          if (done.contains(ownerId)) continue;
          try {
            uploaded.add(
              await service.upload(
                ownerType: ownerType,
                ownerId: ownerId,
                fileName: item.name,
                contentType: item.contentType,
                bytes: item.bytes,
                category: item.category,
              ),
            );
            done.add(ownerId);
          } catch (e) {
            error = _describe(e);
            break;
          }
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
      notifyListeners();
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
