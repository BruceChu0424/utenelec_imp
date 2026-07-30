package com.uten.imp.features.production.plan.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 生产计划新建/编辑请求。 */
@Getter
@Setter
public class PlanSaveRequest {
    private String billNo;
    @NotNull
    private LocalDate billDate;
    private String fStyle;
    private LocalDate deliveryDate;
    private UUID departmentId;
    private String workshopName;
    private String workerName;
    private String sellerName;
    private UUID sellerId;
    private UUID workerId;
    private String remark;
    private String sourceDocNo;

    @Valid
    @NotNull
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<PlanItemLine> items;
}
