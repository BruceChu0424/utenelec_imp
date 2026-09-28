package com.uten.imp.features.stock.ledger.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 货品出入库流水一行 (GET /api/stock/goods/{goodsId}/ledger, ADR-135 §7.1)。
 *
 * <p>行有两种: M = 出入库流水 (stock_movements), W = 只改重量的调整 (stock_weight_adjustments:
 * 重量起算/重量尾差调整/盘点定重/人工核重/撤销盘点重量)。数量、重量都带符号 (入正出负), 重量恒为千克。
 * 结存按「当前余额 − 比本行更新的各行之和」倒推 (排序 = 业务日期倒序 + 记账顺序倒序),
 * 只受仓库 (含下级) 与颜色两个范围条件影响, 类型/方向/截止日期筛选不改变结存。
 *
 * @param rowKind              M / W
 * @param id                   流水 id 或调整行 id
 * @param transactionDate      业务时间
 * @param movementType         出入库类型 (W 行为 null)
 * @param typeLabel            类型名 (服务端给; 方向与自然方向相反时带「(红冲)」; W 行为调整种类名)
 * @param direction            +1 入 / -1 出 (W 行为 null)
 * @param sourceDocType        来源单据类型 (source_doc_type)
 * @param sourceDocId          来源单据头 id
 * @param sourceDocCode        仓库单据 (STOCK_DOC) 的 doc_type, 前端按它打开对应单据页; 其它来源为 null
 * @param billNo               来源单号
 * @param counterpartKind      往来方种类 SUPPLIER / SUBCONTRACTOR / CLIENT / WORKSHOP / WAREHOUSE (调拨对方仓)
 * @param counterpartName      往来方名称 (没有来源单据查看权限时为 null)
 * @param counterpartMasked    往来方名称已按权限遮住
 * @param warehouseId          仓库
 * @param warehouseName        仓库名
 * @param colorId              颜色
 * @param colorName            颜色名
 * @param qtySigned            带符号的基本单位数量 (W 行为 null)
 * @param unitName             货品基本单位名
 * @param weightKgSigned       带符号的重量 (千克; M 行 = 方向 × 流水重量, W 行 = 调整差额); null = 未知
 * @param weightSource         M 行重量来历 MEASURED / EXACT / SLICE / AVERAGE / ESTIMATE (老数据有重量无来历按 MEASURED)
 * @param adjustmentKind       W 行调整种类 ANCHOR / RESIDUAL / COUNT / MANUAL / REVERSAL
 * @param balanceQtyAfter      本行之后的结存数量 (范围内)
 * @param balanceWeightKgAfter 本行之后的结存重量 (千克); null = 不知道 (更新的行里有未知重量或当前余额重量未知)
 * @param remark               备注 (W 行为调整原因)
 * @param operatorName         操作人 (created_by → users.employee_id → employees.full_name)
 * @param amountLocal          流水金额 (没有 goods:cost:view 时为 null)
 * @param costMasked           金额已按成本权限遮住
 */
public record StockLedgerRow(
        String rowKind,
        UUID id,
        OffsetDateTime transactionDate,
        Short movementType,
        String typeLabel,
        Short direction,
        String sourceDocType,
        UUID sourceDocId,
        String sourceDocCode,
        String billNo,
        String counterpartKind,
        String counterpartName,
        boolean counterpartMasked,
        UUID warehouseId,
        String warehouseName,
        UUID colorId,
        String colorName,
        BigDecimal qtySigned,
        String unitName,
        BigDecimal weightKgSigned,
        String weightSource,
        String adjustmentKind,
        BigDecimal balanceQtyAfter,
        BigDecimal balanceWeightKgAfter,
        String remark,
        String operatorName,
        BigDecimal amountLocal,
        boolean costMasked) {
}
