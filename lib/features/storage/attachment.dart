// 通用附件模型（对应后端 AttachmentDto）。
// owner_type + owner_id 软关联业务单据，如 EXPENSE_CLAIM = 报销单。

import '../../core/utils/china_datetime.dart';

class Attachment {
  const Attachment({
    required this.id,
    required this.ownerType,
    required this.ownerId,
    required this.storageKey,
    required this.originalName,
    this.contentType,
    required this.sizeBytes,
    this.uploadedAt,
    this.downloadUrl,
  });

  final String id;
  final String ownerType;
  final String ownerId;
  final String storageKey;
  final String originalName;
  final String? contentType;
  final int sizeBytes;
  final DateTime? uploadedAt;
  final String? downloadUrl;

  bool get isImage => contentType != null && contentType!.startsWith('image/');

  factory Attachment.fromJson(Map<String, dynamic> json) {
    return Attachment(
      id: json['id'] as String,
      ownerType: json['ownerType'] as String,
      ownerId: json['ownerId'] as String,
      storageKey: json['storageKey'] as String,
      originalName: json['originalName'] as String,
      contentType: json['contentType'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      uploadedAt: _dateTime(json['uploadedAt']),
      downloadUrl: json['downloadUrl'] as String?,
    );
  }

  static DateTime? _dateTime(Object? value) {
    if (value == null) return null;
    return ChinaDateTime.tryParse(value as String);
  }
}

/// 预签名上传结果（presign 响应）。
class PresignResult {
  const PresignResult({
    required this.storageKey,
    required this.url,
    required this.method,
    required this.contentType,
    required this.headers,
    required this.confirmToken,
  });

  final String storageKey;
  final String url;
  final String method;
  final String contentType;
  final Map<String, String> headers;
  final String confirmToken;

  factory PresignResult.fromJson(Map<String, dynamic> json) {
    final headers =
        (json['headers'] as Map?)?.cast<String, String>() ?? const {};
    return PresignResult(
      storageKey: json['storageKey'] as String,
      url: json['url'] as String,
      method: (json['method'] as String?) ?? 'PUT',
      contentType: headers['Content-Type'] ?? 'application/octet-stream',
      headers: headers,
      confirmToken: json['confirmToken'] as String,
    );
  }
}
