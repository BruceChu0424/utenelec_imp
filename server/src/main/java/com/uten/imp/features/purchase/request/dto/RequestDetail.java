package com.uten.imp.features.purchase.request.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@Getter @AllArgsConstructor
public class RequestDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID warehouseId;
    private UUID departmentId;
    private UUID applicantId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate needDate;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<RequestItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    private boolean productionLinked;
    private boolean canEdit;
    private boolean canDelete;
    private boolean canReverse;
    private String restrictionReason;
    /** Display only; applicantId remains the stable employee reference. */
    private String applicantName;
}
