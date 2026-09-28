// 新建盘点单的预填 (ADR-135 §6.4): 库存分析「盘点建议 -> 生成盘点单」按仓库带着
// 建议盘点的货品 (货品 + 颜色) 打开 /warehouse/CHECK/new, 作为 GoRouter extra 传入。
//
// 预填只是「未保存的明细行」: 盘点页照常按所选仓库读取账面数量/账面重量,
// 仓库人员逐行填实盘后保存; 不保存就什么都不写。

/// 盘点预填的一行 (货品 + 颜色; 颜色为空 = 无颜色货品)。
class StockCheckPrefillLine {
  const StockCheckPrefillLine({required this.goodsId, this.colorId});

  final String goodsId;
  final String? colorId;
}

/// 一张新盘点单的预填: 盘点仓库 + 建议盘点的明细行。
class StockCheckPrefill {
  const StockCheckPrefill({required this.warehouseId, required this.lines});

  final String warehouseId;
  final List<StockCheckPrefillLine> lines;
}
