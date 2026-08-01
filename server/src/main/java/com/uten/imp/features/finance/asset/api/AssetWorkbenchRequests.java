package com.uten.imp.features.finance.asset.api;

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
import java.util.UUID;

/** Typed command contracts for the asset and deferred-expense workbench. */
public final class AssetWorkbenchRequests {

    public static final String PERIOD = "^\\d{4}-(?:0[1-9]|1[0-2])$";

    private AssetWorkbenchRequests() {}

    public record FixedAssetDraft(
            @Size(max = 64) String code,
            @NotBlank @Size(max = 200) String name,
            UUID categoryId,
            UUID departmentId,
            UUID custodianId,
            @Size(max = 300) String location,
            @Size(max = 160) String serialNumber,
            @Size(max = 100) String assetTag,
            @Size(max = 100) String costCenterCode,
            @NotNull @DecimalMin("0.01") @Digits(integer = 16, fraction = 2) BigDecimal originalValue,
            @DecimalMin("0.0000") @DecimalMax("1.000000")
            @Digits(integer = 1, fraction = 6) BigDecimal salvageRate,
            @NotNull @Min(1) @Max(1200) Integer usefulMonths,
            @NotBlank @Pattern(regexp = PERIOD) String startPeriod,
            LocalDate acquisitionDate,
            LocalDate acceptanceDate,
            LocalDate readyForUseDate,
            @Size(max = 50) String sourceType,
            UUID sourceId,
            @Size(max = 200) String sourceRef,
            @Size(max = 200) String sourceLineRef,
            LocalDate sourceDocumentDate,
            @Size(max = 2000) String remark,
            Long expectedVersion) {}

    public record DeferredExpenseDraft(
            @Size(max = 64) String code,
            @NotBlank @Size(max = 200) String name,
            UUID categoryId,
            UUID departmentId,
            UUID responsibleEmployeeId,
            @Size(max = 300) String location,
            @Size(max = 100) String costCenterCode,
            @NotNull @DecimalMin("0.01") @Digits(integer = 16, fraction = 2) BigDecimal totalAmount,
            @NotNull @Min(1) @Max(1200) Integer usefulMonths,
            @NotBlank @Pattern(regexp = PERIOD) String startPeriod,
            LocalDate benefitStartDate,
            LocalDate benefitEndDate,
            @Size(max = 50) String sourceType,
            UUID sourceId,
            @Size(max = 200) String sourceRef,
            @Size(max = 200) String sourceLineRef,
            LocalDate sourceDocumentDate,
            @Size(max = 2000) String remark,
            Long expectedVersion) {}

    public record VersionCommand(@NotNull @Min(0) Long expectedVersion) {}

    public record ApprovalCommand(
            @NotNull @Min(0) Long expectedVersion,
            @Size(max = 2000) String comment) {}

    public record ReasonCommand(
            @NotNull @Min(0) Long expectedVersion,
            @NotBlank @Size(max = 2000) String reason) {}

    public record TransferCommand(
            @NotNull @Min(0) Long expectedVersion,
            @NotNull UUID targetDepartmentId,
            @NotNull UUID custodianId,
            @NotBlank @Size(max = 300) String location,
            @NotBlank @Size(max = 2000) String reason,
            @NotNull LocalDate effectiveDate) {}

    public record OperatingStatusCommand(
            @NotNull @Min(0) Long expectedVersion,
            @NotBlank @Pattern(regexp = "^(?:PENDING_ACCEPTANCE|IN_USE|IDLE|UNDER_REPAIR|LOANED|LOST_PENDING)$")
                    String operatingStatus,
            @NotBlank @Size(max = 2000) String reason,
            @NotNull LocalDate effectiveDate) {}

    public record DisposalCommand(
            @NotNull @Min(0) Long expectedVersion,
            @NotBlank @Size(max = 2000) String reason,
            @NotNull LocalDate effectiveDate,
            @NotNull @DecimalMin("0.00") @Digits(integer = 16, fraction = 2) BigDecimal proceedsAmount,
            @Size(max = 1000) String evidenceReference) {}

    public record TerminationCommand(
            @NotNull @Min(0) Long expectedVersion,
            @NotBlank @Size(max = 2000) String reason,
            @NotNull LocalDate effectiveDate,
            @Size(max = 1000) String evidenceReference) {}

    public record PostingPreviewCommand(
            @NotBlank @Pattern(regexp = "^(?:DEPRECIATION|AMORTIZATION)$") String runType,
            @Pattern(regexp = "^(?:CORPORATE|TAX)$") String bookType,
            @NotBlank @Pattern(regexp = PERIOD) String period) {}

    public record PostingActionCommand(
            @NotNull @Min(0) Long expectedVersion,
            @Size(max = 128) String token) {}

    public record PostingReasonCommand(
            @NotNull @Min(0) Long expectedVersion,
            @NotBlank @Size(max = 2000) String reason) {}

    public record PeriodCloseCommand(
            @NotBlank @Size(max = 2000) String reason,
            @NotNull @Min(0) Long expectedVersion) {}

    public record PeriodReopenCommand(
            @NotBlank @Size(max = 2000) String reason,
            @NotNull @Min(0) Long expectedVersion) {}
}
