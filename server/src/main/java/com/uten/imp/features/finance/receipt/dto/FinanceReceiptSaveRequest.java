package com.uten.imp.features.finance.receipt.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 销售收款单新建/编辑请求（主表字段 + 明细行）。明细可为空（直接收款，无显式核销）。 */
@Getter
@Setter
public class FinanceReceiptSaveRequest {

    private String billNo;
    private Long expectedVersion;

    @Size(min = 8, max = 128)
    private String createIdempotencyKey;

    @NotNull
    private LocalDate billDate;

    /** Explicit business branch; line existence is never used as an implicit money classification. */
    @NotBlank
    private String receiptKind;
    private UUID salesOrderId;
    private UUID clientId;
    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private BigDecimal bankFee;
    private BigDecimal otherFee;
    private UUID otherFeeStyleId;
    private String settlementChannel;
    private UUID settlementAgentSupplierId;
    private String exchangeRateSource;
    private OffsetDateTime exchangeRateEffectiveAt;
    private OffsetDateTime bankBookedAt;
    @NotBlank
    @Size(max = 128)
    private String bankReference;
    @Size(max = 128)
    private String agentStatementNo;
    /** Expected account currency from the client dictionary; server locks and owns the snapshot. */
    private UUID accountCurrencyId;
    private BigDecimal accountAmount;
    private BigDecimal bankFeeAccountAmount;
    private BigDecimal otherFeeAccountAmount;
    private String feeSettlementMode;
    private String feeBearer;
    private UUID feePaymentAccountId;
    private UUID receiptMethodId;
    private Integer receiptMethodLegacyId;
    private String invoiceNo;
    private UUID operatorId;
    private String sourceRemark;
    private String remark;

    /** 核销明细（可空：空列表 = 直接收款 / 客户预付；非空 = 指定核销若干 AR）。 */
    @Valid
    @Size(max = RequestLimits.DOCUMENT_LINES)
    private List<FinanceReceiptLineInput> items;
}
