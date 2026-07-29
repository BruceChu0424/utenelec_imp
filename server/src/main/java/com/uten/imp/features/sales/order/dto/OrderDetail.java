package com.uten.imp.features.sales.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 销售订货详情（主表全字段 + 明细列表 + BOM 展开只读列表）。 */
@Getter
@AllArgsConstructor
public class OrderDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal taxRate;
    private Integer paymentStyleId;
    private UUID sellerId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate deliverDate;
    private String contractNo;
    private String linkPhone;
    private String signAddr;
    private String shipAddr;
    private BigDecimal deposit;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private String sourceDocNo;
    /** 来源报价单 ID（sourceDocNo 命中报价单号时由详情接口回联填充，前端跳报价详情/比价用）。 */
    @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL)
    @lombok.Setter
    private UUID sourceQuoteId;
    /** 价格脱敏（SOP §三8）：无 sales_order:price:view 时 true，价格族字段已置 null，前端渲染 ***。 */
    private boolean priceMasked;
    private List<OrderItemDto> items;
    /** BOM 展开只读（design 20 §一·13，本期不做编辑）。 */
    private List<OrderCostItemDto> costItems;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
}
