import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'attachment.dart';

/// Original actor/server and verified parent CREATE proof. This is private
/// protocol metadata; never derive it from a later login or current form text.
class AttachmentUploadIdentity {
  const AttachmentUploadIdentity({
    required this.server,
    required this.userId,
    required this.actorId,
    required this.parentProofHash,
  });
  final String server, userId, parentProofHash;
  final String? actorId;
}

class AttachmentUploadAttempt {
  AttachmentUploadAttempt._(this.data);
  factory AttachmentUploadAttempt.capture({
    required PresignResult grant,
    required AttachmentUploadIdentity identity,
    required String ownerType,
    required String ownerId,
    required String name,
    required String contentType,
    required Uint8List bytes,
  }) => AttachmentUploadAttempt.restore({
    'schema': 1,
    'server': identity.server,
    'userId': identity.userId,
    'actorId': identity.actorId,
    'parentProofHash': identity.parentProofHash,
    'storageKey': grant.storageKey,
    'ownerType': ownerType,
    'ownerId': ownerId,
    'originalName': name.trim(),
    'contentType': contentType.split(';').first.trim().toLowerCase(),
    'sizeBytes': bytes.length,
    'fileSha256': sha256.convert(bytes).toString(),
  });
  factory AttachmentUploadAttempt.restore(Map<String, dynamic> json) {
    if (json['schema'] != 1 ||
        json['sizeBytes'] is! int ||
        (json['sizeBytes'] as int) <= 0 ||
        (json['actorId'] != null && json['actorId'] is! String)) {
      throw const FormatException('原附件上传身份不完整');
    }
    for (final key in [
      'server',
      'userId',
      'parentProofHash',
      'storageKey',
      'ownerType',
      'ownerId',
      'originalName',
      'contentType',
      'fileSha256',
    ]) {
      if (json[key] is! String || (json[key] as String).isEmpty) {
        throw const FormatException('原附件上传身份不完整');
      }
    }
    for (final key in ['parentProofHash', 'fileSha256']) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(json[key] as String)) {
        throw const FormatException('原附件证明无效');
      }
    }
    return AttachmentUploadAttempt._(Map<String, dynamic>.unmodifiable(json));
  }
  final Map<String, dynamic> data;
  String get ownerId => data['ownerId'] as String;
  String get storageKey => data['storageKey'] as String;
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(data);
  bool belongsTo(AttachmentUploadIdentity identity) =>
      data['server'] == identity.server &&
      data['userId'] == identity.userId &&
      data['actorId'] == identity.actorId &&
      data['parentProofHash'] == identity.parentProofHash;
  bool matchesFile({
    required String name,
    required String contentType,
    required Uint8List bytes,
  }) =>
      data['originalName'] == name.trim() &&
      data['contentType'] ==
          contentType.split(';').first.trim().toLowerCase() &&
      data['sizeBytes'] == bytes.length &&
      data['fileSha256'] == sha256.convert(bytes).toString();

  // The authoritative stored SHA is required. Legacy null never confirms.
  // Name/category metadata can change; identity and original bytes cannot.
  bool matchesNativeReceipt(Attachment row) =>
      row.id.isNotEmpty &&
      row.storageKey == storageKey &&
      row.ownerType == data['ownerType'] &&
      row.ownerId == ownerId &&
      row.uploadedBy == data['userId'] &&
      row.sha256 != null &&
      row.sha256 == data['fileSha256'];
}
