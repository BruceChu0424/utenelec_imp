package com.uten.imp.features.sales.quote.dto;

import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 销售报价详情(主表全字段 + 明细 + 核价状态与修订时间线)。
 *
 * <p>statusBucket: DRAFT 草稿 / FINANCE_REJECTED 财务退回 / PENDING_FINANCE 待财务核价 / APPROVED 已核价 /
 * REVERSED 作废。allowedActions 由服务端按当前用户计算(edit, delete, submit, withdraw, reopen, convert,
 * reverse, financeReview), 前端按它显示按钮。
 */
@Getter
@Setter
@NoArgsConstructor
public class QuoteDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID clientId;
    private UUID makerId;
    private UUID approverId;
    private LocalDate validUntil;
    private String remark;
    private BigDecimal totalOriginal;
    private BigDecimal totalLocal;
    private Short status;
    private boolean closed;
    private String sourceDocNo;
    private List<QuoteItemDto> items;
    /** 制单员姓名(服务端按 maker_id 解析)。 */
    private String makerName;
    /** 制单时间(审计 created_at, 创建后不可变)。 */
    private java.time.Instant createdAt;
    /** Current caller may mutate this document (functional permission + owner scope + draft). */
    private boolean writable;

    private UUID currencyId;
    private UUID sellerId;
    private String sellerName;
    private LocalDate deliverDate;
    private UUID settlementMethodId;
    private String contractNo;
    private String clientFileCurrency;

    private String statusBucket;
    private OffsetDateTime submittedAt;
    private String submittedByName;
    private String financeReturnReason;
    private OffsetDateTime financeReturnedAt;
    private String financeReturnedByName;
    private OffsetDateTime financeConfirmedAt;
    private String financeConfirmedByName;
    private String financeRemark;
    private int reviewRevision;
    private UUID convertedOrderId;
    private String convertedOrderNo;
    private List<String> allowedActions;
    /** 价格脱敏: 无订单价格查看权限且不是核价人时为 true, 单价/折扣/金额已置空。 */
    private boolean priceMasked;
    /** 还没有单价(等财务定价)的行数。 */
    private int pricePendingCount;
    private List<QuoteRevisionDto> revisions;

    // Exact text is derived after permission masking; null stays null.
    public String getTotalOriginalExact() { return com.uten.imp.common.util.DecimalText.of(totalOriginal); }
    public String getTotalLocalExact() { return com.uten.imp.common.util.DecimalText.of(totalLocal); }
}
