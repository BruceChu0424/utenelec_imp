package com.uten.imp.features.production.dailyreport.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 生产日报新建/编辑请求。 */
@Getter
@Setter
public class DailyReportSaveRequest {
    private String billNo;
    @NotNull private LocalDate billDate;
    private UUID warehouseId;
    private UUID departmentId;
    private String workshopName;
    private UUID workerId;
    private UUID supplierId;
    private String remark;
    private String sourceDocNo;

    @Valid @NotNull
    private List<DailyReportItemLine> items;
}
