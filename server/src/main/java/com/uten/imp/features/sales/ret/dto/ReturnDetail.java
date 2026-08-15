package com.uten.imp.features.sales.ret.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 销售退货详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class ReturnDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID settlementMethodId;
    private UUID sellerId;
    private UUID makerId;
    private UUID approverId;
    private OffsetDateTime lastDate;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private UUID sourceShipmentId;
    private String sourceDocNo;
    private boolean arPosted;
    private List<ReturnItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** Current caller may mutate this document (functional permission + owner scope). */
    private boolean writable;
    /** 退货原因（销售退货专属）。 */
    private String returnReason;
    // ---- 客户处置 ----
    /** 客户处置结论（REFUND_CLOSED/EXCHANGE/RESHIP/REPAIR_RETURN）；未决策为 null。 */
    private String customerDisposition;
    /** 客户处置状态（PENDING/DECIDED）。 */
    private String dispositionStatus;
    /** 处置决策人（员工）。 */
    private UUID dispositionDecidedBy;
    /** 处置决策时间。 */
    private OffsetDateTime dispositionDecidedAt;
    /** 处置原因。 */
    private String dispositionReason;
    /** RESHIP/EXCHANGE 是否已重开替换履约预留。 */
    private boolean fulfilmentReopened;
}
