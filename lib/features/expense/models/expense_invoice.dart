// 报销发票登记模型（V608）
// 文档：docs/04-数据模型/实体字典.md#ExpenseClaimInvoice
//
// 号码口径（国家税务总局公告 2024 年第 11 号）：
// - 数电票：20 位号码、无发票代码（invoiceCode 为空）；
// - 纸质/旧电子票：8 位号码 + 10/12 位发票代码。
// 「代码+号码」在存活报销单间唯一（后端唯一索引）= 防重复报销。

/// 发票类型
enum ExpenseInvoiceType {
  /// 增值税电子普通发票（旧版式）
  general('增值税电子普票'),

  /// 增值税专用发票（电子）
  special('增值税专票'),

  /// 全面数字化电子发票（数电票，20 位号码）
  digital('数电发票'),

  /// 纸质普通发票
  paperGeneral('纸质普票'),

  /// 纸质专用发票
  paperSpecial('纸质专票'),

  /// 其他票据（行程单、定额发票、财政票据等）
  other('其他票据');

  const ExpenseInvoiceType(this.label);
  final String label;

  String get apiValue => switch (this) {
    ExpenseInvoiceType.general => 'GENERAL',
    ExpenseInvoiceType.special => 'SPECIAL',
    ExpenseInvoiceType.digital => 'DIGITAL',
    ExpenseInvoiceType.paperGeneral => 'PAPER_GENERAL',
    ExpenseInvoiceType.paperSpecial => 'PAPER_SPECIAL',
    ExpenseInvoiceType.other => 'OTHER',
  };

  static ExpenseInvoiceType fromApi(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    return switch (normalized) {
      'GENERAL' => ExpenseInvoiceType.general,
      'SPECIAL' => ExpenseInvoiceType.special,
      'DIGITAL' => ExpenseInvoiceType.digital,
      'PAPER_GENERAL' => ExpenseInvoiceType.paperGeneral,
      'PAPER_SPECIAL' => ExpenseInvoiceType.paperSpecial,
      'OTHER' => ExpenseInvoiceType.other,
      _ => ExpenseInvoiceType.other,
    };
  }
}

/// 查验/勾稽状态
enum ExpenseInvoiceCheckState {
  /// 未查验
  unchecked('未查验'),

  amountsMatch('金额勾稽相符'),

  /// 金额勾稽核对通过（不含税 + 税额 = 价税合计）
  verified('已人工查验'),

  /// 票面勾稽不符（供审批人复核）
  mismatch('勾稽不符');

  const ExpenseInvoiceCheckState(this.label);
  final String label;

  static ExpenseInvoiceCheckState fromApi(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    return switch (normalized) {
      'AMOUNTS_MATCH' => ExpenseInvoiceCheckState.amountsMatch,
      'VERIFIED_MANUAL' => ExpenseInvoiceCheckState.verified,
      'MISMATCH' => ExpenseInvoiceCheckState.mismatch,
      _ => ExpenseInvoiceCheckState.unchecked,
    };
  }
}

/// 报销单发票登记行
class ExpenseClaimInvoice {
  const ExpenseClaimInvoice({
    required this.id,
    required this.lineNo,
    required this.type,
    this.invoiceCode,
    required this.invoiceNo,
    this.issueDate,
    this.sellerName,
    this.sellerTaxNo,
    this.buyerName,
    this.buyerTaxNo,
    this.amountExclTax,
    this.taxAmount,
    required this.totalAmount,
    required this.checkState,
    this.verificationRemark,
    this.verifiedAt,
    this.verifiedByName,
    this.attachmentId,
    this.remark,
  });

  final String id;
  final int lineNo;
  final ExpenseInvoiceType type;

  /// 发票代码（数电票为空）
  final String? invoiceCode;

  /// 发票号码（8 位老票 / 20 位数电票）
  final String invoiceNo;
  final DateTime? issueDate;
  final String? sellerName;
  final String? sellerTaxNo;
  final String? buyerName;
  final String? buyerTaxNo;
  final double? amountExclTax;
  final double? taxAmount;
  final double totalAmount;
  final ExpenseInvoiceCheckState checkState;
  final String? verificationRemark;
  final DateTime? verifiedAt;
  final String? verifiedByName;

  /// 关联发票影像附件 id
  final String? attachmentId;
  final String? remark;

  factory ExpenseClaimInvoice.fromJson(Map<String, dynamic> json) =>
      ExpenseClaimInvoice(
        id: json['id'] as String,
        lineNo: (json['lineNo'] as num?)?.toInt() ?? 0,
        type: ExpenseInvoiceType.fromApi(json['invoiceType']),
        invoiceCode: (json['invoiceCode'] as String?)?.trim().isEmpty == true
            ? null
            : json['invoiceCode'] as String?,
        invoiceNo: json['invoiceNo'] as String,
        issueDate: _date(json['issueDate']),
        sellerName: json['sellerName'] as String?,
        sellerTaxNo: json['sellerTaxNo'] as String?,
        buyerName: json['buyerName'] as String?,
        buyerTaxNo: json['buyerTaxNo'] as String?,
        amountExclTax: (json['amountExclTax'] as num?)?.toDouble(),
        taxAmount: (json['taxAmount'] as num?)?.toDouble(),
        totalAmount: (json['totalAmount'] as num).toDouble(),
        checkState: ExpenseInvoiceCheckState.fromApi(json['checkState']),
        verificationRemark: json['verificationRemark'] as String?,
        verifiedAt: DateTime.tryParse(json['verifiedAt'] as String? ?? ''),
        verifiedByName: json['verifiedByName'] as String?,
        attachmentId: json['attachmentId'] as String?,
        remark: json['remark'] as String?,
      );

  static DateTime? _date(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}

/// 发票登记/修改入参
class ExpenseClaimInvoiceInput {
  const ExpenseClaimInvoiceInput({
    required this.type,
    this.invoiceCode,
    required this.invoiceNo,
    this.issueDate,
    this.sellerName,
    this.sellerTaxNo,
    this.buyerName,
    this.buyerTaxNo,
    this.amountExclTax,
    this.taxAmount,
    required this.totalAmount,
    this.attachmentId,
    this.remark,
    this.expectedVersion,
  });

  final ExpenseInvoiceType type;
  final String? invoiceCode;
  final String invoiceNo;
  final DateTime? issueDate;
  final String? sellerName;
  final String? sellerTaxNo;
  final String? buyerName;
  final String? buyerTaxNo;
  final double? amountExclTax;
  final double? taxAmount;
  final double totalAmount;
  final String? attachmentId;
  final String? remark;
  final int? expectedVersion;

  Map<String, dynamic> toJson() => {
    'invoiceType': type.apiValue,
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
    'invoiceCode': invoiceCode,
    'invoiceNo': invoiceNo,
    'issueDate': issueDate == null ? null : _dateOnly(issueDate!),
    'sellerName': sellerName,
    'sellerTaxNo': sellerTaxNo,
    'buyerName': buyerName,
    'buyerTaxNo': buyerTaxNo,
    'amountExclTax': amountExclTax,
    'taxAmount': taxAmount,
    'totalAmount': totalAmount,
    'attachmentId': attachmentId,
    'remark': remark,
  };
}

/// 发票查重预检结果（登记表单即时提示）
class ExpenseInvoiceCheckResult {
  const ExpenseInvoiceCheckResult({
    required this.duplicated,
    this.heldByClaimNo,
    this.heldByStatus,
    this.heldByApplicantName,
  });

  final bool duplicated;
  final String? heldByClaimNo;
  final String? heldByStatus;
  final String? heldByApplicantName;

  factory ExpenseInvoiceCheckResult.fromJson(Map<String, dynamic> json) =>
      ExpenseInvoiceCheckResult(
        duplicated: json['duplicated'] == true,
        heldByClaimNo: json['heldByClaimNo'] as String?,
        heldByStatus: json['heldByStatus'] as String?,
        heldByApplicantName: json['heldByApplicantName'] as String?,
      );
}

/// OCR 识别结果（预填建议，字段可空）
class RecognizedInvoice {
  const RecognizedInvoice({
    this.type,
    this.invoiceCode,
    this.invoiceNo,
    this.issueDate,
    this.sellerName,
    this.sellerTaxNo,
    this.buyerName,
    this.buyerTaxNo,
    this.amountExclTax,
    this.taxAmount,
    this.totalAmount,
    this.itemSummary,
  });

  final ExpenseInvoiceType? type;
  final String? invoiceCode;
  final String? invoiceNo;
  final DateTime? issueDate;
  final String? sellerName;
  final String? sellerTaxNo;
  final String? buyerName;
  final String? buyerTaxNo;
  final double? amountExclTax;
  final double? taxAmount;
  final double? totalAmount;
  final String? itemSummary;

  factory RecognizedInvoice.fromJson(Map<String, dynamic> json) =>
      RecognizedInvoice(
        type: json['invoiceType'] == null
            ? null
            : ExpenseInvoiceType.fromApi(json['invoiceType']),
        invoiceCode: (json['invoiceCode'] as String?)?.trim().isEmpty == true
            ? null
            : json['invoiceCode'] as String?,
        invoiceNo: (json['invoiceNo'] as String?)?.trim().isEmpty == true
            ? null
            : json['invoiceNo'] as String?,
        issueDate:
            json['issueDate'] is String &&
                (json['issueDate'] as String).isNotEmpty
            ? DateTime.tryParse(json['issueDate'] as String)
            : null,
        sellerName: json['sellerName'] as String?,
        sellerTaxNo: json['sellerTaxNo'] as String?,
        buyerName: json['buyerName'] as String?,
        buyerTaxNo: json['buyerTaxNo'] as String?,
        amountExclTax: (json['amountExclTax'] as num?)?.toDouble(),
        taxAmount: (json['taxAmount'] as num?)?.toDouble(),
        totalAmount: (json['totalAmount'] as num?)?.toDouble(),
        itemSummary: json['itemSummary'] as String?,
      );
}

String _dateOnly(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
