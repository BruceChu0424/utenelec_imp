package com.uten.imp.features.finance.accountflow;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

/**
 * 资金账户过账的唯一写入口(ADR-112 / dup-backend-split-04)。
 *
 * <p>{@code accounts} 的余额与累计列、{@code finance_reconciliations} 的正向/反向流水只在这里写:
 * 锁账户并校验启用状态、按 {@link AccountPosting.CurrencyRule} 决定账户记原币还是本币、改余额、写流水;
 * 红冲按原始流水逐笔反向并同步恢复余额, 不按今天的汇率或单据金额重算。业务服务只负责自己的单据与子账,
 * 必须在调用方事务内调用。锁顺序: 调用方先锁总账期间, 再在这里锁账户。
 */
@Service
@RequiredArgsConstructor
public class AccountFlowLedgerService {

    private static final String POSTING = "POSTING";
    private static final String REVERSAL = "REVERSAL";

    private final EntityManager em;

    /** 已在本事务锁住(FOR UPDATE)的启用账户; 只能由 {@link #lockActive} 产生。 */
    public static final class LockedAccount {
        private final UUID accountId;
        private final UUID currencyId;
        private final boolean baseCurrency;
        private final UUID styleId;

        LockedAccount(UUID accountId, UUID currencyId, boolean baseCurrency, UUID styleId) {
            this.accountId = accountId;
            this.currencyId = currencyId;
            this.baseCurrency = baseCurrency;
            this.styleId = styleId;
        }

        public UUID accountId() { return accountId; }
        public UUID currencyId() { return currencyId; }
        public boolean baseCurrency() { return baseCurrency; }
        /** 账户绑定的总账科目(account_style_id), 未绑定为空。 */
        public UUID styleId() { return styleId; }
    }

    /** 过账结果: 流水主键、账户实际变动金额(账户币种)与账户币种。 */
    public record PostedFlow(UUID flowId, BigDecimal accountAmount, UUID accountCurrencyId) {
    }

    /** 锁住一个启用账户(账户与币种都须启用、未删除)。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public LockedAccount lockActive(UUID accountId, String label) {
        if (accountId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, labelOf(label) + "不能为空");
        }
        return lockActive(List.of(accountId), label).get(accountId);
    }

    /** 按账户主键顺序一次锁住多个启用账户, 避免交叉加锁死锁。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public Map<UUID, LockedAccount> lockActive(Collection<UUID> accountIds, String label) {
        if (accountIds == null || accountIds.isEmpty() || accountIds.stream().anyMatch(Objects::isNull)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, labelOf(label) + "不能为空");
        }
        Set<UUID> ids = new TreeSet<>(accountIds);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT account.id, account.currency_id, currency.is_base_currency,
                       account_style_id(account.id)
                FROM accounts account
                JOIN currencies currency ON currency.id = account.currency_id
                WHERE account.id IN (:ids)
                  AND account.status = '使用'
                  AND COALESCE(account.is_deleted, FALSE) = FALSE
                  AND currency.status = '使用'
                  AND COALESCE(currency.is_deleted, FALSE) = FALSE
                ORDER BY account.id
                FOR UPDATE OF account
                """).setParameter("ids", ids));
        if (rows.size() != ids.size()) {
            throw new ApiException(ErrorCode.BUSINESS, labelOf(label) + "不存在、已停用或币种已停用");
        }
        Map<UUID, LockedAccount> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[0], new LockedAccount(
                    (UUID) row[0], (UUID) row[1], Boolean.TRUE.equals(row[2]), (UUID) row[3]));
        }
        return result;
    }

    /** 锁账户并过账。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public PostedFlow post(AccountPosting posting) {
        return post(lockActive(posting.accountId, posting.accountLabel), posting);
    }

    /** 对已锁账户过账: 按币种规则取账户金额, 改余额与累计列, 写一条正向流水(或余额校准流水)。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public PostedFlow post(LockedAccount account, AccountPosting posting) {
        if (account == null || !account.accountId().equals(posting.accountId)) {
            throw new ApiException(ErrorCode.CONFLICT, "过账账户与已锁账户不一致");
        }
        String sourceType = normalizeSourceType(posting.sourceDocType);
        if (posting.sourceDocId == null || posting.bookedAt == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户过账缺少来源单据或入账时间");
        }
        String label = labelOf(posting.accountLabel);
        // 金额原样入账(只补齐 4 位显示位数, 数值不变), 不在账本里舍入。
        BigDecimal accountAmount = MoneyPolicy.canonical(accountAmount(account, posting, label));
        boolean adjustment = posting.direction == AccountPosting.Direction.ADJUSTMENT;
        BigDecimal local = MoneyPolicy.canonical(posting.localAmount);
        if (adjustment) {
            if (accountAmount.signum() == 0) {
                throw new ApiException(ErrorCode.CONFLICT, label + "校准差额为 0, 不需要写流水");
            }
            local = local == null ? null : local.abs();
        } else {
            if (accountAmount.signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT, label + "过账金额必须大于 0");
            }
            // 本位币账户的原生金额就是本币(与 fn_guard_account_flow_insert 同口径)。
            if (account.baseCurrency()) local = accountAmount;
        }
        String totalColumn = switch (posting.direction) {
            case IN -> "receipts_total";
            case OUT -> "payments_total";
            case ADJUSTMENT -> "balance_adjustments_total";
        };
        BigDecimal balanceDelta = posting.direction == AccountPosting.Direction.OUT
                ? accountAmount.negate() : accountAmount;
        int updated = em.createNativeQuery("""
                UPDATE accounts
                SET balance_current = COALESCE(balance_current, 0) + :balanceDelta,
                    %1$s = COALESCE(%1$s, 0) + :totalDelta,
                    updated_at = now(),
                    updated_by = COALESCE(CAST(:actor AS uuid), updated_by)
                WHERE id = :id
                """.formatted(totalColumn))
                .setParameter("balanceDelta", balanceDelta)
                .setParameter("totalDelta", accountAmount)
                .setParameter("actor", posting.actorUserId)
                .setParameter("id", account.accountId())
                .executeUpdate();
        if (updated != 1) {
            throw new ApiException(ErrorCode.CONFLICT, label + "余额更新失败");
        }
        UUID flowId = posting.flowId == null ? UUID.randomUUID() : posting.flowId;
        boolean outgoing = posting.direction == AccountPosting.Direction.OUT || accountAmount.signum() < 0;
        BigDecimal magnitude = accountAmount.abs();
        em.createNativeQuery("""
                INSERT INTO finance_reconciliations(
                    id, bill_no, source_doc_type, source_doc_id, account_id, account_currency_id,
                    check_no, counterpart_name, in_amount, out_amount, amount_local,
                    bill_date, settled_date, source_remark, remark, legacy_bstyle, entry_kind,
                    created_at, updated_at, created_by, updated_by, is_deleted)
                VALUES(
                    :id, :billNo, :sourceType, :sourceId, :accountId, :currencyId,
                    :checkNo, :counterpart, :inAmount, :outAmount, :amountLocal,
                    :bookedAt, :settledAt, :sourceRemark, :remark, :legacyBstyle, :entryKind,
                    now(), now(), :actor, :actor, FALSE)
                """)
                .setParameter("id", flowId)
                .setParameter("billNo", posting.billNo)
                .setParameter("sourceType", sourceType)
                .setParameter("sourceId", posting.sourceDocId)
                .setParameter("accountId", account.accountId())
                .setParameter("currencyId", account.currencyId())
                .setParameter("checkNo", posting.checkNo)
                .setParameter("counterpart", posting.counterpartName)
                .setParameter("inAmount", outgoing ? BigDecimal.ZERO : magnitude)
                .setParameter("outAmount", outgoing ? magnitude : BigDecimal.ZERO)
                .setParameter("amountLocal", local)
                .setParameter("bookedAt", posting.bookedAt)
                .setParameter("settledAt", posting.settledAt)
                .setParameter("sourceRemark", posting.sourceRemark)
                .setParameter("remark", posting.remark)
                .setParameter("legacyBstyle", posting.legacyBstyle)
                .setParameter("entryKind", adjustment ? "ADJUSTMENT" : POSTING)
                .setParameter("actor", posting.actorUserId)
                .executeUpdate();
        return new PostedFlow(flowId, accountAmount, account.currencyId());
    }

    /** 币种规则只写这一次: 账户记单据的哪一个金额。 */
    private static BigDecimal accountAmount(LockedAccount account, AccountPosting posting, String label) {
        BigDecimal amount = switch (posting.currencyRule) {
            case BASE_ONLY -> {
                if (!account.baseCurrency()
                        || (posting.documentCurrencyId != null
                            && !posting.documentCurrencyId.equals(account.currencyId()))) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            label + "必须是启用的本位币账户：单头币种必须等于真实账户币种，汇率必须为 1");
                }
                yield posting.localAmount;
            }
            case BASE_OR_DOCUMENT_CURRENCY -> {
                if (account.baseCurrency()) yield posting.localAmount;
                if (account.currencyId().equals(posting.documentCurrencyId)) yield posting.originalAmount;
                throw new ApiException(ErrorCode.BUSINESS,
                        label + "必须是本位币账户或与单据原币相同的账户，不能直接使用第三币种账户");
            }
            case ACCOUNT_CURRENCY -> {
                if (!account.currencyId().equals(posting.documentCurrencyId)) {
                    throw new ApiException(ErrorCode.CONFLICT, label + "或其币种已变化，禁止继续过账");
                }
                yield posting.originalAmount;
            }
            case ANY -> posting.originalAmount;
        };
        if (amount == null) {
            throw new ApiException(ErrorCode.CONFLICT, label + "过账金额缺失");
        }
        return amount;
    }

    private static String labelOf(String label) {
        return label == null || label.isBlank() ? "资金账户" : label;
    }

    /**
     * 按来源把每条有效正向流水镜像成一条反向流水, 并同步恢复账户余额与累计列; 原始流水不动。
     * 来源级 advisory lock 让重试先看到第一次已提交的红冲, 不会重复冲回。
     *
     * @return number of reversal rows appended
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public int reverse(
            String sourceType,
            UUID sourceId,
            OffsetDateTime reversalAt,
            String reason) {
        String normalizedType = normalizeSourceType(sourceType);
        String normalizedReason = normalizeReason(reason);
        if (sourceId == null || reversalAt == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "账户流水红冲缺少来源 UUID 或红冲时间");
        }

        em.createNativeQuery(
                        "SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "uten:account-flow-reversal:"
                        + normalizedType + ":" + sourceId)
                .getSingleResult();

        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT reconciliation.id,
                       reconciliation.bill_no,
                       reconciliation.account_id,
                       reconciliation.check_no,
                       reconciliation.counterpart_name,
                       reconciliation.in_amount,
                       reconciliation.out_amount,
                       reconciliation.source_remark,
                       reconciliation.remark,
                       reconciliation.legacy_bstyle,
                       reconciliation.account_currency_id,
                       reconciliation.amount_local,
                       reconciliation.entry_kind,
                       reconciliation.reversal_of_id
                FROM finance_reconciliations reconciliation
                WHERE reconciliation.source_doc_type=:sourceType
                  AND reconciliation.source_doc_id=:sourceId
                  AND COALESCE(reconciliation.is_deleted,FALSE)=FALSE
                  AND reconciliation.entry_kind IN ('POSTING','REVERSAL')
                ORDER BY reconciliation.account_id NULLS LAST,
                         reconciliation.id
                FOR UPDATE
                """)
                .setParameter("sourceType", normalizedType)
                .setParameter("sourceId", sourceId));

        List<Posting> postings = rows.stream()
                .filter(row -> POSTING.equals(text(row[12])))
                .map(this::posting)
                .toList();
        long reversalCount = rows.stream()
                .filter(row -> REVERSAL.equals(text(row[12])))
                .count();
        if (postings.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "账户流水原始入账缺失，禁止红冲：" + normalizedType + "/" + sourceId);
        }
        if (reversalCount != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "账户流水已经存在反向分录，禁止重复红冲："
                            + normalizedType + "/" + sourceId);
        }

        Set<UUID> accountIds = new HashSet<>();
        for (Posting posting : postings) {
            if (posting.accountId() == null || !accountIds.add(posting.accountId())) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "账户流水原始入账账户缺失或重复，禁止自动红冲："
                                + normalizedType + "/" + sourceId);
            }
            requireOneSided(posting);
        }

        // 余额按原始流水逐笔反向: 收入流水冲回 receipts_total, 支出流水冲回 payments_total。
        // 账户须仍启用(与正向过账、流水插入守卫同一口径)。
        for (Posting posting : postings.stream()
                .sorted(Comparator.comparing(Posting::accountId)).toList()) {
            boolean incoming = posting.inAmount().signum() > 0;
            String totalColumn = incoming ? "receipts_total" : "payments_total";
            int restored = em.createNativeQuery("""
                    UPDATE accounts
                    SET balance_current = COALESCE(balance_current, 0) + :balanceDelta,
                        %1$s = COALESCE(%1$s, 0) - :amount,
                        updated_at = now()
                    WHERE id = :id
                      AND status = '使用'
                      AND COALESCE(is_deleted, FALSE) = FALSE
                    """.formatted(totalColumn))
                    .setParameter("balanceDelta", incoming ? posting.inAmount().negate() : posting.outAmount())
                    .setParameter("amount", incoming ? posting.inAmount() : posting.outAmount())
                    .setParameter("id", posting.accountId())
                    .executeUpdate();
            if (restored != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "红冲涉及的资金账户不存在或已停用，请先启用账户后再红冲");
            }
        }

        int appended = 0;
        for (Posting posting : postings) {
            int inserted = em.createNativeQuery("""
                    INSERT INTO finance_reconciliations(
                        bill_no,source_doc_type,source_doc_id,account_id,
                        check_no,counterpart_name,in_amount,out_amount,
                        bill_date,settled_date,source_remark,remark,legacy_bstyle,
                        account_currency_id,amount_local,
                        entry_kind,reversal_of_id,reversal_reason,
                        created_at,updated_at,is_deleted)
                    VALUES(
                        :billNo,:sourceType,:sourceId,:accountId,
                        :checkNo,:counterpartName,:inAmount,:outAmount,
                        :reversalAt,:reversalAt,:sourceRemark,:remark,:legacyBstyle,
                        :accountCurrencyId,:amountLocal,
                        'REVERSAL',:reversalOfId,:reversalReason,
                        now(),now(),FALSE)
                    """)
                    .setParameter("billNo", posting.billNo())
                    .setParameter("sourceType", normalizedType)
                    .setParameter("sourceId", sourceId)
                    .setParameter("accountId", posting.accountId())
                    .setParameter("checkNo", posting.checkNo())
                    .setParameter("counterpartName", posting.counterpartName())
                    .setParameter("inAmount", posting.outAmount())
                    .setParameter("outAmount", posting.inAmount())
                    .setParameter("reversalAt", reversalAt)
                    .setParameter("sourceRemark", posting.sourceRemark())
                    .setParameter("remark", normalizedReason)
                    .setParameter("legacyBstyle", posting.legacyBstyle())
                    .setParameter("accountCurrencyId", posting.accountCurrencyId())
                    .setParameter("amountLocal", posting.amountLocal())
                    .setParameter("reversalOfId", posting.id())
                    .setParameter("reversalReason", normalizedReason)
                    .executeUpdate();
            if (inserted != 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "账户流水反向分录写入失败：" + posting.id());
            }
            appended += inserted;
        }
        return appended;
    }

    private Posting posting(Object[] row) {
        return new Posting(
                (UUID) row[0],
                text(row[1]),
                (UUID) row[2],
                text(row[3]),
                text(row[4]),
                decimal(row[5]),
                decimal(row[6]),
                text(row[7]),
                row[9] == null ? null : ((Number) row[9]).intValue(),
                (UUID) row[10],
                nullableDecimal(row[11]));
    }

    private static void requireOneSided(Posting posting) {
        boolean incoming = posting.inAmount().signum() > 0
                && posting.outAmount().signum() == 0;
        boolean outgoing = posting.outAmount().signum() > 0
                && posting.inAmount().signum() == 0;
        if (!incoming && !outgoing) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "账户流水必须且只能有一个正向金额，禁止自动红冲：" + posting.id());
        }
    }

    private static String normalizeSourceType(String sourceType) {
        if (sourceType == null || sourceType.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水红冲来源类型不能为空");
        }
        String normalized = sourceType.trim();
        if (normalized.length() > 64) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水红冲来源类型过长");
        }
        return normalized;
    }

    private static String normalizeReason(String reason) {
        if (reason == null || reason.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水红冲原因不能为空");
        }
        String normalized = reason.trim();
        if (normalized.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户流水红冲原因不能超过 500 个字符");
        }
        return normalized;
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        return value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static BigDecimal nullableDecimal(Object value) {
        return value == null ? null : decimal(value);
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private record Posting(
            UUID id,
            String billNo,
            UUID accountId,
            String checkNo,
            String counterpartName,
            BigDecimal inAmount,
            BigDecimal outAmount,
            String sourceRemark,
            Integer legacyBstyle,
            UUID accountCurrencyId,
            BigDecimal amountLocal) {
    }
}
