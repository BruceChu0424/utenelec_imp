/// Quantities in a closure request stay exact and are always computed by the server.
class ProcurementOrderClosureLine {
  const ProcurementOrderClosureLine({
    required this.orderItemId,
    required this.lineNo,
    required this.goodsCode,
    required this.goodsName,
    required this.unitName,
    required this.orderedQty,
    required this.receivedQty,
    required this.remainingQty,
    required this.remainingGiftQty,
    this.returnedQty = '0',
    this.settledLossQty = '0',
    this.giftQty = '0',
    this.giftReceivedQty = '0',
    this.giftReturnedQty = '0',
  });

  final String orderItemId;
  final int lineNo;
  final String goodsCode;
  final String goodsName;
  final String unitName;
  final String orderedQty;
  final String receivedQty;
  final String? remainingQty;
  final String? remainingGiftQty;
  final String returnedQty;
  final String settledLossQty;
  final String giftQty;
  final String giftReceivedQty;
  final String giftReturnedQty;

  factory ProcurementOrderClosureLine.fromJson(Map<String, dynamic> json) =>
      ProcurementOrderClosureLine(
        orderItemId: json['orderItemId']?.toString() ?? '',
        lineNo: (json['lineNo'] as num?)?.toInt() ?? 0,
        goodsCode: json['goodsCode']?.toString() ?? '',
        goodsName: json['goodsName']?.toString() ?? '',
        unitName: json['unitName']?.toString() ?? '',
        orderedQty: json['orderedQty']?.toString() ?? '0',
        receivedQty: json['receivedQty']?.toString() ?? '0',
        remainingQty: json['remainingQty']?.toString(),
        remainingGiftQty: json['remainingGiftQty']?.toString(),
        returnedQty: json['returnedQty']?.toString() ?? '0',
        settledLossQty: json['settledLossQty']?.toString() ?? '0',
        giftQty: json['giftQty']?.toString() ?? '0',
        giftReceivedQty: json['giftReceivedQty']?.toString() ?? '0',
        giftReturnedQty: json['giftReturnedQty']?.toString() ?? '0',
      );
}

class ProcurementOrderClosureTarget {
  const ProcurementOrderClosureTarget({
    required this.orderType,
    required this.orderId,
    this.billNo = '',
    this.localRevision = '',
  });
  final String orderType;
  final String orderId;
  final String billNo;
  final String localRevision;
  String get identity => '$orderType:$orderId';
  Map<String, dynamic> toJson() => {'orderType': orderType, 'orderId': orderId};
}

List<ProcurementOrderClosureTarget> uniqueProcurementClosureTargets(
  Iterable<ProcurementOrderClosureTarget> targets,
) => {
  for (final target in targets) target.identity: target,
}.values.toList(growable: false);

class ProcurementOrderClosurePreview {
  const ProcurementOrderClosurePreview({
    required this.billNo,
    required this.fingerprint,
    required this.canSubmit,
    required this.items,
    this.blockReason,
    this.canReorder = true,
    this.unverifiedQuantity = false,
    this.blockReorderReason,
    this.blocker,
  });

  final String billNo;
  final String fingerprint;
  final bool canSubmit;
  final String? blockReason;
  final bool canReorder;
  final bool unverifiedQuantity;
  final String? blockReorderReason;
  final ProcurementOrderClosureBlocker? blocker;
  final List<ProcurementOrderClosureLine> items;

  factory ProcurementOrderClosurePreview.fromJson(Map<String, dynamic> json) =>
      ProcurementOrderClosurePreview(
        billNo: json['billNo']?.toString() ?? '',
        fingerprint: json['fingerprint']?.toString() ?? '',
        canSubmit:
            json['canSubmit'] == true &&
            (json['fingerprint']?.toString().isNotEmpty ?? false),
        blockReason: json['blockReason']?.toString(),
        canReorder: json['canReorder'] != false,
        unverifiedQuantity: json['unverifiedQuantity'] == true,
        blockReorderReason: json['blockReorderReason']?.toString(),
        blocker: json['blocker'] is Map
            ? ProcurementOrderClosureBlocker.fromJson(
                (json['blocker'] as Map).cast<String, dynamic>(),
              )
            : null,
        items: [
          for (final item in json['items'] as List? ?? const [])
            if (item is Map)
              ProcurementOrderClosureLine.fromJson(
                item.cast<String, dynamic>(),
              ),
        ],
      );
}

class ProcurementOrderClosureBlocker {
  const ProcurementOrderClosureBlocker({
    required this.kind,
    required this.orderType,
    required this.orderId,
    this.billNo,
    this.documentId,
  });

  final String kind;
  final String orderType;
  final String orderId;
  final String? billNo;
  final String? documentId;

  factory ProcurementOrderClosureBlocker.fromJson(Map<String, dynamic> json) =>
      ProcurementOrderClosureBlocker(
        kind: json['kind']?.toString() ?? '',
        orderType: json['orderType']?.toString() ?? '',
        orderId: json['orderId']?.toString() ?? '',
        billNo: json['billNo']?.toString(),
        documentId: json['documentId']?.toString(),
      );
}

class ProcurementOrderClosureRequest {
  const ProcurementOrderClosureRequest({
    required this.caseId,
    required this.status,
    required this.mode,
    this.reason,
    this.rejectionReason,
    this.replacementOrderId,
    this.replacementBillNo,
    this.executionMode,
    this.closedByName,
    this.closedAt,
    this.unverifiedQuantity = false,
    this.items = const [],
  });

  final String caseId;
  final String status;
  final String mode;
  final String? reason;
  final String? rejectionReason;
  final String? replacementOrderId;
  final String? replacementBillNo;
  final String? executionMode;
  final String? closedByName;
  final String? closedAt;
  final bool unverifiedQuantity;
  final List<ProcurementOrderClosureLine> items;
  bool get isDirect => executionMode == 'DIRECT';
  bool get isPending => status == 'PENDING';
  bool get isApproved => status == 'APPROVED';
  bool get isRejected => status == 'REJECTED';
  bool get isCanceled => status == 'CANCELED';

  factory ProcurementOrderClosureRequest.fromJson(Map<String, dynamic> json) =>
      ProcurementOrderClosureRequest(
        caseId: json['caseId']?.toString() ?? '',
        status: json['status']?.toString() ?? '',
        mode: json['mode']?.toString() ?? '',
        reason: json['reason']?.toString(),
        rejectionReason: json['rejectionReason']?.toString(),
        replacementOrderId: json['replacementOrderId']?.toString(),
        replacementBillNo: json['replacementBillNo']?.toString(),
        executionMode: json['executionMode']?.toString(),
        closedByName: json['closedByName']?.toString(),
        closedAt: json['closedAt']?.toString(),
        unverifiedQuantity: json['unverifiedQuantity'] == true,
        items: [
          for (final item in json['items'] as List? ?? const [])
            if (item is Map)
              ProcurementOrderClosureLine.fromJson(
                item.cast<String, dynamic>(),
              ),
        ],
      );
}
