import 'package:uuid/uuid.dart';
import 'api_client.dart';
import '../performance/json_value_snapshot.dart';

/// Original business-request proof shared by receipt-aware editors and private
/// draft recovery. Wire fingerprints and outcomes remain owned by the server.
class OriginalCommand {
  OriginalCommand({
    required this.actorId,
    required this.operation,
    required this.method,
    required this.path,
    required Map<String, dynamic> body,
    this.identityField = 'requestId',
    this.opaqueIdentity = false,
    bool detachedBody = false,
    this.cancellationPayload,
    this.precisionChoices,
  }) : body = detachedBody
           ? Map<String, dynamic>.unmodifiable(body)
           : Map<String, dynamic>.from(snapshotJsonValue(body) as Map);
  final String actorId, operation, method, path;
  final String identityField;
  final bool opaqueIdentity;
  final Map<String, dynamic> Function()? cancellationPayload;
  final Map<String, dynamic> body;
  final Map<String, dynamic>? precisionChoices;
  String get requestId => body[identityField]?.toString() ?? '';
  Map<String, dynamic> get cancellationBody =>
      cancellationPayload?.call() ??
      {
        'requestId': requestId,
        'actorId': actorId,
        'operation': operation,
        'method': method,
        'path': path,
        'requestBody': body,
        if (precisionChoices != null) 'precisionChoices': precisionChoices,
      };
  void _verifyMetadata(Map<String, dynamic> receipt) {
    if (body[identityField] is! String ||
        (opaqueIdentity
            ? requestId.isEmpty || requestId.trim() != requestId
            : !Uuid.isValidUUID(fromString: requestId)) ||
        actorId.isEmpty ||
        receipt['found'] != true ||
        receipt['requestId'] != requestId ||
        receipt['actorId'] != actorId ||
        receipt['operation'] != operation ||
        receipt['method'] != method ||
        receipt['path'] != path ||
        !const {
          'SUCCEEDED',
          'CANCELLED_UNWRITTEN',
        }.contains(receipt['outcome']) ||
        !receipt.containsKey('result') ||
        receipt['outcome'] == 'CANCELLED_UNWRITTEN' &&
            (receipt['result'] is! Map ||
                (receipt['result'] as Map)['cancelled'] != true)) {
      throw StateError('原财务回执与账号、目标或请求内容不一致，继续保留原请求');
    }
    if (precisionChoices != null) {
      final context = receipt['precisionContext'];
      if (!jsonValuesEqual(receipt['precisionChoices'], precisionChoices) ||
          context is! Map ||
          context['available'] != true ||
          !jsonValuesEqual(context['choices'], precisionChoices) ||
          context['usedChoices'] is! Map ||
          (context['usedChoices'] as Map).entries.any(
            (entry) =>
                !precisionChoices!.containsKey(entry.key) ||
                !jsonValuesEqual(entry.value, precisionChoices![entry.key]),
          )) {
        throw StateError('原回执精度选择与原请求不一致，继续保留原请求');
      }
    }
  }

  Map<String, dynamic> verify(Map<String, dynamic> receipt) {
    _verifyMetadata(receipt);
    if (!jsonValuesEqual(receipt['requestBody'], body)) {
      throw StateError('原财务回执正文与原请求不一致，继续保留原请求');
    }
    return receipt;
  }

  Future<Map<String, dynamic>> verifyResponsive(
    Map<String, dynamic> receipt, {
    bool Function()? isCurrent,
  }) async {
    _verifyMetadata(receipt);
    if (!await jsonValuesEqualResponsive(
      receipt['requestBody'],
      body,
      isCurrent: isCurrent,
    )) {
      throw StateError('原财务回执正文与原请求不一致，继续保留原请求');
    }
    return receipt;
  }

  /// An old success record can omit the original body. Only after GET proves
  /// that immutable success exists, its typed cancellation adapter verifies the
  /// old fingerprint and returns the full proof; it never cancels that success.
  Future<Map<String, dynamic>> _loadReceipt(
    ApiClient api,
    String receiptPath,
  ) async {
    var receipt = await api.get(receiptPath);
    if (receipt['found'] != true) return receipt;
    if (receipt['requestBody'] is! Map) {
      if (receipt['outcome'] != 'SUCCEEDED' ||
          receipt['requestId'] != requestId ||
          receipt['actorId'] != actorId ||
          receipt['operation'] != operation) {
        throw StateError('原成功回执身份不完整，不能按当前配置代替原结果');
      }
      receipt = await api.post('$receiptPath/cancel', body: cancellationBody);
    }
    return receipt;
  }

  Future<Map<String, dynamic>> readReceipt(
    ApiClient api,
    String receiptPath,
  ) async {
    final receipt = await _loadReceipt(api, receiptPath);
    return receipt['found'] == true ? verify(receipt) : receipt;
  }

  Future<Map<String, dynamic>> readReceiptResponsive(
    ApiClient api,
    String receiptPath, {
    bool Function()? isCurrent,
  }) async {
    final receipt = await _loadReceipt(api, receiptPath);
    if (receipt['found'] == true) {
      return verifyResponsive(receipt, isCurrent: isCurrent);
    }
    return receipt;
  }

  Future<Map<String, dynamic>> cancelUnwritten(
    ApiClient api,
    String receiptPath,
  ) async =>
      verify(await api.post('$receiptPath/cancel', body: cancellationBody));
  Future<Map<String, dynamic>> cancelUnwrittenResponsive(
    ApiClient api,
    String receiptPath, {
    bool Function()? isCurrent,
  }) async => verifyResponsive(
    await api.post('$receiptPath/cancel', body: cancellationBody),
    isCurrent: isCurrent,
  );
}
