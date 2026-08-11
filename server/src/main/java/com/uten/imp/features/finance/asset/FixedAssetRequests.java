package com.uten.imp.features.finance.asset;

import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Fixed-asset and deferred-expense JSON request contracts.
 *
 * <p>The records deliberately retain the existing camel-case field names so
 * deployed clients do not need a contract change. Conversion to the service's
 * internal map is kept at this boundary until the legacy native-query service
 * is replaced with typed persistence.
 */
public final class FixedAssetRequests {

    private static final String PERIOD_PATTERN = "^\\d{4}-(?:0[1-9]|1[0-2])$";
    private static final String ASSET_STATUS_PATTERN = "^(?:在用|停用|清理)$";
    private static final String DEFERRED_STATUS_PATTERN = "^(?:摊销中|已摊完|停用)$";

    private FixedAssetRequests() {}

    public record CreateAssetRequest(
            @NotBlank @Size(max = 64) String code,
            @NotBlank @Size(max = 200) String name,
            UUID departmentId,
            UUID expenseStyleId,
            @NotNull @DecimalMin("0.0001") @Digits(integer = 14, fraction = 4)
                    BigDecimal originalValue,
            @DecimalMin("0.0000") @DecimalMax("1.0000") @Digits(integer = 1, fraction = 4)
                    BigDecimal salvageRate,
            @NotNull @Min(1) @Max(1200) Integer usefulMonths,
            @NotBlank @Pattern(regexp = PERIOD_PATTERN) String startPeriod,
            @Pattern(regexp = ASSET_STATUS_PATTERN) String status,
            @Size(max = 2000) String remark) {

        Map<String, Object> toMap() {
            return body(
                    "code", code,
                    "name", name,
                    "departmentId", departmentId,
                    "expenseStyleId", expenseStyleId,
                    "originalValue", originalValue,
                    "salvageRate", salvageRate,
                    "usefulMonths", usefulMonths,
                    "startPeriod", startPeriod,
                    "status", status,
                    "remark", remark);
        }
    }

    public record UpdateAssetRequest(
            @Size(max = 64) String code,
            @Size(min = 1, max = 200) String name,
            UUID departmentId,
            UUID expenseStyleId,
            @DecimalMin("0.0001") @Digits(integer = 14, fraction = 4)
                    BigDecimal originalValue,
            @DecimalMin("0.0000") @DecimalMax("1.0000") @Digits(integer = 1, fraction = 4)
                    BigDecimal salvageRate,
            @Min(1) @Max(1200) Integer usefulMonths,
            @Pattern(regexp = PERIOD_PATTERN) String startPeriod,
            @Pattern(regexp = ASSET_STATUS_PATTERN) String status,
            @Size(max = 2000) String remark) {

        Map<String, Object> toMap() {
            return body(
                    "code", code,
                    "name", name,
                    "departmentId", departmentId,
                    "expenseStyleId", expenseStyleId,
                    "originalValue", originalValue,
                    "salvageRate", salvageRate,
                    "usefulMonths", usefulMonths,
                    "startPeriod", startPeriod,
                    "status", status,
                    "remark", remark);
        }
    }

    public record CreateDeferredRequest(
            @NotBlank @Size(max = 64) String code,
            @NotBlank @Size(max = 200) String name,
            UUID expenseStyleId,
            @NotNull @DecimalMin("0.0001") @Digits(integer = 14, fraction = 4)
                    BigDecimal totalAmount,
            @NotNull @Min(1) @Max(1200) Integer usefulMonths,
            @NotBlank @Pattern(regexp = PERIOD_PATTERN) String startPeriod,
            @Pattern(regexp = DEFERRED_STATUS_PATTERN) String status,
            @Size(max = 2000) String remark) {

        Map<String, Object> toMap() {
            return body(
                    "code", code,
                    "name", name,
                    "expenseStyleId", expenseStyleId,
                    "totalAmount", totalAmount,
                    "usefulMonths", usefulMonths,
                    "startPeriod", startPeriod,
                    "status", status,
                    "remark", remark);
        }
    }

    public record UpdateDeferredRequest(
            @Size(max = 64) String code,
            @Size(min = 1, max = 200) String name,
            UUID expenseStyleId,
            @DecimalMin("0.0001") @Digits(integer = 14, fraction = 4)
                    BigDecimal totalAmount,
            @Min(1) @Max(1200) Integer usefulMonths,
            @Pattern(regexp = PERIOD_PATTERN) String startPeriod,
            @Pattern(regexp = DEFERRED_STATUS_PATTERN) String status,
            @Size(max = 2000) String remark) {

        Map<String, Object> toMap() {
            return body(
                    "code", code,
                    "name", name,
                    "expenseStyleId", expenseStyleId,
                    "totalAmount", totalAmount,
                    "usefulMonths", usefulMonths,
                    "startPeriod", startPeriod,
                    "status", status,
                    "remark", remark);
        }
    }

    private static Map<String, Object> body(Object... entries) {
        Map<String, Object> body = new LinkedHashMap<>();
        for (int index = 0; index < entries.length; index += 2) {
            body.put((String) entries[index], entries[index + 1]);
        }
        return body;
    }
}
