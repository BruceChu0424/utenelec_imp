package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** HTTP contracts for warehouse registration before production FQC. */
public final class ProductionFinishedArrivalContracts {

    private ProductionFinishedArrivalContracts() {
    }

    public record ArrivalRegistrationRequest(
            @NotBlank
            @Size(min = 8, max = 128)
            @Pattern(regexp = "[A-Za-z0-9._:-]+",
                    message = "幂等键只能包含字母、数字或 ._:-")
            String idempotencyKey,
            @NotNull UUID warehouseId,
            @Valid
            @NotNull
            @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
            List<ArrivalRegistrationItemRequest> items) {
    }

    public record ArrivalRegistrationItemRequest(
            @NotNull UUID reportItemId,
            @NotBlank @Size(max = 100) String place) {
    }

    public record ArrivalRegistrationView(
            UUID registrationId,
            boolean registered,
            UUID reportId,
            String reportNo,
            LocalDate reportDate,
            UUID departmentId,
            String workshopName,
            UUID warehouseId,
            String warehouseCode,
            String warehouseName,
            UUID receiverEmployeeId,
            String receiverName,
            OffsetDateTime registeredAt,
            List<ArrivalRegistrationItemView> items) {
    }

    /** Warehouse-scoped suggestions for every immutable report line. */
    public record PlaceSuggestionsView(
            List<PlaceSuggestionItemView> items) {

        public PlaceSuggestionsView {
            items = List.copyOf(items);
        }
    }

    public record PlaceSuggestionItemView(
            UUID reportItemId,
            String place,
            String source) {
    }

    /** Result of the explicit, registration-derived remember action. */
    public record RememberPlacesResult(
            int remembered,
            int unchanged,
            int ambiguous,
            List<String> warnings) {

        public RememberPlacesResult {
            warnings = List.copyOf(warnings);
        }
    }

    public record ArrivalRegistrationItemView(
            UUID reportItemId,
            Integer lineNo,
            UUID planItemId,
            UUID executionSegmentId,
            UUID planId,
            String planNo,
            UUID goodsId,
            String goodsCode,
            String goodsName,
            UUID colorId,
            String colorName,
            UUID unitId,
            String unitName,
            BigDecimal reportedQty,
            String place,
            String placeHint) {
    }
}
