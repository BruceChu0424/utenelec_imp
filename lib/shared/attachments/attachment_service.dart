// 附件存储服务：presign → 直传字节 → confirm；下载；删除。
// 本地后端：上传/下载 URL 是相对路径（/api 基址），走鉴权 Dio。
// OSS 后端：上传/下载 URL 是绝对预签名地址，用独立 Dio 直传/直取（不带本应用鉴权头）。
// 客户端代码在两种后端间一致，仅按 URL 是否绝对分流。

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import 'attachment.dart';

class AttachmentService {
  AttachmentService(this._api, {Dio? externalDio})
    : _externalDio = externalDio ?? Dio();

  final ApiClient _api;
  final Dio _externalDio;
  static const _base = '/attachments';

  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    final presignResult = await presign(
      ownerType: ownerType,
      ownerId: ownerId,
      fileName: fileName,
      contentType: contentType,
      sizeBytes: bytes.length,
    );
    await uploadBytes(presignResult, bytes);
    return confirm(
      storageKey: presignResult.storageKey,
      confirmToken: presignResult.confirmToken,
      ownerType: ownerType,
      ownerId: ownerId,
      originalName: fileName,
      contentType: contentType,
      sizeBytes: bytes.length,
      category: category,
    );
  }

  Future<List<Attachment>> list({
    required String ownerType,
    required String ownerId,
  }) async {
    final rows = await _api.getList(
      _base,
      query: {'ownerType': ownerType, 'ownerId': ownerId},
    );
    return rows.map(Attachment.fromJson).toList();
  }

  /// 上传完成后设置/清除文件分类（`PUT /attachments/{id}/category`）。
  /// [category] 传 null = 清除；后端与删除同一条对象授权路径，单据锁定后会拒绝。
  Future<Attachment> setCategory(String id, String? category) async {
    final r = await _api.put(
      '$_base/$id/category',
      body: {'category': category},
    );
    return Attachment.fromJson(r);
  }

  Future<void> delete(String id) => _api.delete('$_base/$id');

  /// Reads only the employee's selected avatar through its dedicated gate.
  /// The opaque storage key is never converted into a public download URL.
  Future<Uint8List> employeeAvatarBytes(String employeeId) =>
      _api.getBytes(ApiEndpoints.employeeAvatar(employeeId));

  Future<void> uploadBytes(PresignResult upload, Uint8List bytes) async {
    final uploadUrl = upload.url;
    if (uploadUrl.startsWith('http://') || uploadUrl.startsWith('https://')) {
      // OSS 预签名 URL（跨域）：独立 Dio 直传，不带本应用鉴权头。
      if (upload.method.toUpperCase() != 'POST' || upload.formFields.isEmpty) {
        throw StateError(
          'OSS attachment grant is missing its signed POST policy',
        );
      }
      final form = FormData.fromMap({
        ...upload.formFields,
        'file': MultipartFile.fromBytes(bytes, filename: upload.storageKey),
      });
      // This isolated client intentionally carries no ERP Authorization header.
      await _externalDio.post<dynamic>(
        uploadUrl,
        data: form,
        options: Options(headers: upload.headers),
      );
    } else {
      // 本地后端相对 raw 端点：经鉴权 Dio，并携带仅绑定本次上传的一次性语义授权。
      await _api.putBytes(
        uploadUrl,
        bytes,
        upload.contentType,
        headers: {
          ...upload.headers,
          'X-Uten-Attachment-Upload-Token': upload.confirmToken,
        },
      );
    }
  }

  Future<Uint8List> downloadBytes(Attachment attachment) async {
    final grant = await _api.get('$_base/${attachment.id}/download-grant');
    final downloadUrl = grant['url'] as String?;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      throw StateError('该附件暂无下载地址');
    }
    if (downloadUrl.startsWith('http://') ||
        downloadUrl.startsWith('https://')) {
      final r = await _externalDio.get<List<int>>(
        downloadUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(r.data ?? const []);
    }
    return _api.getBytes(downloadUrl);
  }

  /// Office 文档服务端转 PDF 后的字节（`GET /attachments/{id}/preview`）。
  /// 服务器未装转换组件或转换失败时后端返回业务错误，由调用方回落为下载。
  Future<Uint8List> previewBytes(Attachment attachment) =>
      _api.getBytes('$_base/${attachment.id}/preview');

  Future<PresignResult> presign({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required int sizeBytes,
  }) async {
    final r = await _api.post(
      '$_base/presign',
      body: {
        'ownerType': ownerType,
        'ownerId': ownerId,
        'fileName': fileName,
        'contentType': contentType,
        'sizeBytes': sizeBytes,
      },
    );
    return PresignResult.fromJson(r);
  }

  Future<Attachment> confirm({
    required String storageKey,
    required String confirmToken,
    required String ownerType,
    required String ownerId,
    required String originalName,
    required String contentType,
    required int sizeBytes,
    String? category,
  }) async {
    final r = await _api.post(
      '$_base/confirm',
      body: {
        'storageKey': storageKey,
        'confirmToken': confirmToken,
        'ownerType': ownerType,
        'ownerId': ownerId,
        'originalName': originalName,
        'contentType': contentType,
        'sizeBytes': sizeBytes,
        'category': ?category,
      },
    );
    return Attachment.fromJson(r);
  }
}

final attachmentServiceProvider = Provider<AttachmentService>(
  (ref) => AttachmentService(ref.watch(apiClientProvider)),
);
