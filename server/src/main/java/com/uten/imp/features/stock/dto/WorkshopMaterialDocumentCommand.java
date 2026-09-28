package com.uten.imp.features.stock.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 车间内料仓建库存单据的命令(ADR-131)。只给内料仓的库存网关用, 不是通用页面入口。
 *
 * <ul>
 *   <li>ISSUE 发料: 调拨单, 叶仓 → 内料仓;</li>
 *   <li>RETURN 收退回: 调拨单, 内料仓 → 叶仓;</li>
 *   <li>OTHER_ISSUE 其它耗用: 其它出库单, 从内料仓出。</li>
 * </ul>
 *
 * <p>库存侧在调用方同一事务里建单、登记 {@code workshop_material_stock_documents}、审核,
 * 调出一侧的流水逐笔核验登记来源; 调用方不带单价, 也不自己登记单据。
 *
 * @param leafWarehouseId      发料的出库叶仓或退回的收料叶仓; 其它耗用为空
 * @param requisitionId        发料、退回对应的领料单或退回单; 其它耗用为空
 * @param otherIssueId         其它耗用记录; 发料、退回为空
 * @param receiverEmployeeId   领料人, 可空
 * @param billDate             单据日期, 空时取今天(业务时区)
 */
public record WorkshopMaterialDocumentCommand(
        Kind kind,
        UUID binWarehouseId,
        UUID leafWarehouseId,
        UUID requisitionId,
        UUID otherIssueId,
        UUID workshopDepartmentId,
        UUID receiverEmployeeId,
        LocalDate billDate,
        String remark,
        List<Line> lines) {

    public WorkshopMaterialDocumentCommand {
        lines = lines == null ? List.of() : List.copyOf(lines);
    }

    public enum Kind { ISSUE, RETURN, OTHER_ISSUE }

    /** qty 为单据单位数量; unitId 为空时取货品基本单位(换算率 1)。 */
    public record Line(UUID goodsId, UUID colorId, UUID unitId, BigDecimal unitRate,
                       BigDecimal qty, String remark) {}

    /**
     * 审核后的一行明细。baseQty 为基本单位数量(4 位); binMovementId 为内料仓一侧的流水:
     * 发料是 7 型调入, 退回是 8 型调出, 其它耗用是 12 型出库。
     */
    public record PostedLine(int lineNo, UUID itemId, UUID goodsId, UUID colorId, UUID unitId,
                             BigDecimal baseQty, UUID binMovementId) {}

    /** 已审核的库存单据; lines 与命令明细同序。 */
    public record Posted(UUID documentId, String billNo, String docType, List<PostedLine> lines) {
        public Posted {
            lines = List.copyOf(lines);
        }
    }
}
