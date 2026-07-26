package com.uten.imp.features.production.plan.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 生产计划新建/编辑请求。 */
@Getter
@Setter
public class PlanSaveRequest {
    @NotBlank
    private String billNo;
    @NotNull
    private LocalDate billDate;
    private String fStyle;
    private LocalDate deliveryDate;
    private UUID departmentId;
    private String workshopName;
    private String workerName;
    private String sellerName;
    private String remark;
    private String sourceDocNo;

    @Valid
    @NotNull
    private List<PlanItemLine> items;
}
