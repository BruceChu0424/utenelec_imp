import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';

/// Real upload service and native history GET against an in-memory transport.
/// Confirm commits the receipt before optionally holding its response.
class ControlledAttachmentPipeline {
  ControlledAttachmentPipeline({
    this.waitAt,
    this.uniqueKeys = false,
    this.uploadedBy = 'draft-user',
  }) {
    final dio = Dio(
      BaseOptions(baseUrl: 'https://attachment-fixture.invalid/api'),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          requests.add(request);
          if (request.method == 'GET' && request.path == '/attachments') {
            historyCalls++;
            if (!historyEntered.isCompleted) historyEntered.complete();
            if (historyGate != null) await historyGate!.future;
            if (historyErrorStatus != null) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: request,
                    statusCode: historyErrorStatus,
                    data: {
                      'code': 'FORBIDDEN',
                      'message': 'native owner scope denied',
                    },
                  ),
                ),
              );
              return;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: committed
                    .where(
                      (row) =>
                          row['ownerType'] ==
                              request.queryParameters['ownerType'] &&
                          row['ownerId'] == request.queryParameters['ownerId'],
                    )
                    .map(Map<String, dynamic>.from)
                    .toList(),
              ),
            );
            return;
          }
          final stage = request.path.endsWith('/presign')
              ? 'presign'
              : request.path.endsWith('/confirm')
              ? 'confirm'
              : 'bytes';
          final body = request.data is Map
              ? Map<String, dynamic>.from(request.data as Map)
              : <String, dynamic>{};
          Map<String, dynamic>? reply;
          if (stage == 'presign') {
            final key = uniqueKeys
                ? 'fixture-file-${++_sequence}'
                : 'fixture-file';
            reply = {
              'storageKey': key,
              'url': '/attachments/raw/$key',
              'method': 'PUT',
              'headers': {'Content-Type': 'text/plain'},
              'formFields': <String, String>{},
              'confirmToken': 'fixture-upload-token',
            };
          } else if (stage == 'bytes' &&
              request.path.startsWith('/attachments/raw/')) {
            rawBytes[request.path.split('/').last] = Uint8List.fromList(
              request.data as Uint8List,
            );
          } else if (stage == 'confirm') {
            final key = body['storageKey'] as String;
            reply = committed
                .where((row) => row['storageKey'] == key)
                .firstOrNull;
            if (reply == null) {
              reply = {
                'id': 'ack-${committed.length + 1}',
                'ownerType': body['ownerType'],
                'ownerId': body['ownerId'],
                'storageKey': key,
                'originalName': body['originalName'],
                'contentType': body['contentType'],
                'sizeBytes': body['sizeBytes'],
                'uploadedBy': uploadedBy,
                'sha256': crypto.sha256.convert(rawBytes[key]!).toString(),
                'deleted': false,
              };
              committed.add(reply);
            }
          } else {
            handler.reject(
              DioException(
                requestOptions: request,
                message: 'unexpected upload fixture request',
              ),
            );
            return;
          }
          if (stage == waitAt && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          if (stage == 'bytes') {
            handler.resolve(
              Response<void>(requestOptions: request, statusCode: 204),
            );
          } else {
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: reply,
              ),
            );
          }
        },
      ),
    );
    service = AttachmentService(ApiClient(dio));
  }
  final String? waitAt;
  final bool uniqueKeys;
  final String uploadedBy;
  int _sequence = 0;
  int historyCalls = 0;
  int? historyErrorStatus;
  Completer<void>? historyGate;
  final historyEntered = Completer<void>();
  final entered = Completer<void>();
  final release = Completer<void>();
  final requests = <RequestOptions>[];
  final committed = <Map<String, dynamic>>[];
  final rawBytes = <String, Uint8List>{};
  late final AttachmentService service;
}
