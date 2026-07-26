package com.uten.imp.features.production.dailyreport.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.LocalDate;
import java.util.UUID;

/** 生产日报列表行。 */
@Getter
@AllArgsConstructor
public class DailyReportListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID warehouseId;
    private UUID departmentId;
    private String workshopName;
    private UUID workerId;
    private UUID supplierId;
    private Short status;
    private boolean closed;
    private boolean canceled;
    private Integer legacyId;
}
