enum QualityInspectionRecordDomain {
  iqc('IQC'),
  fqc('FQC');

  const QualityInspectionRecordDomain(this.wireValue);

  final String wireValue;

  String get label => switch (this) {
    QualityInspectionRecordDomain.iqc => '来料检验(IQC)',
    QualityInspectionRecordDomain.fqc => '成品检验(FQC)',
  };

  static QualityInspectionRecordDomain fromWire(String? value) =>
      value?.toUpperCase() == 'FQC' ? fqc : iqc;
}

class QualityInspectionRecordMetric {
  const QualityInspectionRecordMetric({
    required this.key,
    required this.label,
    required this.value,
    required this.tone,
    this.decisionFilter,
  });

  final String key;
  final String label;
  final int value;
  final String tone;
  final String? decisionFilter;

  factory QualityInspectionRecordMetric.fromJson(Map<String, dynamic> json) =>
      QualityInspectionRecordMetric(
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '',
        value: (json['value'] as num?)?.toInt() ?? 0,
        tone: json['tone'] as String? ?? 'neutral',
        decisionFilter: json['decisionFilter'] as String?,
      );
}

class QualityInspectionRecordPage {
  const QualityInspectionRecordPage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
    required this.metrics,
  });

  final List<QualityInspectionRecord> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;
  final List<QualityInspectionRecordMetric> metrics;

  factory QualityInspectionRecordPage.fromJson(Map<String, dynamic> json) =>
      QualityInspectionRecordPage(
        items: (json['items'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(QualityInspectionRecord.fromJson)
            .toList(growable: false),
        page: (json['page'] as num?)?.toInt() ?? 1,
        size: (json['size'] as num?)?.toInt() ?? 40,
        total: (json['total'] as num?)?.toInt() ?? 0,
        totalPages: (json['totalPages'] as num?)?.toInt() ?? 0,
        metrics: _parseMetrics(json['metrics']),
      );
}

class QualityInspectionRecord {
  const QualityInspectionRecord({
    required this.recordId,
    required this.domain,
    required this.sourceType,
    required this.inspectionId,
    required this.inspectedQty,
    required this.currentPassedQty,
    required this.currentFailedQty,
    required this.currentRemainingQty,
    required this.decision,
    required this.passQty,
    required this.failQty,
    required this.decidedAt,
    required this.currentStatus,
    required this.effective,
    this.sourceId,
    this.sourceItemId,
    this.sourceNo,
    this.sourceDate,
    this.referenceNo,
    this.partnerId,
    this.partnerName,
    this.warehouseId,
    this.warehouseName,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.dispositionCode,
    this.reason,
    this.inspectorEmployeeId,
    this.inspectorName,
    this.sheetNo,
  });

  final String recordId;
  final QualityInspectionRecordDomain domain;
  final String sourceType;
  final String inspectionId;
  final String? sourceId;
  final String? sourceItemId;
  final String? sourceNo;
  final DateTime? sourceDate;
  final String? referenceNo;
  final String? partnerId;
  final String? partnerName;
  final String? warehouseId;
  final String? warehouseName;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double inspectedQty;
  final double currentPassedQty;
  final double currentFailedQty;
  final double currentRemainingQty;
  final String decision;
  final double passQty;
  final double failQty;
  final String? dispositionCode;
  final String? reason;
  final String? inspectorEmployeeId;
  final String? inspectorName;
  final DateTime decidedAt;
  final String currentStatus;
  final bool effective;

  /// FQC 所属品质检查单号（V547；历史任务/IQC 为空）。
  final String? sheetNo;

  factory QualityInspectionRecord.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    DateTime instant(String key) =>
        DateTime.tryParse(json[key]?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    DateTime? date(String key) {
      final value = json[key]?.toString();
      return value == null || value.isEmpty ? null : DateTime.tryParse(value);
    }

    return QualityInspectionRecord(
      recordId: json['recordId'] as String? ?? '',
      domain: QualityInspectionRecordDomain.fromWire(json['domain'] as String?),
      sourceType: json['sourceType'] as String? ?? '',
      inspectionId: json['inspectionId'] as String? ?? '',
      sourceId: json['sourceId'] as String?,
      sourceItemId: json['sourceItemId'] as String?,
      sourceNo: json['sourceNo'] as String?,
      sourceDate: date('sourceDate'),
      referenceNo: json['referenceNo'] as String?,
      partnerId: json['partnerId'] as String?,
      partnerName: json['partnerName'] as String?,
      warehouseId: json['warehouseId'] as String?,
      warehouseName: json['warehouseName'] as String?,
      goodsId: json['goodsId'] as String?,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorId: json['colorId'] as String?,
      colorName: json['colorName'] as String?,
      unitId: json['unitId'] as String?,
      unitName: json['unitName'] as String?,
      inspectedQty: number('inspectedQty'),
      currentPassedQty: number('currentPassedQty'),
      currentFailedQty: number('currentFailedQty'),
      currentRemainingQty: number('currentRemainingQty'),
      decision: json['decision'] as String? ?? '',
      passQty: number('passQty'),
      failQty: number('failQty'),
      dispositionCode: json['dispositionCode'] as String?,
      reason: json['reason'] as String?,
      inspectorEmployeeId: json['inspectorEmployeeId'] as String?,
      inspectorName: json['inspectorName'] as String?,
      decidedAt: instant('decidedAt'),
      currentStatus: json['currentStatus'] as String? ?? '',
      effective: json['effective'] == true,
      sheetNo: json['sheetNo'] as String?,
    );
  }

  String get sourceTypeLabel => switch (sourceType) {
    'PURCHASE' => '采购来料',
    'SUBCONTRACT' => '委外回厂',
    'PRODUCTION' => '生产成品',
    _ => sourceType.isEmpty ? domain.label : sourceType,
  };

  String get decisionLabel => switch (decision) {
    'PASS' => '合格',
    'PARTIAL' => '部分合格',
    'FAIL' => '不合格',
    'CANCELLED' => '已撤销',
    _ => decision,
  };

  String get currentStatusLabel => switch (currentStatus) {
    'PENDING' => '待检',
    'PARTIAL' => '部分已决定',
    'RESOLVED' => '已结案',
    'REVERSED' => '收货已红冲',
    'CANCELLED' => '来源已红冲',
    _ => currentStatus,
  };

  String get effectLabel => decision == 'CANCELLED'
      ? '撤销有效'
      : effective
      ? '当前有效'
      : '历史失效';

  String get dispositionLabel => switch (dispositionCode) {
    'REWORK' => '返工',
    'SCRAP' => '报废',
    'REJECT' => '拒收/退回',
    'SOURCE_REPORT_REVERSED' => '来源报工红冲',
    'REGISTRATION_REVERSED' => '送检登记撤回',
    'RECEIPT_REVERSED' => '收货红冲',
    null || '' => '—',
    _ => dispositionCode!,
  };
}

List<QualityInspectionRecordMetric> _parseMetrics(Object? raw) {
  if (raw is List) {
    return raw
        .whereType<Map<String, dynamic>>()
        .map(QualityInspectionRecordMetric.fromJson)
        .toList(growable: false);
  }
  if (raw is! Map) return const [];
  const definitions =
      <({String key, String label, String tone, String? decisionFilter})>[
        (key: 'ALL', label: '全部记录', tone: 'info', decisionFilter: null),
        (key: 'PASS', label: '合格记录', tone: 'success', decisionFilter: 'PASS'),
        (
          key: 'PARTIAL',
          label: '部分合格',
          tone: 'warning',
          decisionFilter: 'PARTIAL',
        ),
        (key: 'FAIL', label: '不合格记录', tone: 'danger', decisionFilter: 'FAIL'),
        (
          key: 'CANCELLED',
          label: '已撤销',
          tone: 'neutral',
          decisionFilter: 'CANCELLED',
        ),
      ];
  return [
    for (final definition in definitions)
      QualityInspectionRecordMetric(
        key: definition.key,
        label: definition.label,
        value: (raw[definition.key] as num?)?.toInt() ?? 0,
        tone: definition.tone,
        decisionFilter: definition.decisionFilter,
      ),
  ];
}
