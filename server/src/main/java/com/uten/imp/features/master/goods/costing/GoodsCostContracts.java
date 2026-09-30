package com.uten.imp.features.master.goods.costing;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Stable cost-workbench wire contract. Decimal values are plain decimal strings, never doubles. */
public final class GoodsCostContracts {
    private GoodsCostContracts() {}
    public record DraftInput(UUID goodsId, UUID clientId, String name, String batchQty,
            UUID currencyId, String exchangeRateToLocal, LocalDate effectiveDate,
            String usageStrategy, String priceStrategy, UUID templateId,
            List<LineOverride> lineOverrides, List<FeeInput> fees,
            List<PriceColumn> priceColumns, List<PriceCell> priceCells,
            Map<String, String> extraFields, String notes) {}
    /** path is the slash-separated immutable BOM edge UUID path, or ROOT for an unassembled item. */
    public record LineOverride(String path, String adoptedQty, String route, String unitPrice,
            String priceUnitRate, String priceExchangeRateToLocal, String taxRate,
            String taxMode, UUID priceSourceItemId, String priceSourceType, String reason,
            String priceSourceVersion) {
        public LineOverride(String path,String adoptedQty,String route,String unitPrice,String priceUnitRate,
                String priceExchangeRateToLocal,String taxRate,String taxMode,UUID priceSourceItemId,String priceSourceType,String reason) {
            this(path,adoptedQty,route,unitPrice,priceUnitRate,priceExchangeRateToLocal,taxRate,taxMode,priceSourceItemId,priceSourceType,reason,null);
        }
    }
    /** Typed fee bases: MATERIAL/PROCESS/DIRECT_COST include that category, or explicit fee keys; cycles are rejected. */
    public record FeeInput(String key, String name, String type, String category, String targetPath,
            String value, String quantity, List<String> baseKeys, String source, String reason) {}
    /** A reusable extra price column produces one typed cost fee per explicitly supplied cell. */
    public record PriceColumn(String key, String name, String type, String category,
            List<String> baseKeys) {}
    public record PriceCell(String path, String columnKey, String value, String quantity, String reason) {}
    public record SaveRequest(Long expectedVersion, String idempotencyKey, DraftInput input) {}
    public record Command(long expectedVersion, String idempotencyKey) {}
    public record CopyCommand(long expectedVersion, String idempotencyKey, String name) {}
    public record SheetSummary(UUID id, UUID goodsId, UUID clientId, String name, String status,
            long version, String batchQty, String knownTotal, String unitCost, String valueState,
            UUID confirmedSnapshotId, OffsetDateTime updatedAt) {}
    public record Sheet(UUID id, String sheetNo, String status, long version, DraftInput input,
            Calculation calculation, UUID confirmedSnapshotId, OffsetDateTime updatedAt,
            boolean canEdit, boolean canConfirm, boolean canExport) {}
    public record Calculation(String algorithmVersion, OffsetDateTime calculatedAt,
            String contentDigest, UUID goodsId, String goodsCode, String goodsName,
            UUID unitId, String unitName, UUID currencyId, String currencyName,
            String batchQty, String exchangeRateToLocal, List<CostLine> lines,
            List<FeeResult> fees, Totals totals, List<Issue> issues,
            Map<String, String> sourceRevisions) {}
    public record CostLine(String id, String parentId, String path, int depth, UUID bomItemId,
            UUID goodsId, String goodsCode, String goodsName, UUID colorId, String colorName,
            UUID unitId, String unitName, String sourceType, String route,
            String designQty, String actualQty, String adoptedQty, String usageBasis,
            String usageReason, long sampleCount, String actualOutputQty, String actualNetQty,
            String consumptionBasis, String basisOutputQty, boolean allowPartialPackage,
            String batchQty, String perProductQty, String unitPrice, String priceUnitRate,
            String amount, String unitContribution, boolean included, String valueState,
            PriceEvidence priceEvidence, Map<String, String> extraCosts,
            String materialAmount, String feeAmount) {}
    public record PriceEvidence(String sourceType, UUID sourceId, UUID sourceItemId,
            String sourceNumber, String sourceVersion, String approvalState,
            UUID supplierId, UUID currencyId, String currencyName, UUID unitId,
            String unitName, String unitRate, String originalUnitPrice,
            String exchangeRateToLocal, String taxRate, String taxMode,
            LocalDate sourceDate, String reason) {}
    public record FeeResult(String key, String name, String type, String category, String targetPath,
            String value, String quantity, List<String> baseKeys, String baseAmount,
            String amount, String unitAmount, String valueState, String source, String reason) {}
    public record Totals(String material, String process, String management, String other,
            String knownTotal, String unitCost, String valueState, int missingPriceCount,
            int actualUsageCount, int designUsageCount, Map<String, String> byCategory) {}
    public record Issue(String code, String path, String message, boolean blocksConfirmation) {}
    public record Snapshot(UUID id, UUID sheetId, String sheetNo, long sheetVersion,
            String kind, DraftInput input, Calculation calculation, String contentDigest,
            UUID createdBy, OffsetDateTime createdAt) {}
    public record SnapshotSummary(UUID id, long sheetVersion, String kind,
            String contentDigest, OffsetDateTime createdAt) {}
    public record TemplateInput(String name, UUID goodsId, UUID clientId, LocalDate validFrom,
            LocalDate validTo, String minBatchQty, String maxBatchQty,
            List<FeeInput> fees, List<PriceColumn> priceColumns, String notes,
            UUID currencyId, String exchangeRateToLocal) {
        public TemplateInput(String name,UUID goodsId,UUID clientId,LocalDate validFrom,LocalDate validTo,
                String minBatchQty,String maxBatchQty,List<FeeInput> fees,List<PriceColumn> priceColumns,String notes) {
            this(name,goodsId,clientId,validFrom,validTo,minBatchQty,maxBatchQty,fees,priceColumns,notes,null,"1");
        }
    }
    public record TemplateSave(Long expectedVersion, String idempotencyKey, TemplateInput input) {}
    public record Template(UUID id, long version, TemplateInput input, OffsetDateTime updatedAt) {}
    public record ConvertCurrencyRequest(DraftInput input,UUID targetCurrencyId,String targetExchangeRateToLocal) {}
    public record ConvertedCurrency(DraftInput input,Calculation calculation) {}
}
