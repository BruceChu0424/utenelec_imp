package com.uten.imp.features.production.plan.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.LocalDate;
import java.util.UUID;

/** 生产计划列表行（前端解析车间/部门名称）。 */
@Getter
@AllArgsConstructor
public class PlanListItem {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private LocalDate deliveryDate;
    private UUID departmentId;
    private String workshopName;
    private String workerName;
    private String sellerName;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private boolean canceled;
    private Integer legacyId;
}
