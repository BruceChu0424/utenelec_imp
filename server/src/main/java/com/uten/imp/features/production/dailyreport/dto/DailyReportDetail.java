package com.uten.imp.features.production.dailyreport.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 生产日报详情（含明细行）。 */
@Getter
@AllArgsConstructor
public class DailyReportDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID warehouseId;
    private UUID departmentId;
    private String workshopName;
    private UUID workerId;
    private UUID supplierId;
    private UUID makerId;
    private UUID approverId;
    private Integer makerLegacyId;
    private Integer approverLegacyId;
    private String remark;
    private Short status;
    private boolean closed;
    private boolean canceled;
    private String sourceDocNo;
    private List<DailyReportItemDto> items;
}
