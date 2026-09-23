package com.uten.imp.features.finance.accountflow;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 一笔资金账户过账(ADR-112 / dup-backend-split-04): 改余额 + 写一条对账流水, 只经
 * {@link AccountFlowLedgerService#post} 落库。
 *
 * <p>金额口径由 {@link CurrencyRule} 决定: 单据给出原币与本币, 账户记哪一个由账户币种决定,
 * 规则只在账本服务里写一次。
 */
public final class AccountPosting {

    /** 资金方向。IN 记 receipts_total, OUT 记 payments_total, ADJUSTMENT 记 balance_adjustments_total。 */
    public enum Direction { IN, OUT, ADJUSTMENT }

    /** 账户币种规则。 */
    public enum CurrencyRule {
        /** 只允许启用的本位币账户; 单据币种(若给出)必须等于账户币种; 账户记本币。 */
        BASE_ONLY,
        /** 本位币账户记本币; 与单据原币相同的外币账户记原币; 第三币种账户拒绝。 */
        BASE_OR_DOCUMENT_CURRENCY,
        /** 单据已冻结真实账户币种与账户原生金额: 账户币种必须一致, 记原生金额。 */
        ACCOUNT_CURRENCY,
        /** 账户余额校准: 直接记账户原生金额(带符号)。 */
        ANY
    }

    final String sourceDocType;
    final UUID sourceDocId;
    final String billNo;
    final UUID accountId;
    final Direction direction;
    CurrencyRule currencyRule = CurrencyRule.BASE_ONLY;
    UUID documentCurrencyId;
    BigDecimal originalAmount;
    BigDecimal localAmount;
    OffsetDateTime bookedAt;
    OffsetDateTime settledAt;
    String checkNo;
    String counterpartName;
    String sourceRemark;
    String remark;
    Integer legacyBstyle;
    UUID flowId;
    UUID actorUserId;
    String accountLabel = "资金账户";

    private AccountPosting(String sourceDocType, UUID sourceDocId, String billNo,
                           UUID accountId, Direction direction) {
        this.sourceDocType = sourceDocType;
        this.sourceDocId = sourceDocId;
        this.billNo = billNo;
        this.accountId = accountId;
        this.direction = direction;
    }

    public static AccountPosting in(String sourceDocType, UUID sourceDocId, String billNo, UUID accountId) {
        return new AccountPosting(sourceDocType, sourceDocId, billNo, accountId, Direction.IN);
    }

    public static AccountPosting out(String sourceDocType, UUID sourceDocId, String billNo, UUID accountId) {
        return new AccountPosting(sourceDocType, sourceDocId, billNo, accountId, Direction.OUT);
    }

    public static AccountPosting adjustment(String sourceDocType, UUID sourceDocId, String billNo, UUID accountId) {
        AccountPosting posting = new AccountPosting(sourceDocType, sourceDocId, billNo, accountId, Direction.ADJUSTMENT);
        posting.currencyRule = CurrencyRule.ANY;
        return posting;
    }

    /** 币种规则与单据币种(BASE_ONLY 可为空, 表示不另核对单据币种)。 */
    public AccountPosting rule(CurrencyRule rule, UUID documentCurrencyId) {
        this.currencyRule = rule;
        this.documentCurrencyId = documentCurrencyId;
        return this;
    }

    /** 单据原币金额与本币金额(ADJUSTMENT 为账户原生差额与其本币差额)。 */
    public AccountPosting amounts(BigDecimal originalAmount, BigDecimal localAmount) {
        this.originalAmount = originalAmount;
        this.localAmount = localAmount;
        return this;
    }

    public AccountPosting bookedAt(OffsetDateTime bookedAt) {
        this.bookedAt = bookedAt;
        return this;
    }

    public AccountPosting settledAt(OffsetDateTime settledAt) {
        this.settledAt = settledAt;
        return this;
    }

    public AccountPosting checkNo(String checkNo) {
        this.checkNo = checkNo;
        return this;
    }

    public AccountPosting counterpart(String counterpartName) {
        this.counterpartName = counterpartName;
        return this;
    }

    public AccountPosting sourceRemark(String sourceRemark) {
        this.sourceRemark = sourceRemark;
        return this;
    }

    public AccountPosting remark(String remark) {
        this.remark = remark;
        return this;
    }

    /** 老系统 BStyle 标签(收款 20 / 付款 21 / 其它收入 22 / 费用 23 / 转账 27), 新来源可为空。 */
    public AccountPosting legacyBstyle(Integer legacyBstyle) {
        this.legacyBstyle = legacyBstyle;
        return this;
    }

    /** 调用方需要事先知道流水主键时指定(例如写回来源单据), 否则自动生成。 */
    public AccountPosting flowId(UUID flowId) {
        this.flowId = flowId;
        return this;
    }

    public AccountPosting actor(UUID actorUserId) {
        this.actorUserId = actorUserId;
        return this;
    }

    /** 报错时的账户称呼, 例如「费用付款账户」。 */
    public AccountPosting label(String accountLabel) {
        this.accountLabel = accountLabel;
        return this;
    }
}
