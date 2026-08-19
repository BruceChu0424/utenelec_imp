package com.uten.imp.features.subcontract.receipt.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 委外进仓单详情（主表全字段 + 明细列表）。 */
@Getter
@AllArgsConstructor
public class ReceiptDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID warehouseId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private UUID senderId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate lastDate;
    private boolean apPosted;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<ReceiptItemDto> items;

    private Integer settlementStyleLegacy;
    private UUID settlementMethodId;
    private Integer receiverLegacyId;
    private String receiverName;
    private Integer makerLegacyId;
    private String makerName;
    private Integer approverLegacyId;
    private String approverName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** 来源委外订货单（全部明细同源时给出，供详情页跳转；跨订单为 null，看明细行谱系）。 */
    private UUID sourceOrderId;
    private String sourceOrderNo;
    /** 价格已对当前用户脱敏（单价/金额族置 null，前端据此渲染 ***；V302 收货单价格脱敏）。 */
    private boolean priceMasked;
}
