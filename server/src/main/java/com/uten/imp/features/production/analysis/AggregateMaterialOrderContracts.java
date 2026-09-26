package com.uten.imp.features.production.analysis;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Material totals are user intent; source slices and compatible production batches are server facts. */
public final class AggregateMaterialOrderContracts {
    private AggregateMaterialOrderContracts() { }

    public interface Writer {
        SubmitResult submit(UUID analysisId, SubmitRequest request);
        MaterialAnalysisContracts.AnalysisView cancel(UUID analysisId,UUID actionId,MaterialAnalysisContracts.CancelRequest request);
    }

    public record GroupInput(
            @NotBlank @Size(max=250) String clientGroupKey,
            @NotEmpty @Size(max=RequestLimits.MATERIAL_AGGREGATE_SOURCE_PATHS) List<@NotNull UUID> materialLineIds,
            @NotBlank @Pattern(regexp="BUY|MAKE|SUBCONTRACT") String route,
            @NotNull @DecimalMin("0") @Digits(integer=14,fraction=4) BigDecimal qty,
            boolean allowPublicExtra,
            UUID departmentId, UUID workerId, UUID teamDepartmentId,
            LocalDate billDate, LocalDate deliveryDate,
            @Size(max=100) String productNo,
            @DecimalMin("0") @Digits(integer=3,fraction=6) BigDecimal allowedOverproductionRate,
            @DecimalMin("0") @Digits(integer=14,fraction=4) BigDecimal safetyQty) {
        public GroupInput {
            materialLineIds=materialLineIds==null?List.of():List.copyOf(materialLineIds);
            safetyQty=safetyQty==null?BigDecimal.ZERO:safetyQty;
        }
    }

    public record PreviewRequest(
            @NotNull Long version,
            @NotBlank @Pattern(regexp="(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min=8,max=128) String idempotencyKey,
            @NotNull UUID warehouseId,
            @NotNull LocalDate billDate, LocalDate deliveryDate, boolean approveNow,
            @NotEmpty @Size(max=RequestLimits.DOCUMENT_LINES) List<@Valid GroupInput> groups) {
        public PreviewRequest { groups=groups==null?List.of():List.copyOf(groups); }
    }

    public record SubmitRequest(
            @NotNull Long version,
            @NotBlank @Pattern(regexp="(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min=8,max=128) String idempotencyKey,
            @NotNull UUID warehouseId,
            @NotNull LocalDate billDate, LocalDate deliveryDate, boolean approveNow,
            @NotEmpty @Size(max=RequestLimits.DOCUMENT_LINES) List<@Valid GroupInput> groups,
            @NotBlank @Pattern(regexp="(?i)[0-9a-f]{64}") String previewFingerprint) {
        public SubmitRequest { groups=groups==null?List.of():List.copyOf(groups); }
        public PreviewRequest previewRequest() {
            return new PreviewRequest(version,fingerprint,idempotencyKey,warehouseId,billDate,deliveryDate,approveNow,groups);
        }
    }

    public record SourcePreview(UUID materialLineId, UUID analysisLineId, String sourceLabel,
                                int allocationPriority, LocalDate needDate, BigDecimal sourceRequiredQty,
                                BigDecimal remainingQty, BigDecimal allocatedQty, BigDecimal orderedQty) { }

    /** One physical shared batch's direct frozen BOM inputs, never a sum of separately rounded source batches. */
    public record ChildPreview(UUID materialLineId, UUID goodsId, String goodsCode, String goodsName,
                               UUID colorId, String colorName, UUID unitId, String unitName,
                               String relativeBomPath, String controlStage, String consumptionBasis,
                               BigDecimal bomQty, BigDecimal basisOutputQty, boolean allowPartialPackage,
                               BigDecimal requiredQty) { }

    public record GroupPreview(String clientGroupKey, String compatibilityKey, String route,
                               UUID goodsId, String goodsCode, String goodsName,
                               UUID colorId, String colorName, UUID unitId, String unitName,
                               BigDecimal sourceRequiredQty, BigDecimal orderedQty, BigDecimal remainingQty,
                               BigDecimal requestedQty, BigDecimal publicExtraQty, BigDecimal safetyQty,
                               UUID departmentId, UUID workerId, UUID teamDepartmentId,
                               LocalDate billDate, LocalDate deliveryDate, String productNo,
                               BigDecimal allowedOverproductionRate,
                               List<SourcePreview> sources, List<ChildPreview> sharedBomChildren,
                               String blockedReason,UUID existingBatchId,BigDecimal priorOutputQty) {
        public GroupPreview { sources=List.copyOf(sources);sharedBomChildren=List.copyOf(sharedBomChildren);priorOutputQty=priorOutputQty==null?BigDecimal.ZERO:priorOutputQty; }
        public GroupPreview(String clientGroupKey,String compatibilityKey,String route,UUID goodsId,String goodsCode,String goodsName,
                UUID colorId,String colorName,UUID unitId,String unitName,BigDecimal sourceRequiredQty,BigDecimal orderedQty,BigDecimal remainingQty,
                BigDecimal requestedQty,BigDecimal publicExtraQty,BigDecimal safetyQty,UUID departmentId,UUID workerId,UUID teamDepartmentId,
                LocalDate billDate,LocalDate deliveryDate,String productNo,BigDecimal allowedOverproductionRate,
                List<SourcePreview> sources,List<ChildPreview> sharedBomChildren,String blockedReason) {
            this(clientGroupKey,compatibilityKey,route,goodsId,goodsCode,goodsName,colorId,colorName,unitId,unitName,sourceRequiredQty,orderedQty,
                    remainingQty,requestedQty,publicExtraQty,safetyQty,departmentId,workerId,teamDepartmentId,billDate,deliveryDate,productNo,
                    allowedOverproductionRate,sources,sharedBomChildren,blockedReason,null,BigDecimal.ZERO);
        }
    }

    public record Preview(UUID analysisId, long version, String fingerprint, String previewFingerprint,
                          List<GroupPreview> groups, MaterialAnalysisContracts.AnalysisView analysis) {
        public Preview { groups=List.copyOf(groups); }
    }

    public record BatchResult(UUID batchId, String clientGroupKey, String route,
                              String documentType, UUID documentId, String documentNo,
                              UUID planId, UUID anchorAnalysisItemId, BigDecimal qty, BigDecimal publicExtraQty,
                              List<SourcePreview> sources) {
        public BatchResult { sources=List.copyOf(sources); }
    }

    public record MaterialIdentityBridge(List<UUID> fromMaterialLineIds,UUID toMaterialLineId,
                                         String relativeBomPath,BigDecimal requiredQty) {
        public MaterialIdentityBridge { fromMaterialLineIds=List.copyOf(fromMaterialLineIds); }
    }

    public record SubmitResult(MaterialAnalysisContracts.AnalysisView analysis, boolean replayed,
                               List<BatchResult> batches,List<MaterialIdentityBridge> materialIdentityBridges) {
        public SubmitResult { batches=List.copyOf(batches);materialIdentityBridges=materialIdentityBridges==null?List.of():List.copyOf(materialIdentityBridges); }
        public SubmitResult(MaterialAnalysisContracts.AnalysisView analysis,boolean replayed,List<BatchResult> batches) {
            this(analysis,replayed,batches,List.of());
        }
    }
}
