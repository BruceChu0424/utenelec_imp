package com.uten.imp.features.sales.other_shipment.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 其它出货详情（主表全字段 + 明细列表）。无 ar_posted（不立应收）。 */
@Getter
@AllArgsConstructor
public class OtherShipmentDetail {
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
    private OffsetDateTime lastDate;
    private String outType;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private UUID sourceOrderId;
    private String sourceDocNo;
    private List<OtherShipmentItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** Current caller may mutate this document (functional permission + owner scope). */
    private boolean writable;
}
