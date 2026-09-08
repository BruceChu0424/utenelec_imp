package com.uten.imp.features.finance.payment.dto;

import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 采购付款单详情。 */
@Getter
public class FinancePaymentDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID supplierId;
    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private UUID paymentMethodId;
    private Integer paymentMethodLegacyId;
    private String invoiceNo;
    private OffsetDateTime cancelDate;
    private String operatorName;
    private UUID operatorId;
    private UUID makerId;
    private UUID approverId;
    private String sourceRemark;
    private String remark;
    private Short status;
    private boolean closed;
    private List<FinancePaymentLineDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
    /** 草稿乐观并发版本；编辑请求必须原样回传 expectedVersion。 */
    private long version;
    /** 创建请求幂等键；同一制单人重试同一请求时返回原单。 */
    private String createIdempotencyKey;


    /** Retains the existing DTO constructor for legacy callers. */
    public FinancePaymentDetail(UUID id, Integer legacyId, String billNo, LocalDate billDate, UUID supplierId, UUID accountId, UUID counterpartAccountId, UUID currencyId, BigDecimal exchangeRate, BigDecimal amountOriginal, BigDecimal amountLocal, UUID paymentMethodId, Integer paymentMethodLegacyId, String invoiceNo, OffsetDateTime cancelDate, String operatorName, UUID operatorId, UUID makerId, UUID approverId, String sourceRemark, String remark, Short status, boolean closed, List<FinancePaymentLineDto> items, String makerName, java.time.Instant createdAt, long version, String createIdempotencyKey) {
        this.id=id;
        this.legacyId=legacyId;
        this.billNo=billNo;
        this.billDate=billDate;
        this.supplierId=supplierId;
        this.accountId=accountId;
        this.counterpartAccountId=counterpartAccountId;
        this.currencyId=currencyId;
        this.exchangeRate=exchangeRate;
        this.amountOriginal=amountOriginal;
        this.amountLocal=amountLocal;
        this.paymentMethodId=paymentMethodId;
        this.paymentMethodLegacyId=paymentMethodLegacyId;
        this.invoiceNo=invoiceNo;
        this.cancelDate=cancelDate;
        this.operatorName=operatorName;
        this.operatorId=operatorId;
        this.makerId=makerId;
        this.approverId=approverId;
        this.sourceRemark=sourceRemark;
        this.remark=remark;
        this.status=status;
        this.closed=closed;
        this.items=items;
        this.makerName=makerName;
        this.createdAt=createdAt;
        this.version=version;
        this.createIdempotencyKey=createIdempotencyKey;
    }

    @com.fasterxml.jackson.annotation.JsonIgnore
    @lombok.Getter(lombok.AccessLevel.NONE)
    private BankAuthority bankAuthority;
    private record BankAuthority(short version,UUID accountCurrencyId,BigDecimal accountExchangeRate,
            BigDecimal accountAmount,BigDecimal accountAmountLocal,BigDecimal bankFeeAccountAmount,
            BigDecimal bankFee,String bankReference,OffsetDateTime bankBookedAt) {}
    public FinancePaymentDetail withBankAuthority(com.uten.imp.features.finance.payment.FinancePayment payment) {
        bankAuthority=new BankAuthority(payment.getAmountAuthorityVersion(),payment.getAccountCurrencyId(),
                payment.getAccountExchangeRate(),payment.getAccountAmount(),payment.getAccountAmountLocal(),
                payment.getBankFeeAccountAmount(),payment.getBankFeeLocal(),payment.getBankReference(),payment.getBankBookedAt());
        return this;
    }
    public short getSettlementAuthorityVersion(){return bankAuthority==null?0:bankAuthority.version();}
    public short getAmountAuthorityVersion(){return getSettlementAuthorityVersion();}
    public UUID getAccountCurrencyId(){return bankAuthority==null?null:bankAuthority.accountCurrencyId();}
    public BigDecimal getAccountExchangeRate(){return bankAuthority==null?null:bankAuthority.accountExchangeRate();}
    public BigDecimal getAccountAmount(){return bankAuthority==null?null:bankAuthority.accountAmount();}
    public BigDecimal getAccountAmountLocal(){return bankAuthority==null?null:bankAuthority.accountAmountLocal();}
    public BigDecimal getBankFeeAccountAmount(){return bankAuthority==null?null:bankAuthority.bankFeeAccountAmount();}
    public BigDecimal getBankFee(){return bankAuthority==null?null:bankAuthority.bankFee();}
    public String getBankReference(){return bankAuthority==null?null:bankAuthority.bankReference();}
    public OffsetDateTime getBankBookedAt(){return bankAuthority==null?null:bankAuthority.bankBookedAt();}
    public String getAccountExchangeRateExact(){return com.uten.imp.common.util.DecimalText.of(getAccountExchangeRate());}
    public String getAccountAmountExact(){return com.uten.imp.common.util.DecimalText.of(getAccountAmount());}
    public String getAccountAmountLocalExact(){return com.uten.imp.common.util.DecimalText.of(getAccountAmountLocal());}
    public String getBankFeeAccountAmountExact(){return com.uten.imp.common.util.DecimalText.of(getBankFeeAccountAmount());}
    public String getBankFeeExact(){return com.uten.imp.common.util.DecimalText.of(getBankFee());}

    // Additive exact text never passes through a binary floating-point value.
    public String getExchangeRateExact() { return com.uten.imp.common.util.DecimalText.of(exchangeRate); }
    public String getAmountOriginalExact() { return com.uten.imp.common.util.DecimalText.of(amountOriginal); }
    public String getAmountLocalExact() { return com.uten.imp.common.util.DecimalText.of(amountLocal); }
}
