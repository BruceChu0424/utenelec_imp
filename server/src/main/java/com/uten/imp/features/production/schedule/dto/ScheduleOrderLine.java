package com.uten.imp.features.production.schedule.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 已审订单明细行（新建计划单「从订单带明细」弹窗数据）。
 * 含新增排产缺口 + 该货品一层 BOM 零件清单（点行展开看"这个产品由哪些零件组成"）。
 * 缺口与调度列表同口径：净未交减当前预留，再减尚未入库的计划量，
 * 即 qty-shipped+returned-flag-reserved-max(planned-produced,0)。
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

    /**
     * 货品一层 BOM 零件：perQty 为计算采用的每件用量(有真实数据用真实使用数量，否则设计使用数量)；
     * needQty 按计量规则(整包/固定批次向上取整)算出的待排产缺口需求；颜色为 BOM 行颜色(缺省取组件颜色)；
     * onhand 为全仓即时库存。BOM 行用量不大于零(存量坏数据)时 perQty 与 needQty 为空，
     * 由物料分析给出原因。
     */
    public record BomComponent(
            UUID goodsId,
            String code,
            String name,
            String spec,
            UUID colorId,
            String colorName,
            BigDecimal perQty,
            BigDecimal needQty,
            BigDecimal onhand,
            boolean selfMade) {
    }
}
