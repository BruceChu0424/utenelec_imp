package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
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
                                    boolean requiresSupplement,String fingerprint,BigDecimal originalSalesQty,BigDecimal originalInternalQty,
                                    @JsonSerialize(using=ExactDecimalText.class) BigDecimal withinAuthorizationQty,
                                    @JsonSerialize(using=ExactDecimalText.class) BigDecimal overLimitQty) {
        @JsonProperty(value="actualQtyExact",access=JsonProperty.Access.READ_ONLY)
        @JsonSerialize(using=ExactDecimalText.class)
        public BigDecimal actualQtyExact(){return actualQty;}
    }
    public record ReportPreview(java.util.List<ReportLinePreview> lines,boolean requiresSupplements) {}
    public record ApproveRequest(@NotBlank @Size(min=8,max=128) String idempotencyKey) {}
    /**
     * 取消追加实产：原因选填(2026-11-11 口径「弹窗原因不用必填」)。留空在构造期归一为
     * 「未填写原因」——落库列 production_actual_output_supplement_reversals.reason
     * 库级 CHECK 要求 btrim 后非空(单个字可原样保留)，消费方直接取 {@code reason()} 落库。
     */
    public record CancelRequest(@Size(max=1000) String reason,@NotBlank @Size(min=8,max=128) String idempotencyKey) {
        public static final String DEFAULT_REASON = "未填写原因";
        public CancelRequest {
            if (reason == null || reason.strip().isEmpty()) {
                reason = DEFAULT_REASON;
            }
        }
    }
    public record Preview(UUID sourceSegmentId,UUID sourcePlanId,String sourcePlanNo,String segmentCode,
                          UUID goodsId,UUID colorId,UUID unitId,BigDecimal unitRate,UUID workshopDepartmentId,UUID responsibleEmployeeId,
                          BigDecimal plannedQty,BigDecimal priorReportedQty,BigDecimal effectiveRate,BigDecimal thresholdQty,
                          BigDecimal remainingActualSurplusQty,BigDecimal actualQty,BigDecimal originalReportQty,BigDecimal supplementQty,
                          boolean requiresSupplement,String fingerprint,UUID sourceSalesAllocationId,BigDecimal originalSalesQty,BigDecimal originalInternalQty) {
        @JsonProperty(value="actualQtyExact",access=JsonProperty.Access.READ_ONLY)
        public String actualQtyExact(){return actualQty==null?null:actualQty.toPlainString();}
    }
    public record View(UUID id,String status,UUID planId,String planNo,UUID proofId,UUID supplementSegmentId,Long supplementSegmentVersion,
                       BigDecimal actualQty,BigDecimal originalReportQty,BigDecimal supplementQty,UUID sourceSegmentId,
                       String supplementSegmentStatus,boolean canStart,com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine sourceLine,
                       com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest reportContext,Integer inputLineIndex,UUID excludedReportId,
                       java.util.List<RelatedSupplement> relatedSupplements,java.util.List<InputSource> inputSources) {
        @JsonProperty(value="actualQtyExact",access=JsonProperty.Access.READ_ONLY)
        public String actualQtyExact(){return actualQty==null?null:actualQty.toPlainString();}
    }
    public record InputSource(int inputLineIndex,com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine sourceLine) {}
    public record RelatedSupplement(UUID id,Integer inputLineIndex,UUID sourceSegmentId,UUID sourceSalesAllocationId,BigDecimal actualQty,
                                    UUID proofId,String status,UUID supplementSegmentId,String segmentStatus) {
        @JsonProperty(value="actualQtyExact",access=JsonProperty.Access.READ_ONLY)
        public String actualQtyExact(){return actualQty==null?null:actualQty.toPlainString();}
    }
}
