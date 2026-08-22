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
    private UUID settlementMethodId;
    private UUID sellerId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate deliverDate;
    private String contractNo;
    private String linkPhone;
    private String signAddr;
    private String shipAddr;
    /** Historical commercial snapshot only; never a finance receipt/prepayment fact. */
    private BigDecimal legacyDepositSnapshot;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private boolean stopped;
    private String shipmentPolicy;
    private java.time.OffsetDateTime partialShipmentConfirmedAt;
    private UUID partialShipmentConfirmedBy;
    private String partialShipmentConfirmationReason;
    @lombok.Setter
    private String sourceDocNo;
    /** 来源报价单 UUID（按 sales_orders.source_quote_id 回联；单号仅作历史显示快照）。 */
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
    /** Current caller may mutate this document (functional permission + owner scope). */
    private boolean writable;
    /** 该订单全部出货单聚合（含物流单号/仓库状态；SOP §三.7：分批多单全部展示，非仅一张）。 */
    private List<OrderShipmentRefDto> shipments;
    /** 财务确认（V294）：false=待财务确认（计划部不可见/不可排产）；仅已审订单有意义。 */
    private boolean financeConfirmed;
    private java.time.OffsetDateTime financeConfirmedAt;
    /** 财务确认人姓名（服务端按 finance_confirmed_by 解析）。 */
    private String financeConfirmedByName;
    private String financeConfirmRemark;
    /** 财务驳回（V300）：已驳回待销售修正，原因随详情下发；确认后自动清除。 */
    private boolean financeRejected;
    private String financeRejectedReason;
    private java.time.OffsetDateTime financeRejectedAt;
    /** 财务驳回人姓名（服务端按 finance_rejected_by 解析）。 */
    private String financeRejectedByName;
}
