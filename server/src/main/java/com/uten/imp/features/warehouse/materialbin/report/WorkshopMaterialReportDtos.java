package com.uten.imp.features.warehouse.materialbin.report;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 车间内料仓用量报表的行 (ADR-131 §5.10, 规格 §2.3); 各报表接口直接返回行的列表, 收发明细分页。
 *
 * <p>金额与单价只给持"查看货品成本"权限的人; 没有权限时这些字段为空 (页面据此整列隐藏), 数量照常给。
 * 金额读价值节点现值, 同时保留结算时金额。处理方式与标红原因给代码值, 页面按代码配中文。
 */
public final class WorkshopMaterialReportDtos {

    private WorkshopMaterialReportDtos() {}

    /**
     * 内料仓用量表的一行 (每期 × 每种料)。辅料只给每期总用量 (没有理论, 分摊基数是主料理论);
     * unitCost = 结算时金额 / 实际用量。
     */
    public record BinUsageRow(UUID periodId, int periodNo, LocalDate startDate, LocalDate endDate,
                              String periodStatus, UUID periodLineId, UUID goodsId, String goodsCode,
                              String goodsName, UUID colorId, String colorName, String unitName, String costBasis,
                              BigDecimal openingQty, BigDecimal transferInQty, BigDecimal returnQty,
                              BigDecimal otherIssueQty, BigDecimal closingQty, BigDecimal actualQty,
                              BigDecimal theoryQty, BigDecimal allocationBasisQty, BigDecimal diffQty,
                              BigDecimal wasteRate, String outcome, List<String> flags, BigDecimal consumedQty,
                              BigDecimal lossQty, Integer closeNo, OffsetDateTime closedAt,
                              BigDecimal currentValue, BigDecimal valueAtClose, BigDecimal unitCost,
                              String openingCountBasis, String closingCountBasis, BigDecimal adjustmentQty) {}

    /**
     * 产品用料表的一行 (每期 × 料 × 产品)。unitWeight 与 actualPerUnit 为材料基本单位/件，单位随行下发；exclusivePeriod = 本期这种料
     * 只有这一个产品用 (独占期平均耗用 = 分摊耗用 / 完工)，仍受盘点和报工误差影响，非逐件实测。
     */
    public record ProductUsageRow(UUID periodId, int periodNo, LocalDate startDate, LocalDate endDate,
                                  UUID closeMaterialId, String costBasis, UUID materialGoodsId, String materialCode,
                                  String materialName, UUID materialColorId, String materialColorName,
                                  UUID productGoodsId, String productCode, String productName,
                                  BigDecimal outputQty, BigDecimal unitWeight, BigDecimal theoryQty,
                                  BigDecimal allocatedQty, BigDecimal currentValue, BigDecimal unitMaterialCost,
                                  boolean exclusivePeriod, BigDecimal actualPerUnit,
                                  String openingCountBasis, String closingCountBasis, String materialUnitName,
                                  BigDecimal materialUnitKgFactor) {
        public String getCurrentValueExact() { return currentValue == null ? null : currentValue.toPlainString(); }
        public String getUnitMaterialCostExact() { return unitMaterialCost == null ? null : unitMaterialCost.toPlainString(); }
    }

    /** 耗用差异率趋势的一个点 (只算主料; wasteRate 保留兼容字段名，不代表报废率)。 */
    public record WastePoint(UUID periodId, int periodNo, LocalDate startDate, LocalDate endDate, UUID goodsId,
                             String goodsCode, String goodsName, UUID colorId, String colorName,
                             BigDecimal wasteRate, String openingCountBasis, String closingCountBasis) {}

    /** 缺单重清单的一行: 未结算期间里有产量、但 BOM 没填单个重量的 (期, 产品, 料)。 */
    public record MissingWeightRow(UUID periodId, int periodNo, LocalDate startDate, LocalDate endDate,
                                   UUID productGoodsId, String productCode, String productName,
                                   UUID materialGoodsId, String materialCode, String materialName,
                                   UUID materialColorId, String materialColorName, BigDecimal outputQty) {}

    /**
     * 收发明细的一行。sourceKind: ISSUE 发料 / RETURN 退回 / OTHER_ISSUE 其它耗用 / CONSUME 盘点耗用 /
     * CONSUME_REVERSE 盘点耗用冲回 / GAIN 盘盈 / GAIN_REVERSE 盘盈冲回; signedQty 进为正、出为负;
     * docNo 为库存单据号 (盘点过账没有单据号), requestNo 为领料单号或退回单号。
     */
    public record LedgerRow(UUID sourceRowId, String sourceKind, LocalDate businessDate, UUID periodId,
                            int periodNo, UUID goodsId, String goodsCode, String goodsName, UUID colorId,
                            String colorName, String unitName, BigDecimal signedQty, boolean supplement,
                            String docNo, String requestNo, String operatorName, OffsetDateTime createdAt,
                            String remark) {}
}
