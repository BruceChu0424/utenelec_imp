package com.uten.imp.features.measurement;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Set;
import java.util.UUID;

public final class MeasurementCaptureContracts {

    private MeasurementCaptureContracts() {
    }

    public record ResolveBatchRequest(
            @NotBlank String operationFamily,
            @NotEmpty @Size(max = RequestLimits.LOOKUP_IDS)
            Set<@NotNull UUID> goodsIds) {
    }

    public record ProfileResolution(
            UUID profileId,
            UUID goodsId,
            String operationFamily,
            String status,
            String primaryInput,
            String secondaryPolicy,
            UUID businessUnitId,
            String businessUnitName,
            UUID actualWeightUnitId,
            String actualWeightUnitName,
            BigDecimal confidence,
            long activeEvidenceCount,
            String evidenceFingerprint,
            long version,
            OffsetDateTime lastEvidenceAt,
            boolean profilePresent) {
    }

    public record ResolveBatchResponse(List<ProfileResolution> items) {
        public ResolveBatchResponse {
            items = List.copyOf(items);
        }
    }

    public record OverrideRequest(
            @NotNull UUID commandId,
            @NotBlank @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+") String idempotencyKey,
            @Min(0) long expectedVersion,
            @NotBlank String preference,
            UUID actualWeightUnitId,
            @NotBlank @Size(min = 2, max = 500) String reason) {
    }

    public record ClearOverrideRequest(
            @NotNull UUID commandId,
            @NotBlank @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+") String idempotencyKey,
            @Min(0) long expectedVersion,
            @NotBlank @Size(min = 2, max = 500) String reason) {
    }
}
