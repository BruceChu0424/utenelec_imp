package com.uten.imp.features.production.plan.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 生产计划详情（含明细行）。 */
@Getter
@AllArgsConstructor
public class PlanDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private String fStyle;
    private LocalDate deliveryDate;
    private UUID departmentId;
    private String workshopName;
    private String workerName;
    private String sellerName;
    private UUID sellerId;
    private UUID workerId;
    private UUID makerId;
    private UUID approverId;
    private Integer makerLegacyId;
    private Integer approverLegacyId;
    private String remark;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private boolean canceled;
    private String sourceDocNo;
    private List<PlanItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
}
