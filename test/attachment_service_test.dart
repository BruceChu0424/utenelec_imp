import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';

void main() {
  test(
    'local upload uses /api raw endpoint and sends the bound upload token',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://office.example.com/api'));
      final requests = <RequestOptions>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            if (request.path == '/attachments/presign') {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'storageKey': 'fixed.png',
                    'url': '/attachments/raw/fixed.png',
                    'method': 'PUT',
                    'headers': {'Content-Type': 'image/png'},
                    'formFields': <String, String>{},
                    'confirmToken': 'signed-upload-grant',
                  },
                ),
              );
              return;
            }
            if (request.path == '/attachments/raw/fixed.png') {
              handler.resolve(
                Response<void>(requestOptions: request, statusCode: 204),
              );
              return;
            }
            if (request.path == '/attachments/confirm') {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'id': 'attachment-id',
                    'ownerType': 'EXPENSE_CLAIM',
                    'ownerId': 'claim-id',
                    'storageKey': 'fixed.png',
                    'originalName': 'receipt.png',
                    'contentType': 'image/png',
                    'sizeBytes': 8,
                    'downloadUrl': '/attachments/raw/fixed.png',
                  },
                ),
              );
              return;
            }
            handler.reject(
              DioException(
                requestOptions: request,
                message: 'unexpected request ${request.uri}',
              ),
            );
          },
        ),
      );
      final service = AttachmentService(ApiClient(dio));

      final saved = await service.upload(
        ownerType: 'EXPENSE_CLAIM',
        ownerId: 'claim-id',
        fileName: 'receipt.png',
        contentType: 'image/png',
        bytes: Uint8List(8),
      );

      expect(saved.id, 'attachment-id');
      final raw = requests.singleWhere(
        (request) => request.path == '/attachments/raw/fixed.png',
      );
      expect(
        raw.uri.toString(),
        'https://office.example.com/api/attachments/raw/fixed.png',
      );
      expect(
        raw.headers['X-Uten-Attachment-Upload-Token'],
        'signed-upload-grant',
      );
      expect(raw.headers[Headers.contentTypeHeader], 'image/png');
    },
  );

  test('OSS upload uses signed POST form without application token', () async {
    final external = Dio();
    RequestOptions? captured;
    external.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<void>(requestOptions: request, statusCode: 200),
          );
        },
      ),
    );
    final service = AttachmentService(ApiClient(Dio()), externalDio: external);
    const upload = PresignResult(
      storageKey: 'fixed.pdf',
      url: 'https://bucket.oss-cn-hangzhou.aliyuncs.com/',
      method: 'POST',
      contentType: 'application/pdf',
      headers: {},
      formFields: {
        'key': 'attachments/staging/fixed.pdf',
        'policy': 'signed-policy',
        'Signature': 'signature',
        'OSSAccessKeyId': 'temporary-access-key',
        'Content-Type': 'application/pdf',
      },
      confirmToken: 'application-only-token',
    );

    await service.uploadBytes(
      upload,
      Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
    );

    expect(captured, isNotNull);
    expect(captured!.method, 'POST');
    final form = captured!.data as FormData;
    expect(Map<String, String>.fromEntries(form.fields), upload.formFields);
    expect(form.files, hasLength(1));
    expect(form.files.single.key, 'file');
    expect(
      captured!.headers.containsKey('X-Uten-Attachment-Upload-Token'),
      isFalse,
    );
  });

  test(
    'download obtains a fresh object-authorized grant on every click',
    () async {
      final apiDio = Dio(
        BaseOptions(baseUrl: 'https://office.example.com/api'),
      );
      var grantRequests = 0;
      apiDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            grantRequests++;
            expect(request.path, '/attachments/attachment-id/download-grant');
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'url': 'https://bucket.example/fixed-version?versionId=v1',
                  'expiresAt': '2026-08-09T12:00:00Z',
                },
              ),
            );
          },
        ),
      );
      final external = Dio();
      external.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            expect(request.headers.containsKey('Authorization'), isFalse);
            handler.resolve(
              Response<List<int>>(
                requestOptions: request,
                statusCode: 200,
                data: const [1, 2, 3],
              ),
            );
          },
        ),
      );
      final service = AttachmentService(
        ApiClient(apiDio),
        externalDio: external,
      );
      const attachment = Attachment(
        id: 'attachment-id',
        ownerType: 'EXPENSE_CLAIM',
        ownerId: 'claim-id',
        storageKey: 'fixed.png',
        originalName: 'receipt.png',
        sizeBytes: 3,
      );

      expect(
        await service.downloadBytes(attachment),
        Uint8List.fromList([1, 2, 3]),
      );
      expect(
        await service.downloadBytes(attachment),
        Uint8List.fromList([1, 2, 3]),
      );
      expect(grantRequests, 2);
    },
  );
}
