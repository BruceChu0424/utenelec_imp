package com.uten.imp.features.production.schedule.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 已审订单明细行（新建计划单「从订单带明细」弹窗数据）。
 * 含待排产缺口 + 该货品一层 BOM 零件清单（点行展开看"这个产品由哪些零件组成"）。
 */
public record ScheduleOrderLine(
        UUID orderItemId,
        Integer lineNo,
        UUID goodsId,
        String goodsCode,
        String goodsName,
        String spec,
        UUID colorId,
        String colorName,
        UUID unitId,
        String unitName,
        BigDecimal qty,
        BigDecimal plannedQty,
        BigDecimal needQty,
        BigDecimal unitRate,
        LocalDate deliverDate,
        String orderBillNo,
        String clientName,
        List<BomComponent> bom) {

    /** 货品一层 BOM 零件：单件用量 × 待排产缺口 = 需求小计；onhand 为全仓即时库存。 */
    public record BomComponent(
            UUID goodsId,
            String code,
            String name,
            String spec,
            BigDecimal perQty,
            BigDecimal needQty,
            BigDecimal onhand,
            boolean selfMade) {
    }
}
