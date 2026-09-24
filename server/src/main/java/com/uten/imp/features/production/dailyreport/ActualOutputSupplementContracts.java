package com.uten.imp.features.production.dailyreport;

import jakarta.validation.constraints.*;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

public final class ActualOutputSupplementContracts {
    private ActualOutputSupplementContracts() {}
    public record PreviewRequest(@NotNull UUID sourceExecutionSegmentId,@NotNull @DecimalMin("0.0001") BigDecimal actualQty,
                                 UUID sourceSalesAllocationId,UUID excludedReportId) {}
    public record CreateRequest(@NotNull UUID sourceExecutionSegmentId,@NotNull @DecimalMin("0.0001") BigDecimal actualQty,
                                UUID sourceSalesAllocationId,@NotBlank String fingerprint,@NotNull LocalDate billDate,
                                LocalDate deliveryDate,@Size(max=1000) String remark,@NotBlank @Size(min=8,max=128) String idempotencyKey,
                                UUID excludedReportId,com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest reportContext,Integer inputLineIndex) {}
    public record ReportPreviewRequest(@NotNull @jakarta.validation.Valid com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest report,UUID excludedReportId) {}
    public record ReportLinePreview(int inputLineIndex,UUID sourceExecutionSegmentId,UUID sourceSalesAllocationId,BigDecimal actualQty,
                                    BigDecimal originalReportQty,BigDecimal supplementQty,BigDecimal remainingActualSurplusQty,
                                    boolean requiresSupplement,String fingerprint,BigDecimal originalSalesQty,BigDecimal originalInternalQty) {}
    public record ReportPreview(java.util.List<ReportLinePreview> lines,boolean requiresSupplements) {}
    public record ApproveRequest(@NotBlank @Size(min=8,max=128) String idempotencyKey) {}
    public record CancelRequest(@NotBlank @Size(max=1000) String reason,@NotBlank @Size(min=8,max=128) String idempotencyKey) {}
    public record Preview(UUID sourceSegmentId,UUID sourcePlanId,String sourcePlanNo,String segmentCode,
                          UUID goodsId,UUID colorId,UUID unitId,BigDecimal unitRate,UUID workshopDepartmentId,UUID responsibleEmployeeId,
                          BigDecimal plannedQty,BigDecimal priorReportedQty,BigDecimal effectiveRate,BigDecimal thresholdQty,
                          BigDecimal remainingActualSurplusQty,BigDecimal actualQty,BigDecimal originalReportQty,BigDecimal supplementQty,
                          boolean requiresSupplement,String fingerprint,UUID sourceSalesAllocationId,BigDecimal originalSalesQty,BigDecimal originalInternalQty) {}
    public record View(UUID id,String status,UUID planId,String planNo,UUID proofId,UUID supplementSegmentId,Long supplementSegmentVersion,
                       BigDecimal actualQty,BigDecimal originalReportQty,BigDecimal supplementQty,UUID sourceSegmentId,
                       String supplementSegmentStatus,boolean canStart,com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine sourceLine,
                       com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest reportContext,Integer inputLineIndex,UUID excludedReportId,
                       java.util.List<RelatedSupplement> relatedSupplements,java.util.List<InputSource> inputSources) {}
    public record InputSource(int inputLineIndex,com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine sourceLine) {}
    public record RelatedSupplement(UUID id,Integer inputLineIndex,UUID sourceSegmentId,UUID sourceSalesAllocationId,BigDecimal actualQty,
                                    UUID proofId,String status,UUID supplementSegmentId,String segmentStatus) {}
}
