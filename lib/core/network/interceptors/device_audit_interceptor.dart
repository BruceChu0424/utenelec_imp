// 每个 API 请求附带最小设备快照，并在本机安全存储保存有界回执。
//
// 不保存 query、请求体、Authorization 或其它凭证。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../audit/device_audit_store.dart';

class DeviceAuditInterceptor extends Interceptor {
  DeviceAuditInterceptor(this.store, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  static const _eventIdExtra = 'uten.audit.clientEventId';
  static const _startedAtExtra = 'uten.audit.startedAt';
  static const _localReceiptEnabledExtra = 'uten.audit.localReceiptEnabled';

  /// Keeps the complete client request comfortably below the gateway/server
  /// budget even for super-admin sessions and verbose browser headers.
  static const maxEncodedContextLength = 1536;

  final DeviceAuditStore store;
  final Uuid _uuid;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Audit investigation requests still carry device context for the server's
    // own audit trail, but must not create local receipts. Otherwise opening or
    // verifying the receipt ledger could evict the very evidence being checked
    // at the bounded local-store limit and create a self-observation loop.
    final recordLocally = !_isAuditInvestigationRequest(options.path);
    options.extra[_localReceiptEnabledExtra] = recordLocally;
    try {
      final profile = await store.profile();
      final existingEventId = options.extra[_eventIdExtra] as String?;
      final eventId = _validUuid(existingEventId)
          ? existingEventId!
          : _uuid.v4();
      final startedAt =
          options.extra[_startedAtExtra] as DateTime? ?? DateTime.now();
      options.extra[_eventIdExtra] = eventId;
      options.extra[_startedAtExtra] = startedAt;
      options.headers[DeviceAuditHeaders.operationId] = eventId;
      options.headers[DeviceAuditHeaders.context] = _encodedContext(
        profile,
        startedAt,
      );
      if (recordLocally) {
        unawaited(
          store
              .beginReceipt(
                clientEventId: eventId,
                method: options.method,
                path: options.uri.path,
                startedAt: startedAt,
                device: profile,
              )
              .catchError((Object _) {}),
        );
      }
    } catch (_) {
      // 设备插件或本地安全存储失败不能中断业务请求。
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final retentionMonths = _retentionMonths(response);
    if (retentionMonths != null) {
      unawaited(
        store.updateRetentionMonths(retentionMonths).catchError((Object _) {}),
      );
    }
    _complete(
      response.requestOptions,
      outcome: response.statusCode != null && response.statusCode! >= 400
          ? 'failure'
          : 'success',
      statusCode: response.statusCode,
      headers: response.headers,
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _complete(
      err.requestOptions,
      outcome: err.response == null ? 'network_error' : 'failure',
      statusCode: err.response?.statusCode,
      headers: err.response?.headers,
    );
    handler.next(err);
  }

  void _complete(
    RequestOptions options, {
    required String outcome,
    int? statusCode,
    Headers? headers,
  }) async {
    if (options.extra[_localReceiptEnabledExtra] == false) return;
    final eventId =
        options.extra[_eventIdExtra] as String? ??
        options.headers[DeviceAuditHeaders.operationId] as String?;
    if (eventId == null || eventId.isEmpty) return;
    unawaited(
      store
          .completeReceipt(
            clientEventId: eventId,
            outcome: outcome,
            completedAt: DateTime.now(),
            statusCode: statusCode,
            serverRequestId: headers?.value(DeviceAuditHeaders.serverRequestId),
          )
          .catchError((Object _) {}),
    );
  }

  bool _isAuditInvestigationRequest(String path) =>
      path == '/admin/audit-logs' || path.startsWith('/admin/audit-logs/');

  int? _retentionMonths(Response<dynamic> response) {
    final data = response.data;
    if (data is! Map) return null;
    final value = data['auditReceiptRetentionMonths'];
    if (value is num) return value.toInt();
    return value is String ? int.tryParse(value) : null;
  }

  String _encodedContext(DeviceAuditProfile profile, DateTime startedAt) {
    final context = profile.toAuditContext(startedAt);
    String encode() => base64UrlEncode(utf8.encode(jsonEncode(context)));
    var encoded = encode();
    for (final field in const [
      'deviceName',
      'manufacturer',
      'model',
      'osVersion',
      'browserName',
      'formFactor',
      'locale',
      'timeZone',
    ]) {
      if (encoded.length <= maxEncodedContextLength) break;
      context.remove(field);
      encoded = encode();
    }
    return encoded;
  }
}

bool _validUuid(String? value) =>
    value != null &&
    RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);
