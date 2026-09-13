package com.uten.imp.features.production.analysis;

import jakarta.validation.constraints.*;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Explicit reassignment of approved external supply; never a physical loan. */
public final class PreplanFutureSupplyTransfer {
    private PreplanFutureSupplyTransfer() {}
    public record Source(UUID sourceAllocationId,UUID sourceAnalysisId,UUID sourceMaterialId,String sourceLabel,
                         String route,UUID warehouseId,String warehouseName,UUID goodsId,String goodsCode,String goodsName,
                         UUID colorId,UUID unitId,String unitName,BigDecimal availableQty,BigDecimal receivedQty,
                         LocalDate expectedDate,LocalDate targetNeedDate,boolean lateOrUnknown,String stage,
                         long sourceVersion,String sourceFingerprint,long targetVersion,String targetFingerprint,BigDecimal targetUncoveredQty) {}
    public record Create(@NotNull UUID sourceAllocationId,@NotNull UUID targetMaterialId,
                         @NotNull @DecimalMin("0.0001") @Digits(integer=14,fraction=4) BigDecimal qty,
                         @NotNull Long sourceVersion,@NotBlank String sourceFingerprint,
                         @NotNull Long targetVersion,@NotBlank String targetFingerprint,
                         boolean allowLateSupply,@NotBlank @Size(min=2,max=1000) String reason,
                         @NotBlank @Size(min=8,max=128) String idempotencyKey) {}
    public record Cancel(@NotNull @DecimalMin("0.0001") @Digits(integer=14,fraction=4) BigDecimal qty,
                         @NotNull Long sourceVersion,@NotBlank String sourceFingerprint,
                         @NotNull Long targetVersion,@NotBlank String targetFingerprint,
                         @NotBlank @Size(min=2,max=1000) String reason,@NotBlank @Size(min=8,max=128) String idempotencyKey,
                         boolean acceptPublicRelease) {
        public Cancel(BigDecimal qty,Long sourceVersion,String sourceFingerprint,Long targetVersion,String targetFingerprint,String reason,String idempotencyKey){
            this(qty,sourceVersion,sourceFingerprint,targetVersion,targetFingerprint,reason,idempotencyKey,false);
        }
    }
    public record Transfer(UUID id,UUID sourceAllocationId,UUID sourceAnalysisId,UUID sourceMaterialId,String sourceLabel,
                           UUID targetAnalysisId,UUID targetMaterialId,String targetLabel,String route,
                           BigDecimal qty,BigDecimal cancelledQty,BigDecimal receivedQty,BigDecimal remainingQty,
                           String status,LocalDate expectedDate,LocalDate targetNeedDate,boolean allowLateSupply,
                           long sourceVersion,String sourceFingerprint,long targetVersion,String targetFingerprint,
                           boolean canCancel,String reason,String direction,String blockedReason,BigDecimal cancelableQty,
                           BigDecimal cancelRestoreToSourceQty,BigDecimal cancelPublicReleaseQty,
                           BigDecimal sourceSupplyShortfallQty,String supplyWarning) {
        @com.fasterxml.jackson.annotation.JsonProperty("transferId") public UUID transferId(){return id;}
    }
}
