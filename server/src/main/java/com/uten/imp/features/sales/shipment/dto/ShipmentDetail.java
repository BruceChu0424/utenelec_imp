package com.uten.imp.features.sales.shipment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 销售出货详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class ShipmentDetail {
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
    private UUID senderId;
    private UUID makerId;
    private UUID approverId;
    private String shipAddr;
    private String linkPhone;
    private Integer parcelCount;
    private Integer printCount;
    private java.time.OffsetDateTime lastDate;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private UUID sourceOrderId;
    private String sourceDocNo;
    private boolean arPosted;
    private boolean rejected;
    private String rejectReason;
    /** C6 财务发货审核：0 未审 / 1 已审发货。 */
    private Short financeAudit;
    private java.time.OffsetDateTime financeAuditedAt;
    private String warehouseWorkStatus;
    private java.time.OffsetDateTime warehouseWorkUpdatedAt;
    private java.time.OffsetDateTime pickingStartedAt;
    private java.time.OffsetDateTime pickedAt;
    private java.time.OffsetDateTime handedOverAt;
    private String warehouseExceptionReason;
    private List<ShipmentItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** Current caller may mutate this document through normal sales actions. */
    private boolean writable;
    /** Current caller may reject this draft, including explicit reject-authority bypass. */
    private boolean canReject;
    /** Current caller can execute warehouse work independent of sales owner scope. */
    private boolean canManageWarehouseWork;
}
