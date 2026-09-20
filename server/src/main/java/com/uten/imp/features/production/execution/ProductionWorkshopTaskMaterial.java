package com.uten.imp.features.production.execution;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 车间任务的一种物料的事实(ADR-095/V628)：数量全部为基础单位；状态桶与列表汇总同口径
 * (ISSUED / SHORT / SHORT_DIRECT / DRAWABLE / AWAITING_WAREHOUSE / LINE_SIDE_PENDING / PREPARING)。
 */
public record ProductionWorkshopTaskMaterial(
        UUID demandId,
        String goodsCode,
        String goodsName,
        String colorName,
        String unitName,
        /** 需求的供料路线：BUY / SUBCONTRACT / MAKE。 */
        String supplyRoute,
        /** 冻结为同车间上下层直送供给。 */
        boolean directSupply,
        BigDecimal requiredQty,
        /** 已为本需求正式预留(含已领)。 */
        BigDecimal reservedQty,
        /** 车间已提交领料、仓库尚未实际发出。 */
        BigDecimal requestedUnissuedQty,
        /** 已备好、车间尚未提交领料。 */
        BigDecimal requestableQty,
        /** 线边仓直送料待开工时自动投入。 */
        BigDecimal lineSidePendingQty,
        /** 净实领(实领减退回、损耗与待退冻结)。 */
        BigDecimal issuedQty,
        /** 预留不足需求量的缺口。 */
        BigDecimal shortageQty,
        /** 同车间子件已交接到本车间的直送总量。 */
        BigDecimal directReceivedQty,
        /** 直送已交接但尚未分配给本需求的余量。 */
        BigDecimal directAvailableQty,
        /**
         * 仓库里当前可给本需求用的实物(本任务专属来源权益 + 允许动用的公共库存，扣安全库存)，
         * 与齐套提升同一口径——齐套生产在到齐前不预留，靠它回答「到了多少」。
         */
        BigDecimal warehouseAvailableQty,
        String state,
        /** 同车间承担直送责任的子件工单：`编号|状态` 以顿号分隔；非自制需求为空。 */
        String producingSegments) {
}
