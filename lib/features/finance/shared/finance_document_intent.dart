import 'package:uuid/uuid.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/original_command.dart';
import '../../../core/performance/json_value_snapshot.dart';
import '../models/finance_doc.dart';

/// A financial document command always belongs to one displayed generation.
/// Configuration forms and batch grouping use their own published contracts.
class FinanceDocumentIntent {
  FinanceDocumentIntent({
    required this.type,
    required this.documentId,
    required this.actorId,
    required this.operation,
    required this.body,
    required this.precisionChoices,
  });
  final FinanceDocType type;
  final String documentId, actorId, operation;
  final Map<String, dynamic> body;
  Map<String, dynamic> precisionChoices;
  String get requestId => body['requestId'] as String;
  String get family => switch (type) {
    FinanceDocType.receipt => 'financeReceipt',
    FinanceDocType.payment => 'financePayment',
    FinanceDocType.expense => 'financeExpense',
    FinanceDocType.otherIncome => 'financeOtherIncome',
    FinanceDocType.bankTransfer => 'financeBankTransfer',
  };
  String get method => operation == 'FINANCE_DOCUMENT_DELETE'
      ? 'DELETE'
      : operation == 'FINANCE_DOCUMENT_UPDATE'
      ? 'PUT'
      : 'POST';
  String get path => switch (operation) {
    'FINANCE_DOCUMENT_UNAPPROVE' => '/documents/$family/$documentId/unapprove',
    'FINANCE_DOCUMENT_APPROVE' =>
      '/finance/${type.pathSegment}/$documentId/approve',
    'FINANCE_DOCUMENT_UPDATE' => '/finance/${type.pathSegment}/$documentId',
    'FINANCE_DOCUMENT_DELETE' => '/finance/${type.pathSegment}/$documentId',
    'FINANCE_DOCUMENT_GL_CONFIRM' when type == FinanceDocType.expense =>
      '/finance/expenses/$documentId/gl-confirm',
    _ => throw StateError('财务操作与单据种类不一致'),
  };
  String get receiptPath =>
      '/finance/${type.pathSegment}/$documentId/review-operations/$requestId';
  OriginalCommand get original => OriginalCommand(
    actorId: actorId,
    operation: operation,
    method: method,
    path: path,
    body: body,
    detachedBody: true,
    precisionChoices: precisionChoices,
  );
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'segment': type.pathSegment,
    'documentId': documentId,
    'actorId': actorId,
    'operation': operation,
    'body': body,
    'precisionChoices': precisionChoices,
  };
  static FinanceDocumentIntent restore(
    Object? value, {
    required FinanceDocType type,
    required String documentId,
    required String actorId,
    required Map<String, dynamic> choices,
    required String expectedOperation,
  }) {
    if (value is! Map ||
        value['schema'] != 1 ||
        value['segment'] != type.pathSegment ||
        value['documentId'] != documentId ||
        value['actorId'] != actorId ||
        value['operation'] != expectedOperation ||
        value['body'] is! Map ||
        !const {
          'FINANCE_DOCUMENT_APPROVE',
          'FINANCE_DOCUMENT_UNAPPROVE',
          'FINANCE_DOCUMENT_UPDATE',
          'FINANCE_DOCUMENT_GL_CONFIRM',
          'FINANCE_DOCUMENT_DELETE',
        }.contains(value['operation']) ||
        value['operation'] == 'FINANCE_DOCUMENT_GL_CONFIRM' &&
            type != FinanceDocType.expense ||
        !jsonValuesEqual(value['precisionChoices'], choices)) {
      throw const FormatException('原财务单据请求、身份或精度依据不完整');
    }
    final body = Map<String, dynamic>.from(value['body'] as Map);
    if (body['requestId'] is! String ||
        !Uuid.isValidUUID(fromString: body['requestId'] as String)) {
      throw const FormatException('原财务单据请求缺少编号');
    }
    return FinanceDocumentIntent(
      type: type,
      documentId: documentId,
      actorId: actorId,
      operation: value['operation'] as String,
      body: body,
      precisionChoices: choices,
    );
  }

  void validateReviewedDetail(
    FinanceDocDetail detail, {
    String? factsSnapshot,
  }) {
    final expectedKeys = operation == 'FINANCE_DOCUMENT_UNAPPROVE'
        ? {'requestId', 'idempotencyKey', 'reason', 'expectedSnapshot'}
        : {
            'requestId',
            'expectedVersion',
            'expectedSnapshot',
            if (operation == 'FINANCE_DOCUMENT_UPDATE') 'document',
          };
    if (detail.id != documentId ||
        operation == 'FINANCE_DOCUMENT_GL_CONFIRM' &&
            (type != FinanceDocType.expense ||
                detail.status != 1 ||
                detail.glStatus != 1) ||
        operation == 'FINANCE_DOCUMENT_DELETE' &&
            (detail.status != 0 || detail.deleted) ||
        body.length != expectedKeys.length ||
        !body.keys.toSet().containsAll(expectedKeys) ||
        body['expectedSnapshot'] !=
            (operation == 'FINANCE_DOCUMENT_UNAPPROVE'
                ? factsSnapshot
                : detail.approvalSnapshot) ||
        operation != 'FINANCE_DOCUMENT_UNAPPROVE' &&
            !jsonValuesEqual(body['expectedVersion'], detail.approvalVersion) ||
        operation == 'FINANCE_DOCUMENT_UNAPPROVE' &&
            (body['idempotencyKey'] != requestId ||
                body['reason'] is! String) ||
        operation == 'FINANCE_DOCUMENT_UPDATE' &&
            (body['document'] is! Map ||
                (type == FinanceDocType.receipt ||
                        type == FinanceDocType.payment) &&
                    !jsonValuesEqual(
                      (body['document'] as Map)['expectedVersion'],
                      detail.approvalVersion,
                    ))) {
      throw const FormatException('原财务操作、正文和所查看版本不一致，原草稿继续保留');
    }
  }

  Future<Map<String, dynamic>> receipt(
    ApiClient api, {
    bool Function()? isCurrent,
  }) => original.readReceiptResponsive(api, receiptPath, isCurrent: isCurrent);
  Future<Map<String, dynamic>> cancel(
    ApiClient api, {
    bool Function()? isCurrent,
  }) => original.cancelUnwrittenResponsive(
    api,
    receiptPath,
    isCurrent: isCurrent,
  );
}

bool financeDocumentHasReviewSnapshot(
  FinanceDocDetail detail, {
  FinanceDocType? type,
}) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(detail.approvalSnapshot ?? '') ||
      detail.sourceJson == null) {
    return false;
  }
  if (type == null) return true;
  final scope = switch (type) {
    FinanceDocType.receipt => 'finance_receipt',
    FinanceDocType.payment => 'finance_payment',
    FinanceDocType.expense => 'finance_expense',
    FinanceDocType.otherIncome => 'finance_other_income',
    FinanceDocType.bankTransfer => 'finance_bank_transfer',
  };
  final header = detail.approvalPlatformFields[scope];
  final items = detail.approvalPlatformFields['${scope}_item'];
  return header is List &&
      header.whereType<Map<Object?, Object?>>().any(
        (row) => row['recordId'] == detail.id && row['cells'] is List,
      ) &&
      items is List &&
      detail.items.every(
        (item) =>
            item.id != null &&
            items.whereType<Map<Object?, Object?>>().any(
              (row) => row['recordId'] == item.id && row['cells'] is List,
            ),
      );
}

String financeDocumentPrecisionLabel(Map<String, dynamic> envelope) {
  final context = envelope['precisionContext'];
  if (context is! Map ||
      context['available'] != true ||
      context['usedChoices'] is! Map) {
    return '';
  }
  final used = context['usedChoices'] as Map;
  if (used.isEmpty) return '';
  final descriptions = used.values.map((value) {
    final choice = value as Map;
    return '${choice['scale']}位${choice['rounding'] == 'DOWN' ? '截断' : '四舍五入'}';
  }).toSet();
  return '（原计算精度：${descriptions.join('；')}）';
}
