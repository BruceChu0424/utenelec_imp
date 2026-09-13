/// Exact stock posting source; quantities use the original DRAW display unit.
class ProductionMaterialReturnSource {
  ProductionMaterialReturnSource.fromJson(Map<String, dynamic> json)
    : issuePostingId = json['issuePostingId'] as String,
      demandId = json['demandId'] as String,
      drawId = json['drawId'] as String,
      drawNo = json['drawNo'] as String? ?? '—',
      drawItemId = json['drawItemId'] as String,
      warehouseId = json['warehouseId'] as String,
      warehouseName = json['warehouseName'] as String? ?? '—',
      goodsId = json['goodsId'] as String,
      goodsCode = json['goodsCode'] as String? ?? '—',
      goodsName = json['goodsName'] as String? ?? '—',
      colorId = json['colorId'] as String?,
      colorName = json['colorName'] as String? ?? '—',
      unitId = json['unitId'] as String?,
      unitName = json['unitName'] as String? ?? '单位待核实',
      unitRate = (json['unitRate'] as num).toDouble(),
      issuedQty = (json['issuedQty'] as num).toDouble(),
      unsettledQty = (json['unsettledQty'] as num).toDouble(),
      pendingReturnQty = (json['pendingReturnQty'] as num).toDouble(),
      availableQty = (json['availableQty'] as num).toDouble(),
      returnBlockedReason = json['returnBlockedReason'] as String?;

  final String issuePostingId, demandId, drawId, drawNo, drawItemId;
  final String warehouseId, warehouseName, goodsId, goodsCode, goodsName;
  final String? colorId, unitId;
  final String colorName, unitName;
  final String? returnBlockedReason;
  final double unitRate,
      issuedQty,
      unsettledQty,
      pendingReturnQty,
      availableQty;
}

class ProductionMaterialReturnLine {
  ProductionMaterialReturnLine.fromJson(Map<String, dynamic> json)
    : itemId = json['itemId'] as String,
      issuePostingId = json['issuePostingId'] as String,
      demandId = json['demandId'] as String,
      drawItemId = json['drawItemId'] as String,
      goodsCode = json['goodsCode'] as String? ?? '—',
      goodsName = json['goodsName'] as String? ?? '—',
      colorName = json['colorName'] as String? ?? '—',
      unitName = json['unitName'] as String? ?? '单位待核实',
      qty = (json['qty'] as num).toDouble(),
      baseQty = (json['baseQty'] as num).toDouble();

  final String itemId, issuePostingId, demandId, drawItemId;
  final String goodsCode, goodsName, colorName, unitName;
  final double qty, baseQty;
}

class ProductionMaterialReturnDocument {
  ProductionMaterialReturnDocument.fromJson(Map<String, dynamic> json)
    : documentId = json['documentId'] as String,
      documentNo = json['documentNo'] as String? ?? '—',
      warehouseId = json['warehouseId'] as String,
      warehouseName = json['warehouseName'] as String? ?? '—',
      status = json['status'] as String,
      lines = (json['lines'] as List)
          .map(
            (line) => ProductionMaterialReturnLine.fromJson(
              Map<String, dynamic>.from(line as Map),
            ),
          )
          .toList(growable: false);

  final String documentId, documentNo, warehouseId, warehouseName, status;
  final List<ProductionMaterialReturnLine> lines;
  bool get pending => status == 'PENDING';
  String get statusLabel => switch (status) {
    'PENDING' => '待仓库收料',
    'RECEIVED' => '仓库已收料',
    'CANCELLED' => '已撤回',
    'REVERSED' => '已红冲',
    _ => status,
  };
}
