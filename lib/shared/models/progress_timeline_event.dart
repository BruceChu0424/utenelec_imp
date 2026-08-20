// 全链路进度时间线事件（快递式追踪）。镜像后端 OrderProgressTimelineEvent：
// 每条 = 阶段标题 + 责任人（operatorLabel/operatorName，如 下单人/审核人/采购人）
// + 发生时间 + 状态 + 补充说明 + 可跳转单据锚点（docType/docId/docNo）。
//
// 服务端已排好展示顺序：已发生事件按时间倒序（最新在最上，无时间的当前阶段置顶），
// PENDING 占位按业务顺序垫底；前端按数组顺序直接渲染，不再重排。
class ProgressTimelineEvent {
  const ProgressTimelineEvent({
    required this.seq,
    required this.code,
    required this.title,
    this.operatorLabel,
    this.operatorName,
    this.occurredAt,
    required this.state,
    this.detail,
    this.docType,
    this.docId,
    this.docNo,
  });

  /// 业务顺序（下单→…→结案递增），同刻事件稳定排序与 PENDING 占位排序用。
  final int seq;
  final String code;
  final String title;

  /// 责任人角色（下单人/审核人/执行人/采购人/发货人…），无责任人的派生阶段为 null。
  final String? operatorLabel;

  /// 责任人姓名；历史数据缺人时为 null（UI 显示「—」）。
  final String? operatorName;

  /// 发生时间（ISO 字符串，UTC）；当前进行/未到阶段可为 null。
  final String? occurredAt;

  /// DONE / CURRENT / PENDING / REJECTED。
  final String state;

  /// 补充说明（审批人、物流单号、已产/订货等）。
  final String? detail;

  /// 可跳转单据锚点：SALES_SHIPMENT / PURCHASE_ORDER / SUBCONTRACT_ORDER /
  /// PRODUCTION_PLAN / MATERIAL_ANALYSIS；无跳转则为 null。
  final String? docType;
  final String? docId;
  final String? docNo;

  bool get isDone => state == 'DONE';
  bool get isCurrent => state == 'CURRENT';
  bool get isPending => state == 'PENDING';
  bool get isRejected => state == 'REJECTED';

  /// 是否有可跳转的关联单据。
  bool get hasDoc => docType != null && docId != null && docId!.isNotEmpty;

  factory ProgressTimelineEvent.fromJson(Map<String, dynamic> json) =>
      ProgressTimelineEvent(
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        code: json['code'] as String? ?? '',
        title: json['title'] as String? ?? '',
        operatorLabel: json['operatorLabel'] as String?,
        operatorName: json['operatorName'] as String?,
        occurredAt: json['occurredAt'] as String?,
        state: (json['state'] as String? ?? 'PENDING').toUpperCase(),
        detail: json['detail'] as String?,
        docType: json['docType'] as String?,
        docId: json['docId'] as String?,
        docNo: json['docNo'] as String?,
      );
}
