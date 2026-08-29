package com.uten.imp.features.finance.accountbalance;

import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentBatchRequest;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentBatchResult;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentItemRequest;
import com.uten.imp.features.finance.accountbalance.dto.AccountBalanceAdjustmentItemResult;
import com.uten.imp.features.finance.gl.GlPostingService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Posts an atomic, idempotent account-balance verification batch.
 *
 * <p>The UI enters target balances, but the server writes an immutable command,
 * a signed delta in the account currency, separately governed functional-currency
 * GL evidence, one effective bank-register row per non-zero item, and the two
 * denormalized account totals in one transaction. It never rewrites opening
 * balance or old flows, and never converts an account balance with a mutable
 * currency-master reference rate.
 */
@Service
@RequiredArgsConstructor
public class AccountBalanceAdjustmentService {

    private static final String SCOPE_FULL = "FULL";
    private static final String SCOPE_SELECTED = "SELECTED";
    private static final String RECON_SOURCE = "BALANCE_ADJUSTMENT";
    private static final String CLEARING_ROLE = "ACCOUNT_BALANCE_CLEARING";
    private static final String BASIS_BASE_CURRENCY = "BASE_CURRENCY_IDENTITY";
    private static final String BASIS_FINANCE_EXPLICIT = "FINANCE_EXPLICIT_LOCAL";
    private static final String BASIS_NO_CHANGE = "NO_CHANGE";

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final DocNumberService docNumberService;
    private final GlPostingService glPostingService;

    @Transactional
    @PreAuthorize("hasAuthority('account:view') and hasAuthority('account:balance:view') "
            + "and hasAuthority('account:balance:adjust')")
    public AccountBalanceAdjustmentBatchResult adjust(
            AccountBalanceAdjustmentBatchRequest request) {
        tx.bind();
        NormalizedRequest normalized = normalize(request);

        lockIdempotencyKey(normalized.idempotencyKey());
        ExistingCommand existing = findExisting(normalized.idempotencyKey());
        if (existing != null) {
            return replay(existing, normalized.requestHash(), normalized.legacyRequestHash());
        }
        requireCurrentEffectiveDate(normalized.effectiveDate());

        // Global lock order: category hierarchy -> GL AUTO period -> account population -> account UUIDs.
        PaymentStyleHierarchyLock.lock(em);
        glPostingService.lockAutoProjectionPeriod(normalized.effectiveDate());
        lockAccountPopulation();

        UUID clearingStyleId = requireClearingStyle();
        List<UUID> requestedIds = normalized.items().stream()
                .map(NormalizedItem::accountId)
                .toList();
        Set<UUID> activeBefore = activeAccountIds();
        requireScopeCoverage(normalized.scope(), requestedIds, activeBefore);

        List<AccountSnapshot> accounts = lockAccounts(requestedIds);
        if (accounts.size() != requestedIds.size()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "部分账户不存在、已删除或已停用，请刷新账户列表后重新核对");
        }
        if (SCOPE_FULL.equals(normalized.scope())
                && !activeBefore.equals(activeAccountIds())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "活动账户集合在核对期间发生变化，请刷新后重新提交全量核对");
        }

        Map<UUID, NormalizedItem> requestedById = new LinkedHashMap<>();
        for (NormalizedItem item : normalized.items()) requestedById.put(item.accountId(), item);
        for (AccountSnapshot account : accounts) {
            NormalizedItem item = requestedById.get(account.id());
            if (account.balance().compareTo(item.expectedBalance()) != 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "账户余额已变化：" + account.code() + " " + account.name()
                                + "，页面显示 " + plain(item.expectedBalance())
                                + "，当前实际 " + plain(account.balance())
                                + "。请刷新后重新确认整批数据");
            }
        }
        requireFlowIntegrity(accounts);

        UUID actorEmployeeId = currentUser.requireEmployeeId();
        UUID auditUserId = currentUser.requireId();
        UUID batchId = UUID.randomUUID();
        int expectedItemCount = normalized.items().size();
        int changedItemCount = (int) normalized.items().stream()
                .filter(item -> item.targetBalance().compareTo(item.expectedBalance()) != 0)
                .count();
        String batchNo = docNumberService.nextNumber(
                DocNumberPrefix.FIN_ACCOUNT_BALANCE_ADJUSTMENT);
        em.createNativeQuery("""
                        INSERT INTO account_balance_adjustment_batches(
                            id,batch_no,adjustment_scope,effective_date,reason,
                            idempotency_key,request_hash,clearing_style_id,actor_id,
                            expected_item_count,changed_item_count,created_at,created_by)
                        VALUES(
                            :id,:batchNo,:scope,:effectiveDate,:reason,
                            :requestKey,:requestHash,:clearingStyle,:actor,
                            :expectedCount,:changedCount,now(),:createdBy)
                        """)
                .setParameter("id", batchId)
                .setParameter("batchNo", batchNo)
                .setParameter("scope", normalized.scope())
                .setParameter("effectiveDate", normalized.effectiveDate())
                .setParameter("reason", normalized.reason())
                .setParameter("requestKey", normalized.idempotencyKey())
                .setParameter("requestHash", normalized.requestHash())
                .setParameter("clearingStyle", clearingStyleId)
                .setParameter("actor", actorEmployeeId)
                .setParameter("expectedCount", expectedItemCount)
                .setParameter("changedCount", changedItemCount)
                .setParameter("createdBy", auditUserId)
                .executeUpdate();

        Map<UUID, AccountSnapshot> accountById = new LinkedHashMap<>();
        for (AccountSnapshot account : accounts) accountById.put(account.id(), account);
        int lineNo = 0;
        for (NormalizedItem requested : normalized.items()) {
            lineNo++;
            AccountSnapshot account = accountById.get(requested.accountId());
            BigDecimal delta = exactMoney(
                    requested.targetBalance().subtract(requested.expectedBalance()));
            LocalAmountEvidence localEvidence = resolveLocalAmountEvidence(
                    account.baseCurrency(), account.code(), delta, requested.localDelta());
            BigDecimal deltaLocal = localEvidence.localDelta();
            UUID itemId = UUID.randomUUID();
            em.createNativeQuery("""
                            INSERT INTO account_balance_adjustment_items(
                                id,batch_id,line_no,account_id,
                                account_code_snapshot,account_name_snapshot,
                                currency_id,currency_code_snapshot,currency_name_snapshot,
                                exchange_rate_snapshot,local_amount_basis,account_style_id_snapshot,
                                expected_balance,target_balance,delta_balance,delta_local,
                                verified,created_at,created_by)
                            VALUES(
                                :id,:batch,:line,:account,
                                :accountCode,:accountName,
                                :currency,:currencyCode,:currencyName,
                                :rate,:localAmountBasis,:accountStyle,
                                :expected,:target,:delta,:deltaLocal,
                                TRUE,now(),:actor)
                            """)
                    .setParameter("id", itemId)
                    .setParameter("batch", batchId)
                    .setParameter("line", lineNo)
                    .setParameter("account", account.id())
                    .setParameter("accountCode", account.code())
                    .setParameter("accountName", account.name())
                    .setParameter("currency", account.currencyId())
                    .setParameter("currencyCode", account.currencyCode())
                    .setParameter("currencyName", account.currencyName())
                    .setParameter("rate", localEvidence.exchangeRateSnapshot())
                    .setParameter("localAmountBasis", localEvidence.basis())
                    .setParameter("accountStyle", account.styleId())
                    .setParameter("expected", requested.expectedBalance())
                    .setParameter("target", requested.targetBalance())
                    .setParameter("delta", delta)
                    .setParameter("deltaLocal", deltaLocal)
                    .setParameter("actor", auditUserId)
                    .executeUpdate();

            if (delta.signum() == 0) continue;
            int updated = em.createNativeQuery("""
                            UPDATE accounts
                            SET balance_adjustments_total=balance_adjustments_total+:delta,
                                balance_current=balance_current+:delta,
                                updated_at=now(),updated_by=:actor
                            WHERE id=:account
                            """)
                    .setParameter("delta", delta)
                    .setParameter("actor", auditUserId)
                    .setParameter("account", account.id())
                    .executeUpdate();
            if (updated != 1) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "账户余额更新失败：" + account.code());
            }
            em.createNativeQuery("""
                            INSERT INTO finance_reconciliations(
                                bill_no,source_doc_type,source_doc_id,account_id,
                                in_amount,out_amount,amount_local,entry_kind,bill_date,settled_date,
                                source_remark,remark,created_at,updated_at,created_by,updated_by,is_deleted)
                            VALUES(
                                :batchNo,:source,:batch,:account,
                                :inAmount,:outAmount,:amountLocal,'ADJUSTMENT',:billDate,NULL,
                                '账户余额校准',:reason,now(),now(),:actor,:actor,FALSE)
                            """)
                    .setParameter("batchNo", batchNo)
                    .setParameter("source", RECON_SOURCE)
                    .setParameter("batch", batchId)
                    .setParameter("account", account.id())
                    .setParameter("inAmount", delta.signum() > 0 ? delta : BigDecimal.ZERO)
                    .setParameter("outAmount", delta.signum() < 0 ? delta.abs() : BigDecimal.ZERO)
                    .setParameter("amountLocal", deltaLocal.abs())
                    .setParameter("billDate", BusinessTime.startOfDay(normalized.effectiveDate()))
                    .setParameter("reason", normalized.reason())
                    .setParameter("actor", auditUserId)
                    .executeUpdate();
        }
        return loadResult(batchId);
    }

    /**
     * A target-balance adjustment changes both the cache and the account flow by
     * the same delta, so it cannot repair a pre-existing cache/flow drift. Fail
     * closed until that historical difference has an independently approved
     * opening/repair fact.
     */
    private void requireFlowIntegrity(List<AccountSnapshot> accounts) {
        List<UUID> ids=accounts.stream().map(AccountSnapshot::id).toList();
        List<Object[]> rows=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT account_id,balance_difference
                        FROM v_account_balance_integrity
                        WHERE account_id IN (:ids)
                        ORDER BY account_id
                        """)
                .setParameter("ids",ids));
        if(rows.size()!=ids.size()){
            throw new ApiException(ErrorCode.CONFLICT,
                    "部分账户缺少流水重建余额，禁止用余额校准掩盖历史缺口");
        }
        Map<UUID,AccountSnapshot> byId=new LinkedHashMap<>();
        for(AccountSnapshot account:accounts)byId.put(account.id(),account);
        for(Object[] row:rows){
            UUID id=(UUID)row[0];
            BigDecimal difference=NativeValueConverters.toBigDecimal(row[1]);
            if(difference!=null&&difference.signum()!=0){
                AccountSnapshot account=byId.get(id);
                throw new ApiException(ErrorCode.CONFLICT,
                        "账户快照与流水重建余额不一致："
                                +(account==null?id:account.code()+" "+account.name())
                                +"，差异 "+plain(difference)
                                +"。请先完成历史流水/开账来源对账，不能直接改余额");
            }
        }
    }

    private static NormalizedRequest normalize(AccountBalanceAdjustmentBatchRequest request) {
        if (request == null || request.scope() == null || request.effectiveDate() == null
                || request.reason() == null || request.idempotencyKey() == null
                || request.items() == null || request.items().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "账户余额核对参数不完整");
        }
        String scope = request.scope().trim().toUpperCase();
        if (!Set.of(SCOPE_FULL, SCOPE_SELECTED).contains(scope)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "核对范围只能是 FULL 或 SELECTED");
        }
        String reason = request.reason().trim();
        if (reason.isEmpty() || reason.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "余额核对原因不能为空且不能超过 500 个字符");
        }
        String key = request.idempotencyKey().trim();
        if (key.length() < 8 || key.length() > 128
                || !key.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "余额核对幂等键格式不正确");
        }
        if (request.items().size() > 2000) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "单个余额核对批次最多 2000 个账户；请在维护窗口分批使用 SELECTED 并保留分批签字记录");
        }
        List<NormalizedItem> items = new ArrayList<>(request.items().size());
        Set<UUID> ids = new LinkedHashSet<>();
        for (AccountBalanceAdjustmentItemRequest item : request.items()) {
            if (item == null || item.accountId() == null
                    || item.expectedBalance() == null || item.targetBalance() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "余额核对明细参数不完整");
            }
            if (!ids.add(item.accountId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "同一账户不能在一个余额核对批次中重复出现");
            }
            BigDecimal localDelta = item.localDelta() == null
                    ? null : exactMoney(item.localDelta());
            items.add(new NormalizedItem(
                    item.accountId(), exactMoney(item.expectedBalance()),
                    exactMoney(item.targetBalance()), localDelta));
        }
        items.sort(Comparator.comparing(NormalizedItem::accountId));
        String hash = requestHash(scope, request.effectiveDate(), reason, items, true);
        String legacyHash = items.stream().allMatch(item -> item.localDelta() == null)
                ? requestHash(scope, request.effectiveDate(), reason, items, false)
                : null;
        return new NormalizedRequest(
                scope, request.effectiveDate(), reason, key, hash, legacyHash,
                List.copyOf(items));
    }

    private static void requireCurrentEffectiveDate(LocalDate effectiveDate) {
        if (!BusinessTime.today().equals(effectiveDate)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "账户余额核对生效日必须是上海业务今日，不能回填或预填历史日期");
        }
    }

    private void lockIdempotencyKey(String key) {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "uten:account-balance-adjustment:" + key)
                .getSingleResult();
    }

    private void lockAccountPopulation() {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "ACCOUNT_MASTER_POPULATION")
                .getSingleResult();
    }

    private ExistingCommand findExisting(String key) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT id,request_hash
                        FROM account_balance_adjustment_batches
                        WHERE idempotency_key=:key
                        """)
                .setParameter("key", key));
        if (rows.isEmpty()) return null;
        return new ExistingCommand((UUID) rows.getFirst()[0], rows.getFirst()[1].toString());
    }

    private AccountBalanceAdjustmentBatchResult replay(
            ExistingCommand existing, String requestHash, String legacyRequestHash) {
        boolean currentMatch = existing.requestHash().equals(requestHash);
        boolean legacyMatch = legacyRequestHash != null
                && existing.requestHash().equals(legacyRequestHash);
        if (!currentMatch && !legacyMatch) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该幂等键已用于另一笔账户余额核对，请使用新的幂等键");
        }
        return loadResult(existing.id());
    }

    private UUID requireClearingStyle() {
        List<?> rows = em.createNativeQuery("""
                        SELECT style.id
                        FROM system_posting_style_roles role
                        JOIN payment_styles style ON style.id=role.style_id
                        WHERE role.role_key=:role
                          AND role.required_category='EQUITY'
                          AND style.category='EQUITY'
                          AND style.status='使用'
                          AND COALESCE(style.is_deleted,FALSE)=FALSE
                          AND NOT EXISTS(
                              SELECT 1 FROM payment_styles child
                              WHERE child.parent_id=style.id
                                AND COALESCE(child.is_deleted,FALSE)=FALSE)
                        """)
                .setParameter("role", CLEARING_ROLE)
                .getResultList();
        if (rows.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "账户余额调整清算科目未配置为可用的权益类叶节点");
        }
        return (UUID) rows.getFirst();
    }

    private Set<UUID> activeAccountIds() {
        @SuppressWarnings("unchecked")
        List<UUID> ids = em.createNativeQuery("""
                        SELECT id FROM accounts
                        WHERE COALESCE(is_deleted,FALSE)=FALSE AND status='使用'
                        ORDER BY id
                        """)
                .getResultList();
        return new LinkedHashSet<>(ids);
    }

    private void requireScopeCoverage(
            String scope, List<UUID> requestedIds, Set<UUID> activeIds) {
        Set<UUID> requested = new LinkedHashSet<>(requestedIds);
        if (!activeIds.containsAll(requested)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "核对明细包含不存在、已删除或已停用的账户");
        }
        if (SCOPE_FULL.equals(scope) && !requested.equals(activeIds)) {
            Set<UUID> missing = new LinkedHashSet<>(activeIds);
            missing.removeAll(requested);
            throw new ApiException(ErrorCode.CONFLICT,
                    "FULL 核对必须覆盖全部活动账户，当前缺少 " + missing.size() + " 个账户");
        }
    }

    private List<AccountSnapshot> lockAccounts(List<UUID> accountIds) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT account.id,account.code,account.name,account.currency_id,
                               currency.code,currency.name,currency.is_base_currency,
                               currency.status,COALESCE(currency.is_deleted,FALSE),
                               account.balance_current,account.style_id,
                               style.category,style.status,COALESCE(style.is_deleted,FALSE),
                               EXISTS(
                                   SELECT 1 FROM payment_styles child
                                   WHERE child.parent_id=style.id
                                     AND COALESCE(child.is_deleted,FALSE)=FALSE)
                        FROM accounts account
                        LEFT JOIN currencies currency ON currency.id=account.currency_id
                        LEFT JOIN payment_styles style ON style.id=account.style_id
                        WHERE account.id IN (:ids)
                          AND COALESCE(account.is_deleted,FALSE)=FALSE
                          AND account.status='使用'
                        ORDER BY account.id
                        FOR UPDATE OF account
                        """)
                .setParameter("ids", accountIds));
        List<AccountSnapshot> result = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            UUID currencyId = (UUID) row[3];
            String currencyCode = row[4] == null ? null : row[4].toString().trim();
            String currencyName = row[5] == null ? null : row[5].toString().trim();
            if (currencyId == null) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "活动账户未设置币种，禁止猜测为人民币：" + row[1]);
            }
            if (currencyCode == null || currencyCode.isBlank()
                    || currencyName == null || currencyName.isBlank()
                    || !"使用".equals(row[7]) || Boolean.TRUE.equals(row[8])) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "账户币种不存在、已停用或资料不完整：" + row[1]);
            }
            boolean baseCurrency = Boolean.TRUE.equals(row[6]);
            UUID styleId = (UUID) row[10];
            if (styleId == null
                    || !"ACCOUNT".equals(row[11])
                    || !"使用".equals(row[12])
                    || Boolean.TRUE.equals(row[13])
                    || Boolean.TRUE.equals(row[14])) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "活动账户未绑定可用的账户类叶子科目 UUID：" + row[1]);
            }
            String accountCode = row[1] == null ? "" : row[1].toString().trim();
            if (accountCode.isEmpty()) {
                throw new ApiException(ErrorCode.CONFLICT, "活动账户缺少编号，不能核对余额");
            }
            result.add(new AccountSnapshot(
                    (UUID) row[0], accountCode, row[2].toString(), currencyId,
                    currencyCode, currencyName,
                    baseCurrency,
                    exactMoney(NativeValueConverters.toBigDecimal(row[9])), styleId));
        }
        return result;
    }

    private AccountBalanceAdjustmentBatchResult loadResult(UUID batchId) {
        List<Object[]> headers = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT id,batch_no,adjustment_scope,effective_date,reason,
                               expected_item_count,changed_item_count,actor_id,created_at
                        FROM account_balance_adjustment_batches WHERE id=:id
                        """)
                .setParameter("id", batchId));
        if (headers.size() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "账户余额核对批次不存在或不完整");
        }
        Object[] header = headers.getFirst();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT id,account_id,account_code_snapshot,account_name_snapshot,
                               currency_id,currency_code_snapshot,currency_name_snapshot,
                               exchange_rate_snapshot,local_amount_basis,
                               expected_balance,target_balance,delta_balance,delta_local,verified
                        FROM account_balance_adjustment_items
                        WHERE batch_id=:batch ORDER BY line_no
                        """)
                .setParameter("batch", batchId));
        List<AccountBalanceAdjustmentItemResult> items = new ArrayList<>(rows.size());
        int changed = 0;
        BigDecimal increase = BigDecimal.ZERO.setScale(4);
        BigDecimal decrease = BigDecimal.ZERO.setScale(4);
        for (Object[] row : rows) {
            BigDecimal rate = row[7] == null
                    ? null : NativeValueConverters.toBigDecimal(row[7]);
            BigDecimal expected = NativeValueConverters.toBigDecimal(row[9]);
            BigDecimal target = NativeValueConverters.toBigDecimal(row[10]);
            BigDecimal delta = NativeValueConverters.toBigDecimal(row[11]);
            BigDecimal deltaLocal = NativeValueConverters.toBigDecimal(row[12]);
            if (delta.signum() != 0) changed++;
            if (deltaLocal.signum() > 0) increase = increase.add(deltaLocal);
            if (deltaLocal.signum() < 0) decrease = decrease.add(deltaLocal.abs());
            items.add(new AccountBalanceAdjustmentItemResult(
                    (UUID) row[0], (UUID) row[1], String.valueOf(row[2]), String.valueOf(row[3]),
                    (UUID) row[4], String.valueOf(row[5]), String.valueOf(row[6]),
                    rate, expected, target, delta, deltaLocal, String.valueOf(row[8]),
                    rate == null ? null : plain(rate),
                    plain(expected), plain(target),
                    plain(delta), plain(deltaLocal),
                    Boolean.TRUE.equals(row[13])));
        }
        int expectedCount = ((Number) header[5]).intValue();
        int persistedChangedCount = ((Number) header[6]).intValue();
        if (items.size() != expectedCount || changed != persistedChangedCount) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "账户余额核对批次明细数量与不可变头记录不一致");
        }
        return new AccountBalanceAdjustmentBatchResult(
                (UUID) header[0], String.valueOf(header[1]), String.valueOf(header[2]),
                NativeValueConverters.toLocalDate(header[3]), String.valueOf(header[4]),
                items.size(), changed, increase, decrease, plain(increase), plain(decrease),
                (UUID) header[7],
                NativeValueConverters.toOffsetDateTime(header[8]), List.copyOf(items));
    }

    static BigDecimal exactMoney(BigDecimal value) {
        try {
            BigDecimal result = value.setScale(4, RoundingMode.UNNECESSARY);
            if (result.precision() - result.scale() > 14) throw new ArithmeticException();
            return result;
        } catch (ArithmeticException ex) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "账户余额最多允许 14 位整数和 4 位小数");
        }
    }

    static LocalAmountEvidence resolveLocalAmountEvidence(
            boolean baseCurrency,
            String accountCode,
            BigDecimal delta,
            BigDecimal suppliedLocalDelta) {
        if (delta.signum() == 0) {
            if (suppliedLocalDelta != null && suppliedLocalDelta.signum() != 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "账户余额未变化时，本位币调账额必须留空或为 0：" + accountCode);
            }
            return new LocalAmountEvidence(
                    BigDecimal.ZERO.setScale(4), null, BASIS_NO_CHANGE);
        }
        if (baseCurrency) {
            if (suppliedLocalDelta != null && suppliedLocalDelta.compareTo(delta) != 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "人民币账户的本位币调账额必须等于账户原币差额：" + accountCode);
            }
            return new LocalAmountEvidence(
                    delta, BigDecimal.ONE.setScale(6), BASIS_BASE_CURRENCY);
        }
        if (suppliedLocalDelta == null || suppliedLocalDelta.signum() == 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "外币账户余额发生变化时，财务必须单独填写同方向的本位币调账额："
                            + accountCode);
        }
        if (suppliedLocalDelta.signum() != delta.signum()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "外币账户的原币差额与本位币调账额方向必须一致：" + accountCode);
        }
        return new LocalAmountEvidence(
                suppliedLocalDelta, null, BASIS_FINANCE_EXPLICIT);
    }

    private static String requestHash(
            String scope, LocalDate effectiveDate, String reason,
            List<NormalizedItem> items, boolean includeLocalDelta) {
        StringBuilder canonical = new StringBuilder();
        appendCanonical(canonical, scope);
        appendCanonical(canonical, effectiveDate.toString());
        appendCanonical(canonical, reason);
        appendCanonical(canonical, Integer.toString(items.size()));
        for (NormalizedItem item : items) {
            appendCanonical(canonical, item.accountId().toString());
            appendCanonical(canonical, plain(item.expectedBalance()));
            appendCanonical(canonical, plain(item.targetBalance()));
            if (includeLocalDelta) {
                appendCanonical(canonical,
                        item.localDelta() == null ? "" : plain(item.localDelta()));
            }
        }
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(canonical.toString().getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException ex) {
            throw new IllegalStateException("SHA-256 unavailable", ex);
        }
    }

    private static void appendCanonical(StringBuilder target, String value) {
        target.append(value.length()).append('#').append(value);
    }

    static String requestFingerprint(AccountBalanceAdjustmentBatchRequest request) {
        return normalize(request).requestHash();
    }

    private static String plain(BigDecimal value) {
        return value.stripTrailingZeros().toPlainString();
    }

    private record NormalizedRequest(
            String scope,
            LocalDate effectiveDate,
            String reason,
            String idempotencyKey,
            String requestHash,
            String legacyRequestHash,
            List<NormalizedItem> items) {
    }

    private record NormalizedItem(
            UUID accountId,
            BigDecimal expectedBalance,
            BigDecimal targetBalance,
            BigDecimal localDelta) {
    }

    private record AccountSnapshot(
            UUID id,
            String code,
            String name,
            UUID currencyId,
            String currencyCode,
            String currencyName,
            boolean baseCurrency,
            BigDecimal balance,
            UUID styleId) {
    }

    record LocalAmountEvidence(
            BigDecimal localDelta,
            BigDecimal exchangeRateSnapshot,
            String basis) {
    }

    private record ExistingCommand(UUID id, String requestHash) {
    }
}
