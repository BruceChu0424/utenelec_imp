package com.uten.imp.features.stock.weight.dto;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 称重记录一行 (GET /api/stock/weight/goods/{goodsId}/observations)。
 *
 * @param unitWeightKg      本次单重 = 净重 / 数量
 * @param namesMasked       供应商/往来方名称已隐藏 (需要 stock_report:view 或 stock:weight:manage)
 * @param sourceDocCode     来源单据细分类型 (仓库单据为 doc_type, 如 DRAW/OTHER_IN)
 * @param billNo            来源单号
 * @param sourceDocCleared  来源单据已不存在 (历史记录显示「来源单据已清空」); 类型未知时 null
 * @param outlier           当前学习结果把它判为离群
 * @param previousRegime    属于之前的批次 (不再参与当前单重)
 * @param status            REVERSED (已红冲) / EXCLUDED (已排除) / OUTLIER (离群) / NORMAL (正常)
 */
public record WeightObservationRow(
        UUID id,
        OffsetDateTime observedAt,
        String sourceKind,
        String role,
        BigDecimal qtyBase,
        BigDecimal weightKg,
        BigDecimal unitWeightKg,
        BigDecimal grossKg,
        BigDecimal tareKg,
        UUID warehouseId,
        String warehouseName,
        UUID colorId,
        String colorName,
        UUID supplierId,
        String supplierName,
        String counterpartKind,
        UUID counterpartId,
        String counterpartName,
        boolean namesMasked,
        String sourceDocType,
        UUID sourceDocId,
        UUID sourceItemId,
        String sourceDocCode,
        String billNo,
        Boolean sourceDocCleared,
        UUID movementId,
        String stage,
        OffsetDateTime reversedAt,
        String excludedReason,
        OffsetDateTime excludedAt,
        String excludedByName,
        BigDecimal expectedUnitWeightKg,
        BigDecimal expectedWeightKg,
        BigDecimal deviationPct,
        String alertLevel,
        String estimateBasisUsed,
        String estimateTierUsed,
        BigDecimal tolerancePctUsed,
        boolean newRegime,
        boolean outlier,
        Double outlierZ,
        String outlierHint,
        boolean previousRegime,
        String remark,
        UUID recordedBy,
        String recordedByName,
        String status,java.util.List<com.uten.imp.application.port.BusinessNumericInputEvidencePort.Value> inputEvidence) {
    public WeightObservationRow(
        UUID id,
        OffsetDateTime observedAt,
        String sourceKind,
        String role,
        BigDecimal qtyBase,
        BigDecimal weightKg,
        BigDecimal unitWeightKg,
        BigDecimal grossKg,
        BigDecimal tareKg,
        UUID warehouseId,
        String warehouseName,
        UUID colorId,
        String colorName,
        UUID supplierId,
        String supplierName,
        String counterpartKind,
        UUID counterpartId,
        String counterpartName,
        boolean namesMasked,
        String sourceDocType,
        UUID sourceDocId,
        UUID sourceItemId,
        String sourceDocCode,
        String billNo,
        Boolean sourceDocCleared,
        UUID movementId,
        String stage,
        OffsetDateTime reversedAt,
        String excludedReason,
        OffsetDateTime excludedAt,
        String excludedByName,
        BigDecimal expectedUnitWeightKg,
        BigDecimal expectedWeightKg,
        BigDecimal deviationPct,
        String alertLevel,
        String estimateBasisUsed,
        String estimateTierUsed,
        BigDecimal tolerancePctUsed,
        boolean newRegime,
        boolean outlier,
        Double outlierZ,
        String outlierHint,
        boolean previousRegime,
        String remark,
        UUID recordedBy,
        String recordedByName,
        String status){this(id,observedAt,sourceKind,role,qtyBase,weightKg,unitWeightKg,grossKg,tareKg,warehouseId,warehouseName,colorId,colorName,supplierId,supplierName,counterpartKind,counterpartId,counterpartName,namesMasked,sourceDocType,sourceDocId,sourceItemId,sourceDocCode,billNo,sourceDocCleared,movementId,stage,reversedAt,excludedReason,excludedAt,excludedByName,expectedUnitWeightKg,expectedWeightKg,deviationPct,alertLevel,estimateBasisUsed,estimateTierUsed,tolerancePctUsed,newRegime,outlier,outlierZ,outlierHint,previousRegime,remark,recordedBy,recordedByName,status,java.util.List.of());}
    public WeightObservationRow withInputEvidence(java.util.List<com.uten.imp.application.port.BusinessNumericInputEvidencePort.Value> values){return new WeightObservationRow(id,observedAt,sourceKind,role,qtyBase,weightKg,unitWeightKg,grossKg,tareKg,warehouseId,warehouseName,colorId,colorName,supplierId,supplierName,counterpartKind,counterpartId,counterpartName,namesMasked,sourceDocType,sourceDocId,sourceItemId,sourceDocCode,billNo,sourceDocCleared,movementId,stage,reversedAt,excludedReason,excludedAt,excludedByName,expectedUnitWeightKg,expectedWeightKg,deviationPct,alertLevel,estimateBasisUsed,estimateTierUsed,tolerancePctUsed,newRegime,outlier,outlierZ,outlierHint,previousRegime,remark,recordedBy,recordedByName,status,values);}

        public String getQtyBaseExact(){return com.uten.imp.common.util.DecimalText.of(qtyBase);}
        public String getWeightKgExact(){return com.uten.imp.common.util.DecimalText.of(weightKg);}
        public String getUnitWeightKgExact(){return com.uten.imp.common.util.DecimalText.of(unitWeightKg);}
        public String getGrossKgExact(){return com.uten.imp.common.util.DecimalText.of(grossKg);}
        public String getTareKgExact(){return com.uten.imp.common.util.DecimalText.of(tareKg);}
        public String getExpectedUnitWeightKgExact(){return com.uten.imp.common.util.DecimalText.of(expectedUnitWeightKg);}
        public String getExpectedWeightKgExact(){return com.uten.imp.common.util.DecimalText.of(expectedWeightKg);}
        public String getDeviationPctExact(){return com.uten.imp.common.util.DecimalText.of(deviationPct);}
        public String getTolerancePctUsedExact(){return com.uten.imp.common.util.DecimalText.of(tolerancePctUsed);}
}
