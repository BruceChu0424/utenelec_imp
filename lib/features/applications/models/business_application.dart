import '../../../core/utils/china_datetime.dart';

const businessApplicationKinds = <String, String>{
  'TRAVEL': '出差申请',
  'PAYMENT': '付款申请',
  'PREPAYMENT': '预付申请',
  'SUPPLIER_PAYMENT': '供应商付款申请',
};

const businessApplicationWorkflowStages = <String, List<String>>{
  'TRAVEL': ['DEPARTMENT', 'EXECUTIVE', 'FINANCE_RECEIVE'],
  'PAYMENT': [
    'DEPARTMENT',
    'FINANCE_INITIAL',
    'FINANCE_REVIEW',
    'EXECUTIVE',
    'PAYMENT',
  ],
  'PREPAYMENT': [
    'DEPARTMENT',
    'FINANCE_INITIAL',
    'FINANCE_REVIEW',
    'EXECUTIVE',
    'PAYMENT',
  ],
  'SUPPLIER_PAYMENT': [
    'PROCUREMENT',
    'FINANCE_REVIEW',
    'VICE_EXECUTIVE',
    'EXECUTIVE',
    'PAYMENT',
  ],
};

String businessApplicationStageLabel(String? stage, {String? kind}) {
  if (kind == 'SUPPLIER_PAYMENT') {
    if (stage == 'FINANCE_REVIEW') return '财务部意见';
    if (stage == 'EXECUTIVE') return '总经理审批';
  }
  return switch (stage) {
    'DEPARTMENT' => '部门负责人审核',
    'PROCUREMENT' => '采购部意见',
    'FINANCE_INITIAL' => '财务初核',
    'FINANCE_REVIEW' => '财务复核',
    'VICE_EXECUTIVE' => '副总审批',
    'EXECUTIVE' => '总经办批准',
    'FINANCE_RECEIVE' => '财务接收保管',
    'PAYMENT' => '出纳登记付款',
    'FINANCE_POSTING' => '预付账务关联',
    _ => '',
  };
}

List<String> businessApplicationApprovalRoles(String kind) => [
  for (final stage
      in businessApplicationWorkflowStages[kind] ?? const <String>[])
    businessApplicationStageLabel(stage, kind: kind),
];

class BusinessApplicationEvent {
  const BusinessApplicationEvent({
    required this.action,
    required this.actorName,
    required this.occurredAt,
    this.stage,
    this.remark,
    this.round = 0,
  });
  final String action;
  final String actorName;
  final String? stage;
  final String? remark;
  final DateTime occurredAt;
  final int round;
  factory BusinessApplicationEvent.fromJson(Map<String, dynamic> json) =>
      BusinessApplicationEvent(
        action: json['action'] as String,
        actorName: json['actorName'] as String? ?? '',
        occurredAt: ChinaDateTime.tryParse(json['occurredAt'] as String)!,
        stage: json['stage'] as String?,
        remark: json['remark'] as String?,
        round: (json['round'] as num?)?.toInt() ?? 0,
      );
}

class BusinessApplication {
  const BusinessApplication({
    required this.id,
    required this.applicationNo,
    required this.kind,
    required this.title,
    required this.amount,
    required this.status,
    required this.applicantId,
    required this.applicantName,
    required this.createdAt,
    required this.fields,
    this.departmentId,
    this.departmentName,
    this.approvalStage,
    this.approvalStageLabel,
    this.version = 0,
    this.round = 0,
    this.rejectReason,
    this.canApprove = false,
    this.canReject = false,
    this.canReceive = false,
    this.canPay = false,
    this.canCancelPayment = false,
    this.approvalRoutingStale = false,
    this.canLinkFinance = false,
    this.postingStatus = 'NOT_REQUIRED',
    this.events = const [],
    this.financeDocumentId,
    this.submittedAt,
  });
  final String id;
  final String applicationNo;
  final String kind;
  final String title;
  final String amount;
  final String status;
  final String applicantId;
  final String applicantName;
  final String? departmentId;
  final String? departmentName;
  final String? approvalStage;
  final String? approvalStageLabel;
  final Map<String, dynamic> fields;
  final int version;
  final int round;
  final String? rejectReason;
  final bool canApprove;
  final bool canReject;
  final bool canReceive;
  final bool canPay;
  final bool canCancelPayment;
  final bool approvalRoutingStale;
  final bool canLinkFinance;
  final String postingStatus;
  final List<BusinessApplicationEvent> events;
  final String? financeDocumentId;
  final DateTime createdAt;
  final DateTime? submittedAt;
  String get kindLabel => businessApplicationKinds[kind] ?? kind;
  bool get editable => status == 'DRAFT' || status == 'REJECTED';
  String get statusLabel => approvalRoutingStale
      ? '待重新提交'
      : switch (status) {
          'DRAFT' => '草稿',
          'REJECTED' => '待修订',
          'SUBMITTED' || 'REVIEWING' => approvalStageLabel ?? '待审核',
          'APPROVED' => '待付款',
          'PAID' =>
            kind == 'PREPAYMENT' && postingStatus == 'PENDING'
                ? '已付款 待财务入账'
                : '已付款',
          'COMPLETED' => '已归档',
          'CANCELLED' => '已作废',
          _ => status,
        };
  factory BusinessApplication.fromJson(Map<String, dynamic> json) =>
      BusinessApplication(
        id: json['id'] as String,
        applicationNo: json['applicationNo'] as String,
        kind: json['kind'] as String,
        title: json['title'] as String,
        amount: json['amount'].toString(),
        status: json['status'] as String,
        applicantId: json['applicantId'] as String,
        applicantName: json['applicantName'] as String? ?? '',
        departmentId: json['departmentId'] as String?,
        departmentName: json['departmentName'] as String?,
        approvalStage: json['approvalStage'] as String?,
        approvalStageLabel: json['approvalStageLabel'] as String?,
        fields: Map<String, dynamic>.from(json['fields'] as Map? ?? const {}),
        version: (json['version'] as num?)?.toInt() ?? 0,
        round: (json['round'] as num?)?.toInt() ?? 0,
        rejectReason: json['rejectReason'] as String?,
        canApprove: json['canApprove'] == true,
        canReject: json['canReject'] == true,
        canReceive: json['canReceive'] == true,
        canPay: json['canPay'] == true,
        canCancelPayment: json['canCancelPayment'] == true,
        approvalRoutingStale: json['approvalRoutingStale'] == true,
        canLinkFinance: json['canLinkFinance'] == true,
        postingStatus: json['postingStatus'] as String? ?? 'NOT_REQUIRED',
        financeDocumentId: json['financeDocumentId'] as String?,
        createdAt: ChinaDateTime.tryParse(json['createdAt'] as String)!,
        submittedAt: json['submittedAt'] == null
            ? null
            : ChinaDateTime.tryParse(json['submittedAt'] as String),
        events: (json['events'] as List? ?? const [])
            .map(
              (e) => BusinessApplicationEvent.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList(growable: false),
      );
}

class BusinessApplicationInput {
  const BusinessApplicationInput({
    required this.id,
    required this.kind,
    required this.title,
    required this.amount,
    required this.fields,
    this.expectedVersion,
  });
  final String id;
  final String kind;
  final String title;
  final String amount;
  final Map<String, dynamic> fields;
  final int? expectedVersion;
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'title': title,
    'amount': amount,
    'fields': fields,
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
  };
}
