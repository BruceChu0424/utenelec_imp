/// V189 销售退货质检冻结投影。
///
/// 数量字段均为库存基本单位数量；冻结量不属于可售库存，只有 GOOD_RELEASE
/// 才会由服务端记库存入库。历史退货可能没有任何投影行，客户端不得据此补造事实。
class SalesReturnQualityItem {
  const SalesReturnQualityItem({
    required this.id,
    required this.returnId,
    required this.returnItemId,
    required this.warehouseId,
    required this.goodsId,
    required this.colorId,
    required this.unitId,
    required this.unitRate,
    required this.receivedBaseQty,
    required this.releasedBaseQty,
    required this.scrappedBaseQty,
    required this.reworkBaseQty,
    required this.remainingBaseQty,
    required this.status,
    required this.receivedAt,
    required this.updatedAt,
  });

  final String id;
  final String returnId;
  final String returnItemId;
  final String warehouseId;
  final String goodsId;
  final String? colorId;
  final String? unitId;
  final double unitRate;
  final double receivedBaseQty;
  final double releasedBaseQty;
  final double scrappedBaseQty;
  final double reworkBaseQty;
  final double remainingBaseQty;
  final String status;
  final String? receivedAt;
  final String? updatedAt;

  double get disposedBaseQty =>
      releasedBaseQty + scrappedBaseQty + reworkBaseQty;

  bool get canDispose =>
      remainingBaseQty > 0 && (status == 'PENDING' || status == 'PARTIAL');

  /// 只有服务端明确返回“待质检且从未处置”的新流程收货才可直接红冲。
  /// 未识别状态按不安全处理；历史退货由“无投影行”分支兼容。
  bool get blocksDirectReturnReversal =>
      status != 'PENDING' || disposedBaseQty > 0;

  factory SalesReturnQualityItem.fromJson(Map<String, dynamic> json) =>
      SalesReturnQualityItem(
        id: json['id'] as String,
        returnId: json['returnId'] as String,
        returnItemId: json['returnItemId'] as String,
        warehouseId: json['warehouseId'] as String,
        goodsId: json['goodsId'] as String,
        colorId: json['colorId'] as String?,
        unitId: json['unitId'] as String?,
        unitRate: _number(json, 'unitRate'),
        receivedBaseQty: _number(json, 'receivedBaseQty'),
        releasedBaseQty: _number(json, 'releasedBaseQty'),
        scrappedBaseQty: _number(json, 'scrappedBaseQty'),
        reworkBaseQty: _number(json, 'reworkBaseQty'),
        remainingBaseQty: _number(json, 'remainingBaseQty'),
        status: json['status'] as String,
        receivedAt: json['receivedAt'] as String?,
        updatedAt: json['updatedAt'] as String?,
      );

  static double _number(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw FormatException('Invalid numeric field: $key');
  }
}

enum SalesReturnQualityAction {
  goodRelease('GOOD_RELEASE', '良品释放'),
  scrap('SCRAP', '报废'),
  rework('REWORK', '返工');

  const SalesReturnQualityAction(this.code, this.label);

  final String code;
  final String label;
}

String salesReturnQualityStatusLabel(String status) => switch (status) {
  'PENDING' => '待质检',
  'PARTIAL' => '部分处置',
  'DISPOSED' => '已全部处置',
  'REVERSED' => '收货已撤销',
  _ => '未知状态',
};
