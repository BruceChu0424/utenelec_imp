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
import java.util.Map;
import java.util.UUID;

/** Material totals are user intent; source slices and compatible production batches are server facts. */
public final class AggregateMaterialOrderContracts {
    private AggregateMaterialOrderContracts() { }

    public interface Writer {
        SubmitResult submit(UUID analysisId, SubmitRequest request);
        MaterialAnalysisContracts.AnalysisView cancel(UUID analysisId,UUID actionId,MaterialAnalysisContracts.CancelRequest request);
    }

    record AdoptedClaim(String kind,UUID claimId,UUID targetMaterialLineId,BigDecimal qty) { }
    record SourceAdoptionIntent(UUID originalMaterialLineId,UUID targetMaterialLineId,String kind,UUID claimId,BigDecimal qty) { }

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
            @DecimalMin("0") @Digits(integer=14,fraction=4) BigDecimal safetyQty,
            Map<UUID,BigDecimal> sourceRequestedQtyByMaterialLineId) {
        public GroupInput {
            materialLineIds=materialLineIds==null?List.of():List.copyOf(materialLineIds);
            safetyQty=safetyQty==null?BigDecimal.ZERO:safetyQty;
            sourceRequestedQtyByMaterialLineId=sourceRequestedQtyByMaterialLineId==null?Map.of():java.util.Collections.unmodifiableMap(new java.util.TreeMap<>(sourceRequestedQtyByMaterialLineId));
        }

        public GroupInput(String clientGroupKey,List<UUID> materialLineIds,String route,BigDecimal qty,
                boolean allowPublicExtra,UUID departmentId,UUID workerId,UUID teamDepartmentId,
                LocalDate billDate,LocalDate deliveryDate,String productNo,BigDecimal allowedOverproductionRate,BigDecimal safetyQty) {
            this(clientGroupKey,materialLineIds,route,qty,allowPublicExtra,departmentId,workerId,teamDepartmentId,
                    billDate,deliveryDate,productNo,allowedOverproductionRate,safetyQty,Map.of());
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
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String fingerprint,
            @NotBlank @Size(min=8,max=128) String idempotencyKey,
            @NotNull UUID warehouseId,
            @NotNull LocalDate billDate, LocalDate deliveryDate, boolean approveNow,
            @NotEmpty @Size(max=RequestLimits.DOCUMENT_LINES) List<@Valid GroupInput> groups,
            @NotBlank @Pattern(regexp = "(?i)[0-9a-f]{64}") String previewFingerprint,
            /**
             * ADR-099 修订(2026-09-29)：null/false = 原行为——提交时先自动认领自制公共
             * 超产与同主仓公共在途、只为余下部分新下单；true = 用户明确选择
             * 「足额下单，不扣可用数量」，跳过全部自动认领。预览本身不认领，指纹校验不受影响。
             */
            Boolean skipAutoClaim) {
        public SubmitRequest { groups=groups==null?List.of():List.copyOf(groups); }
        public boolean skipClaims() { return Boolean.TRUE.equals(skipAutoClaim); }
        public SubmitRequest(Long version,String fingerprint,String idempotencyKey,UUID warehouseId,
                LocalDate billDate,LocalDate deliveryDate,boolean approveNow,List<GroupInput> groups,
                String previewFingerprint) {
            this(version,fingerprint,idempotencyKey,warehouseId,billDate,deliveryDate,approveNow,groups,previewFingerprint,null);
        }
        public PreviewRequest previewRequest() {
            return new PreviewRequest(version,fingerprint,idempotencyKey,warehouseId,billDate,deliveryDate,approveNow,groups);
        }
    }

    public record SourcePreview(UUID materialLineId, UUID analysisLineId, String sourceLabel,
                                int allocationPriority, LocalDate needDate, BigDecimal sourceRequiredQty,
                                BigDecimal remainingQty, BigDecimal allocatedQty, BigDecimal orderedQty,List<UUID> originalMaterialLineIds) {
        public SourcePreview { originalMaterialLineIds=originalMaterialLineIds==null?List.of(materialLineId):List.copyOf(originalMaterialLineIds); }
        public SourcePreview(UUID materialLineId,UUID analysisLineId,String sourceLabel,int allocationPriority,LocalDate needDate,
                BigDecimal sourceRequiredQty,BigDecimal remainingQty,BigDecimal allocatedQty,BigDecimal orderedQty) {
            this(materialLineId,analysisLineId,sourceLabel,allocationPriority,needDate,sourceRequiredQty,remainingQty,allocatedQty,orderedQty,null);
        }
    }

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
                              List<SourcePreview> sources,MaterialAnalysisContracts.GeneratedPlan generatedPlan) {
        public BatchResult { sources=List.copyOf(sources); }
        public BatchResult(UUID batchId,String clientGroupKey,String route,String documentType,UUID documentId,String documentNo,
                UUID planId,UUID anchorAnalysisItemId,BigDecimal qty,BigDecimal publicExtraQty,List<SourcePreview> sources) {
            this(batchId,clientGroupKey,route,documentType,documentId,documentNo,planId,anchorAnalysisItemId,qty,publicExtraQty,sources,null);
        }
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
