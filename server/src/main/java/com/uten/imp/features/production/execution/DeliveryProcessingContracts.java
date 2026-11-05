package com.uten.imp.features.production.execution;

import com.uten.imp.common.validation.DocumentQuantity;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Price-free, exact physical processing work. Reporting does not manufacture stock. */
public final class DeliveryProcessingContracts {
    private DeliveryProcessingContracts() { }
    public record Assignment(@NotNull Long expectedVersion, @NotNull UUID workshopDepartmentId,
            UUID responsibleEmployeeId, @NotNull UUID idempotencyKey) { }
    public record Start(@NotNull Long expectedVersion, @NotNull UUID warehouseId,
            @NotNull UUID idempotencyKey) { }
    public record Report(@NotNull Long expectedVersion,
            @NotNull @DecimalMin(value="0",inclusive=false) @DocumentQuantity BigDecimal quantity,
            @NotBlank @Pattern(regexp="LASER") String operation,
            @NotBlank @Size(max=2000) String evidence, @NotNull UUID idempotencyKey) { }
    public record CancelStart(@NotNull Long expectedVersion, @NotNull UUID idempotencyKey) { }
    public record ActionOutcome(UUID requestId, boolean recorded, Long resultingVersion) { }
    public record Task(UUID componentId, UUID shipmentId, String shipmentNo, UUID orderItemId,
            List<String> path, UUID goodsId, String goodsCode, String goodsName, UUID colorId,
            UUID unitId, String unitName, String requiredQtyExact, String completedQtyExact,
            String remainingQtyExact, List<String> operations, UUID warehouseId, String warehouseName,
            UUID workshopDepartmentId, String workshopName, UUID responsibleEmployeeId, String responsibleName,
            String status, long version, OffsetDateTime startedAt, UUID startedBy,
            OffsetDateTime completedAt, String evidence, boolean canAssign, boolean canStart, boolean canReport,
            OffsetDateTime issuedAt, OffsetDateTime receivedAt, boolean canCancelStart,
            List<com.uten.imp.common.delivery.DeliveryProcessingTargets.Target> processingTargets) { }
}
