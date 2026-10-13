package com.uten.imp.features.master.goods.pricing;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Read-only analytical values. All wire decimals are exact plain strings. */
public final class GoodsPriceContracts {
    private GoodsPriceContracts() {}
    public enum Kind { PURCHASE, SUBCONTRACT, SALES }
    public record Query(UUID goodsId, Kind kind, Integer days, UUID supplierId, UUID colorId,
            UUID unitId, UUID currencyId, String taxRate, String quantity, UUID excludeOrderId,
            UUID clientId, UUID confirmedCostSnapshotId, String targetMarginRate, String unitRate) {}
    public record Context(UUID supplierId, UUID clientId, UUID colorId, UUID unitId,
            String unitName, UUID currencyId, String currencyName, String taxRate,
            String quantity, int days, String taxMode, String priceBasis, String quantityBasis, String unitRate, String colorName) {}
    public record Observation(String sourceType, UUID sourceId, UUID sourceItemId, String sourceNo,
            String sourceRevision, LocalDate businessDate, UUID supplierId, UUID clientId,
            String partnerName, UUID colorId, UUID unitId, String unitName, UUID currencyId,
            String currencyName, String taxRate, String quantity, String unitPrice, String amount,
            String exchangeRateToLocal, UUID financeApprovalCaseId, String exchangeRateSource,
            boolean comparable, List<String> reasonCodes, String goodsCodeSnapshot,
            String goodsNameSnapshot, boolean canOpenSource, String unitRate, UUID historyVersionId,
            String lifecycle, OffsetDateTime recordedAt, String colorName) {}
    public record CostSummary(String basis, UUID snapshotId, String digest, String sheetNo,
            String batchQuantity, String unitCost, UUID currencyId, boolean fullCostComplete,
            boolean actualFullCostComplete, List<String> missingCostComponents,
            List<String> includedCostComponents, String targetMarginRate, String suggestedPrice,
            String explanation, String currencyName, String unitName) {}
    public record Analysis(UUID goodsId, String goodsCode, String goodsName, Kind kind, Context context,
            String status, String referencePrice, String weightedAveragePrice, String lowerReferencePrice,
            String upperReferencePrice, String lastPrice, LocalDate lastBusinessDate, int sampleCount,
            int independentOrderCount, String effectiveSampleSize, OffsetDateTime dataAsOf,
            List<String> reasonCodes, String explanation, List<Observation> observations,
            String evidenceToken, String algorithmVersion, boolean dataComplete, CostSummary costSummary) {}
    public record CheckRequest(Kind kind, Integer days, UUID excludeOrderId, List<CheckItem> items) {}
    public record CheckItem(String rowKey, UUID goodsId, UUID supplierId, UUID colorId, UUID unitId,
            UUID currencyId, String taxRate, String quantity, String unitPrice, String totalAmountInput,
            List<Map<String,Object>> extraColumns, String unitRate, String giftQuantity) {}
    public record CheckRow(String rowKey, UUID goodsId, String status, String severity, String inputPrice,
            String referencePrice, String weightedAveragePrice, String percentageDeviation,
            String estimatedImpact, List<String> reasonCodes, String message, String evidenceToken,
            int sampleCount, String confidence, String peerReferencePrice, String peerPercentageDeviation,
            String currencyName, String unitName) {
        public CheckRow(String rowKey, UUID goodsId, String status, String severity, String inputPrice,
                String referencePrice, String weightedAveragePrice, String percentageDeviation,
                String estimatedImpact, List<String> reasonCodes, String message, String evidenceToken,
                int sampleCount, String confidence, String peerReferencePrice, String peerPercentageDeviation) {
            this(rowKey,goodsId,status,severity,inputPrice,referencePrice,weightedAveragePrice,percentageDeviation,
                    estimatedImpact,reasonCodes,message,evidenceToken,sampleCount,confidence,peerReferencePrice,peerPercentageDeviation,null,null);
        }
    }
    public record CheckResult(List<CheckRow> rows, String algorithmVersion, OffsetDateTime checkedAt) {}
    public record HistoryQuery(Query context, LocalDate from, LocalDate to, String cursor, Integer pageSize) {}
    public record History(List<Observation> observations, String nextCursor, boolean hasMore, OffsetDateTime dataAsOf) {}
    /** Identity comes from one rendered row; a missing history version means the analysis-window projection. */
    public record DetailQuery(Kind kind, String sourceType, UUID sourceId, UUID sourceItemId,
            UUID historyVersionId, String expectedSourceRevision) {}
    public record DetailField(String key, String label, String value) {}
    public record Detail(Observation observation, String title, String summary,
            List<String> reasonCodes, List<DetailField> fields) {}
}
