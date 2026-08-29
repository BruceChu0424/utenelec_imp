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
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** 当前乐观锁版本；PUT 时原样回传为 expectedVersion。 */
    private long rowVersion;
}
