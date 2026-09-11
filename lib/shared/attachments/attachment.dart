// 通用附件模型（对应后端 AttachmentDto）。
// owner_type + owner_id 软关联业务单据，如 EXPENSE_CLAIM = 报销单。

import '../../core/utils/china_datetime.dart';
import 'attachment_file_rules.dart';

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
    this.category,
    this.avatar = false,
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

  /// 文档分类（员工档案：合同/身份证件/学历证书/照片/其他）；报销附件为 null。
  final String? category;

  /// 是否员工头像。
  final bool avatar;

  /// 是否「客户端能显示的图片」——用于头像选择与图片分支。
  /// 2026-09-11 起以能力矩阵为准而非 `image/` 前缀：tiff/heic/svg 也是 image/*，
  /// 但 Flutter 解码不了，选成头像就是一个永远加载失败的空头像。
  bool get isImage => isRenderableImageAttachment(originalName, contentType);

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
      category: json['category'] as String?,
      avatar: json['avatar'] as bool? ?? false,
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
    required this.formFields,
    required this.confirmToken,
  });

  final String storageKey;
  final String url;
  final String method;
  final String contentType;
  final Map<String, String> headers;
  final Map<String, String> formFields;
  final String confirmToken;

  factory PresignResult.fromJson(Map<String, dynamic> json) {
    final headers =
        (json['headers'] as Map?)?.cast<String, String>() ?? const {};
    final formFields =
        (json['formFields'] as Map?)?.cast<String, String>() ?? const {};
    return PresignResult(
      storageKey: json['storageKey'] as String,
      url: json['url'] as String,
      method: (json['method'] as String?) ?? 'PUT',
      contentType: headers['Content-Type'] ?? 'application/octet-stream',
      headers: headers,
      formFields: formFields,
      confirmToken: json['confirmToken'] as String,
    );
  }
}
