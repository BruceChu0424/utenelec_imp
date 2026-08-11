package com.uten.imp.features.finance.asset.api;

import com.fasterxml.jackson.annotation.JsonFormat;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Category and policy configuration contracts. No enterprise accounting defaults are embedded. */
public final class AssetCategoryContracts {

    private AssetCategoryContracts() {}

    public record SaveRequest(
            @NotBlank @Pattern(regexp = "^(?:FIXED_ASSET|DEFERRED_EXPENSE)$") String objectType,
            @NotBlank @Size(max = 64) String code,
            @NotBlank @Size(max = 160) String name,
            @NotNull LocalDate effectiveFrom,
            @Pattern(regexp = "^STRAIGHT_LINE$") String defaultMethod,
            @Min(1) @Max(1200) Integer defaultUsefulMonths,
            @DecimalMin("0.0000") @DecimalMax("1.000000")
            @Digits(integer = 1, fraction = 6) BigDecimal defaultResidualRate,
            UUID costStyleId,
            UUID accumulatedStyleId,
            UUID expenseStyleId,
            UUID clearingStyleId,
            List<@NotBlank @Size(max = 64) String> requiredDocumentCodes,
            @Size(max = 2000) String remark,
            Long expectedVersion) {}

    public record Category(
            UUID id,
            String objectType,
            String code,
            String name,
            int categoryVersion,
            String status,
            LocalDate effectiveFrom,
            String defaultMethod,
            Integer defaultUsefulMonths,
            @JsonFormat(shape = JsonFormat.Shape.STRING) BigDecimal defaultResidualRate,
            UUID costStyleId,
            UUID accumulatedStyleId,
            UUID expenseStyleId,
            UUID clearingStyleId,
            List<String> requiredDocumentCodes,
            boolean policyReady,
            List<String> missingPolicyItems,
            long rowVersion) {}
}
