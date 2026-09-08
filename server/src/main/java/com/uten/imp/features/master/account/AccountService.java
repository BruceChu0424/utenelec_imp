package com.uten.imp.features.master.account;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.master.account.dto.AccountDetail;
import com.uten.imp.features.master.account.dto.AccountCurrencySummary;
import com.uten.imp.features.master.account.dto.AccountFacets;
import com.uten.imp.features.master.account.dto.AccountListItem;
import com.uten.imp.features.master.account.dto.AccountQueryFilter;
import com.uten.imp.features.master.account.dto.AccountSaveRequest;
import com.uten.imp.features.master.account.dto.AccountSummary;
import com.uten.imp.features.master.account.dto.AccountWarningUpdateRequest;
import com.uten.imp.features.master.account.dto.FacetBucket;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 账户主档：扁平列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（account:edit）。
 *
 * <p>范式同 {@code CurrencyService}，加账户类型枚举与余额字段。
 * 收付款单据审核时由钱流 Service 维护 {@code receipts_total/payments_total/balance_current}，
 * 余额守恒 {@code balanceCurrent = initBalance + receiptsTotal − paymentsTotal
 * + balanceAdjustmentsTotal}。
 *
 * <p>{@link #inferAccountType} 是迁移「按 AccName 关键字 CASE WHEN 映射」的 Java 版本单一事实源，
 * 供迁移脚本参考与运行时新建账户缺省类型推断；老库 AStyle 全为 1 已丢弃。
 */
@Service
@RequiredArgsConstructor
public class AccountService {

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.ACCOUNT;

    /** 账户类型枚举值（对齐 CHECK 约束）。 */
    public static final String TYPE_BANK = "BANK";
    public static final String TYPE_CASH = "CASH";
    public static final String TYPE_CHECK = "CHECK";
    public static final String TYPE_FOREIGN_CHECK = "FOREIGN_CHECK";
    public static final String TYPE_THIRD_PARTY = "THIRD_PARTY";
    public static final String TYPE_OFFSHORE = "OFFSHORE";
    public static final String TYPE_GENERAL = "GENERAL";

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS =
            Set.of("code", "bankAccountNo", "currencyId", "parentLegacyId", "styleId");

    /** 列排序白名单：前端列 key → JPA 实体属性名（金额列；命中才排序，否则默认 code ASC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("balanceCurrent", "balanceCurrent");

    /** facet 截断阈值。 */
    private static final int FACET_LIMIT = 50;

    private final AccountRepository repo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final MasterCodeService masterCodeService;

    // ===== account_type 映射（迁移 CASE WHEN 的 Java 版本单一事实源） =====

    /**
     * 按 AccName 关键字推断账户类型（design doc 26 §3.1）。
     *
     * <p>规则：现金→CASH / 微信|支付宝→THIRD_PARTY / 香港→OFFSHORE /
     * 一般帐户→GENERAL / 银行关键字（农行/工行/建行/招商/交通/邮政/信用社/工商牡丹/兴业/中国/广发/基本户…）→BANK。
     * 老库"支票"两条（ID 50 禁用=本公司、ID 56 使用=外来）靠 Status+备注区分；
     * 本方法返回 FOREIGN_CHECK 作保守默认，迁移脚本可按 Status 人工修正为 CHECK。
     */
    public static String inferAccountType(String name) {
        if (name == null || name.isBlank()) {
            return TYPE_BANK;
        }
        String n = name.toLowerCase();
        if (n.contains("现金")) return TYPE_CASH;
        if (n.contains("微信") || n.contains("支付宝")) return TYPE_THIRD_PARTY;
        if (n.contains("香港")) return TYPE_OFFSHORE;
        if (n.contains("一般帐户") || n.contains("一般账户")) return TYPE_GENERAL;
        if (n.contains("支票")) return TYPE_FOREIGN_CHECK;
        // 其余（农行/工行/建行/招商/交通/邮政/信用社/工商牡丹/兴业/中国/广发/基本户…）一律银行
        return TYPE_BANK;
    }

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<AccountListItem> list(AccountQueryFilter f, int page, int size, String sort, String order) {
        if ("balanceCurrent".equals(sort) && !hasAuthority("account:balance:view")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少账户余额查看权限，不能按余额排序");
        }
        Specification<Account> spec = (Root<Account> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                       CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("name")), like),
                        cb.like(cb.lower(root.get("code")), like),
                        cb.like(cb.lower(root.get("bankAccountNo")), like)));
            }
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "accountType", f.accountType());
            addEq(ps, cb, root, "status", f.status());
            if (f.currencyId() != null) ps.add(cb.equal(root.get("currencyId"), f.currencyId()));
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.ASC, "code"), ALLOWED_SORT));
        Page<Account> p = repo.findAll(spec, pageable);
        Map<UUID, CurrencyMeta> currencyMeta = currencyMetaFor(p.getContent());
        return new PageResponse<>(
                p.getContent().stream()
                        .map(account -> toList(
                                account, currencyMetaOf(account.getCurrencyId(), currencyMeta)))
                        .toList(),
                p);
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Account> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    // ===== 加密 Excel 导出（服务端权威列定义） =====

    /**
     * 加密 Excel 导出：循环 list 分页累积全部行（size=100），硬上限 1000 页=10万行防 OOM。
     * 列定义服务端权威；过滤/排序走 list 已接的 TableSort 白名单（balanceCurrent）。
     * accountType 用枚举值（BANK/CASH/...），与 DB 列一致，便于二次处理；不解析为中文。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(AccountQueryFilter f, String sort, String order) {
        boolean showBalance = hasAuthority("account:balance:view");
        List<ExportColumn> cols = new ArrayList<>();
        cols.add(new ExportColumn("code", "编号", ExportColumn.TEXT));
        cols.add(new ExportColumn("name", "账户名称", ExportColumn.TEXT));
        cols.add(new ExportColumn("bankAccountNo", "银行账号", ExportColumn.TEXT));
        cols.add(new ExportColumn("accountType", "账户类型", ExportColumn.TEXT));
        if (showBalance) {
            cols.add(new ExportColumn("initBalance", "期初余额", ExportColumn.MONEY));
            cols.add(new ExportColumn("receiptsTotal", "累计收款", ExportColumn.MONEY));
            cols.add(new ExportColumn("paymentsTotal", "累计付款", ExportColumn.MONEY));
            cols.add(new ExportColumn("adjustmentsTotal", "余额调整累计", ExportColumn.MONEY));
            cols.add(new ExportColumn("balanceCurrent", "当前余额", ExportColumn.MONEY));
            cols.add(new ExportColumn("balanceFloor", "余额警戒线", ExportColumn.MONEY));
        }
        cols.add(new ExportColumn("status", "状态", ExportColumn.TEXT));
        List<Map<String, Object>> rows = new ArrayList<>();
        int pageSize = 100;
        int maxPages = 1000;
        long total = -1;
        for (int p = 1; p <= maxPages; p++) {
            PageResponse<AccountListItem> page = list(f, p, pageSize, sort, order);
            if (total < 0) total = page.getTotal();
            for (AccountListItem a : page.getItems()) {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("code", a.getCode());
                row.put("name", a.getName());
                row.put("bankAccountNo", a.getBankAccountNo());
                row.put("accountType", accountTypeLabel(a.getAccountType()));
                if (showBalance) {
                    row.put("initBalance", a.getInitBalance());
                    row.put("receiptsTotal", a.getReceiptsTotal());
                    row.put("paymentsTotal", a.getPaymentsTotal());
                    row.put("adjustmentsTotal", a.getAdjustmentsTotal());
                    row.put("balanceCurrent", a.getBalanceCurrent());
                    row.put("balanceFloor", a.getBalanceFloor());
                }
                row.put("status", a.getStatus());
                rows.add(row);
            }
            if (page.getItems().size() < pageSize) break;
            if (rows.size() >= total) break;
            if (p == maxPages && rows.size() < total) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "导出数据超过 10 万行上限，请收窄筛选条件后重试");
            }
        }
        return new ExportPayload(cols, rows, rows.size());
    }

    // ===== facets（各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public AccountFacets facets() {
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        buckets.put("accountType", new ArrayList<>());
        buckets.put("status", new ArrayList<>());
        buckets.put("currencyId", new ArrayList<>());
        nullCounts.put("accountType", 0L);
        nullCounts.put("status", 0L);
        nullCounts.put("currencyId", 0L);
        Map<String, String> currencyLabels = currencyLabels();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        WITH expanded(field_name, facet_value) AS (
                            SELECT facet.field_name, facet.facet_value
                            FROM accounts account
                            CROSS JOIN LATERAL (VALUES
                                ('accountType', account.account_type::TEXT),
                                ('status', account.status::TEXT),
                                ('currencyId', account.currency_id::TEXT)
                            ) AS facet(field_name, facet_value)
                            WHERE account.is_deleted=FALSE
                        ), grouped AS (
                            SELECT field_name, facet_value, COUNT(*) AS item_count
                            FROM expanded
                            GROUP BY field_name, facet_value
                        ), ranked AS (
                            SELECT field_name, facet_value, item_count,
                                   ROW_NUMBER() OVER (
                                       PARTITION BY field_name
                                       ORDER BY item_count DESC, facet_value ASC) AS bucket_rank
                            FROM grouped
                            WHERE facet_value IS NOT NULL
                        ), null_counts AS (
                            SELECT field_name, item_count
                            FROM grouped
                            WHERE facet_value IS NULL
                        )
                        SELECT field_name, facet_value, item_count, bucket_rank
                        FROM ranked
                        WHERE bucket_rank<=:facetLimit
                        UNION ALL
                        SELECT field_name, NULL, item_count, 2147483647::BIGINT
                        FROM null_counts
                        ORDER BY field_name, bucket_rank
                        """)
                .setParameter("facetLimit", FACET_LIMIT));
        for (Object[] row : rows) {
            String field = String.valueOf(row[0]);
            long count = ((Number) row[2]).longValue();
            if (row[1] == null) {
                nullCounts.put(field, count);
                continue;
            }
            String value = String.valueOf(row[1]);
            List<FacetBucket> fieldBuckets = buckets.get(field);
            if (fieldBuckets != null) {
                fieldBuckets.add(new FacetBucket(
                        value, count, facetLabel(field, value, currencyLabels)));
            }
        }
        return new AccountFacets(buckets.get("accountType"), buckets.get("status"),
                buckets.get("currencyId"), nullCounts);
    }

    @org.springframework.security.access.prepost.PreAuthorize(
            "hasAuthority('account:view') and hasAuthority('account:balance:view')")
    @Transactional(readOnly = true)
    public AccountSummary summary() {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT account.currency_id,
                       CASE WHEN account.currency_id IS NULL THEN '—'
                            ELSE COALESCE(NULLIF(currency.code,''),'—') END AS currency_code,
                       CASE WHEN account.currency_id IS NULL THEN '未设置币种'
                            ELSE COALESCE(NULLIF(currency.name,''),'未命名币种') END AS currency_name,
                       COUNT(*) AS account_count,
                       COUNT(*) FILTER (WHERE account.status='使用') AS active_count,
                       COALESCE(SUM(account.balance_current)
                           FILTER (WHERE account.status='使用'),0) AS balance_total,
                       COUNT(*) FILTER (
                           WHERE account.status='使用'
                             AND account.balance_floor IS NOT NULL
                             AND account.balance_current < account.balance_floor) AS warning_count,
                       COUNT(*) FILTER (
                           WHERE account.status='使用'
                             AND account.balance_current < 0) AS negative_count
                FROM accounts account
                LEFT JOIN currencies currency ON currency.id=account.currency_id
                WHERE COALESCE(account.is_deleted,FALSE)=FALSE
                GROUP BY account.currency_id, currency.code, currency.name
                ORDER BY currency_code, currency_name
                """));
        List<AccountCurrencySummary> currencies = new ArrayList<>(rows.size());
        long total = 0;
        long active = 0;
        long warnings = 0;
        long negatives = 0;
        for (Object[] row : rows) {
            long accountCount = ((Number) row[3]).longValue();
            long activeCount = ((Number) row[4]).longValue();
            long warningCount = ((Number) row[6]).longValue();
            long negativeCount = ((Number) row[7]).longValue();
            BigDecimal balanceTotal = decimal(row[5]);
            total += accountCount;
            active += activeCount;
            warnings += warningCount;
            negatives += negativeCount;
            if (activeCount > 0) {
                currencies.add(new AccountCurrencySummary(
                        (UUID) row[0],
                        String.valueOf(row[1]),
                        String.valueOf(row[2]),
                        accountCount,
                        activeCount,
                        balanceTotal,
                        plainOrNull(balanceTotal),
                        warningCount,
                        negativeCount));
            }
        }
        return new AccountSummary(
                total, active, total - active, warnings, negatives, currencies);
    }

    // ===== 详情 / CRUD =====

    /** 全量字典（钱流单据选账户用）：返回全部未软删账户，按编号排序。 */
    @Transactional(readOnly = true)
    public List<AccountListItem> dict() {
        Specification<Account> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        List<Account> accounts = repo.findAll(spec, Sort.by(Sort.Direction.ASC, "code"));
        Map<UUID, CurrencyMeta> currencyMeta = currencyMetaFor(accounts);
        return accounts.stream()
                .map(account -> toList(
                        account, currencyMetaOf(account.getCurrencyId(), currencyMeta)))
                .toList();
    }

    @Transactional(readOnly = true)
    public AccountDetail detail(UUID id) {
        Account account = requireAccount(id);
        CurrencyMeta currency = currencyMetaOf(
                account.getCurrencyId(), currencyMetaFor(List.of(account)));
        BalanceIntegrity integrity = hasAuthority("account:balance:view")
                ? balanceIntegrity(account.getId()) : null;
        return toDetail(account, currency, integrity);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('account:create')")
    @Transactional
    public AccountDetail create(AccountSaveRequest req) {
        tx.bind();
        if (req.getInitBalance() != null && req.getInitBalance().signum() != 0) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("account:balance:adjust");
        }
        if (req.getBalanceFloor() != null) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("account:warning:manage");
        }
        if (req.getStatus() != null && !"使用".equals(req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("account:status");
        }
        if (req.getStyleId() != null || req.getStyleLegacyId() != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        lockAccountPopulation();
        Account a = new Account();
        apply(req, a);
        a.setCode(resolveCode(req, null));
        if (a.getStatus() == null) a.setStatus("使用");
        if ("使用".equals(a.getStatus())) requireActiveCurrency(a.getCurrencyId());
        recomputeBalance(a);
        repo.save(a);
        return toDetail(a);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('account:edit', 'account:status')")
    @Transactional
    public AccountDetail update(UUID id, AccountSaveRequest req) {
        tx.bind();
        com.uten.imp.security.CurrentAuthorityGuard.requireAll("account:edit");
        boolean targetActive = "使用".equals(req.getStatus());
        if (targetActive || req.getStyleId() != null || req.getStyleLegacyId() != null) {
            PaymentStyleHierarchyLock.lock(em);
        }
        lockAccountPopulation();
        Account a = requireAccount(id);
        em.refresh(a, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (req.getStatus() != null && !Objects.equals(a.getStatus(), req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("account:status");
        }
        if (targetActive
                && req.getStyleId() == null
                && req.getStyleLegacyId() == null
                && (a.getStyleId() != null || a.getStyleLegacyId() != null)) {
            applyStyleReference(a.getStyleId(), a.getStyleLegacyId(), a);
        }
        boolean currencyChanged = !Objects.equals(a.getCurrencyId(), req.getCurrencyId());
        boolean openingChanged = req.getInitBalance() != null
                && nz(a.getInitBalance()).compareTo(req.getInitBalance()) != 0;
        boolean styleChanged = req.getStyleId() != null
                && !Objects.equals(a.getStyleId(), req.getStyleId());
        boolean floorChanged = req.getBalanceFloor() != null
                && (a.getBalanceFloor() == null
                    || a.getBalanceFloor().compareTo(req.getBalanceFloor()) != 0);
        boolean deactivating = "使用".equals(a.getStatus())
                && req.getStatus() != null
                && !req.getStatus().isBlank()
                && !"使用".equals(req.getStatus());
        if (openingChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("account:balance:adjust");
        }
        if (floorChanged) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("account:warning:manage");
        }
        if (currencyChanged || openingChanged || styleChanged) {
            assertHistoricalMoneyFieldsCanChange(
                    a, changedHistoricalFields(currencyChanged, openingChanged, styleChanged));
        }
        if (deactivating) {
            assertNoApprovedFinancialUsage(a.getId(), "停用");
        }
        apply(req, a);
        a.setCode(resolveCode(req, a));
        if ("使用".equals(a.getStatus())) requireActiveCurrency(a.getCurrencyId());
        recomputeBalance(a);
        repo.save(a);
        return toDetail(a);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('account:status')")
    @Transactional
    public AccountDetail changeStatus(
            UUID id, com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        tx.bind();
        boolean targetActive = "使用".equals(req.status());
        if (targetActive) {
            PaymentStyleHierarchyLock.lock(em);
        }
        lockAccountPopulation();
        Account a = requireAccount(id);
        em.refresh(a, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (Objects.equals(a.getStatus(), req.status())) {
            return toDetail(a);
        }
        if (targetActive && a.getStyleId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "使用中的账户必须选择会计科目 UUID");
        }
        if (targetActive) requireActiveCurrency(a.getCurrencyId());
        if (!targetActive) {
            assertNoApprovedFinancialUsage(a.getId(), "停用");
        }
        a.setStatus(req.status());
        recomputeBalance(a);
        repo.save(a);
        return toDetail(a);
    }

    @org.springframework.security.access.prepost.PreAuthorize(
            "hasAuthority('account:view') and hasAuthority('account:balance:view') "
                    + "and hasAuthority('account:warning:manage')")
    @Transactional
    public AccountDetail updateWarning(UUID id, AccountWarningUpdateRequest req) {
        tx.bind();
        Account account = requireAccount(id);
        em.refresh(account, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        account.setBalanceFloor(req.balanceFloor());
        repo.save(account);
        return toDetail(account);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('account:delete')")
    @Transactional
    public void delete(UUID id) {
        tx.bind();
        lockAccountPopulation();
        Account a = requireAccount(id);
        em.refresh(a, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        assertNoApprovedFinancialUsage(a.getId(), "删除");
        a.setDeleted(true);
        a.setDeletedAt(OffsetDateTime.now());
        repo.save(a);
    }

    /** 应用请求字段到实体（不含 receipts/payments/balance，由 Service 维护）。 */
    private void apply(AccountSaveRequest req, Account a) {
        a.setName(req.getName());
        a.setBankAccountNo(req.getBankAccountNo());
        a.setAccountType(req.getAccountType() == null || req.getAccountType().isBlank()
                ? inferAccountType(req.getName()) : req.getAccountType());
        a.setCurrencyId(req.getCurrencyId());
        if (req.getInitBalance() != null) a.setInitBalance(req.getInitBalance());
        if (req.getBalanceFloor() != null) a.setBalanceFloor(req.getBalanceFloor());
        if (req.getParentLegacyId() != null) a.setParentLegacyId(req.getParentLegacyId());
        applyStyleReference(req, a);
        if (req.getStatus() != null && !req.getStatus().isBlank()) a.setStatus(req.getStatus());
        if ("使用".equals(a.getStatus()) && a.getStyleId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "使用中的账户必须选择会计科目 UUID");
        }
    }

    /** 有期初或任何资金事实后，账户币别与期初余额成为不可变历史口径。 */
    private void assertHistoricalMoneyFieldsCanChange(Account account, String fields) {
        boolean hasAmounts = nz(account.getInitBalance()).signum() != 0
                || nz(account.getReceiptsTotal()).signum() != 0
                || nz(account.getPaymentsTotal()).signum() != 0
                || nz(account.getBalanceAdjustmentsTotal()).signum() != 0;
        long activeFlowCount = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_reconciliations
                        WHERE account_id=:accountId
                          AND COALESCE(is_deleted,false)=false
                        """)
                .setParameter("accountId", account.getId())
                .getSingleResult()).longValue();
        long historicalDocumentCount = financialDocumentUsageCount(account.getId(), "<>0");
        long adjustmentItemCount = adjustmentItemCount(account.getId());
        if (hasAmounts || activeFlowCount > 0 || historicalDocumentCount > 0
                || adjustmentItemCount > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "账户已有期初或资金流水，" + fields + "不可修改；请新建账户或使用调整单");
        }
    }

    /** 已审核资金单据仍可能需要红冲，所用账户必须保持可用且不可删除。 */
    private void assertNoApprovedFinancialUsage(UUID accountId, String action) {
        long activeFlowCount = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM finance_reconciliations
                        WHERE account_id=:accountId
                          AND COALESCE(is_deleted,false)=false
                        """)
                .setParameter("accountId", accountId)
                .getSingleResult()).longValue();
        if (activeFlowCount > 0 || financialDocumentUsageCount(accountId, "=1") > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "账户仍被已审核资金单据使用，不能" + action + "；请先按业务单据完成红冲");
        }
    }

    /**
     * 账户作为资金收付方的历史单据计数。status=1 用于停用/删除守卫；
     * status&lt;&gt;0 还包含已红冲事实，用于永久冻结币别与期初口径。
     */
    private long financialDocumentUsageCount(UUID accountId, String statusPredicate) {
        String sql = """
                SELECT COALESCE(SUM(fact_count),0)
                FROM (
                    SELECT COUNT(*) AS fact_count FROM finance_receipts
                     WHERE account_id=:accountId AND status %s
                    UNION ALL
                    SELECT COUNT(*) FROM finance_payments
                     WHERE account_id=:accountId AND status %s
                    UNION ALL
                    SELECT COUNT(*) FROM finance_expenses
                     WHERE account_id=:accountId AND status %s
                    UNION ALL
                    SELECT COUNT(*) FROM finance_other_incomes
                     WHERE account_id=:accountId AND status %s
                    UNION ALL
                    SELECT COUNT(*) FROM finance_bank_transfers
                     WHERE out_account_id=:accountId AND status %s
                    UNION ALL
                    SELECT COUNT(*)
                    FROM finance_bank_transfer_lines line
                    JOIN finance_bank_transfers transfer ON transfer.id=line.transfer_id
                    WHERE line.in_account_id=:accountId AND transfer.status %s
                ) facts
                """.formatted(statusPredicate, statusPredicate, statusPredicate,
                statusPredicate, statusPredicate, statusPredicate);
        return ((Number) em.createNativeQuery(sql)
                .setParameter("accountId", accountId)
                .getSingleResult()).longValue();
    }

    private long adjustmentItemCount(UUID accountId) {
        return ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM account_balance_adjustment_items
                        WHERE account_id=:accountId
                        """)
                .setParameter("accountId", accountId)
                .getSingleResult()).longValue();
    }

    private void lockAccountPopulation() {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "ACCOUNT_MASTER_POPULATION")
                .getSingleResult();
    }

    private void requireActiveCurrency(UUID currencyId) {
        if (currencyId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "使用中的账户必须明确选择币种 UUID，不能默认猜测人民币");
        }
        long matches = ((Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM currencies
                        WHERE id=:currencyId
                          AND status='使用'
                          AND COALESCE(is_deleted,FALSE)=FALSE
                        """)
                .setParameter("currencyId", currencyId)
                .getSingleResult()).longValue();
        if (matches != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "账户币种不存在、已禁用或已删除");
        }
    }

    /** 余额守恒：balance = init + receipts − payments + adjustments。 */
    public static BigDecimal recomputeBalance(Account a) {
        BigDecimal init = nz(a.getInitBalance());
        BigDecimal rcv = nz(a.getReceiptsTotal());
        BigDecimal paid = nz(a.getPaymentsTotal());
        BigDecimal adjusted = nz(a.getBalanceAdjustmentsTotal());
        BigDecimal bal = init.add(rcv).subtract(paid).add(adjusted);
        a.setBalanceCurrent(bal);
        return bal;
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }

    private AccountDetail toDetail(Account a) {
        return toDetail(a, currencyMetaOf(
                a.getCurrencyId(), currencyMetaFor(List.of(a))));
    }

    private AccountDetail toDetail(Account a, CurrencyMeta currency) {
        return toDetail(a, currency, null);
    }

    private AccountDetail toDetail(
            Account a, CurrencyMeta currency, BalanceIntegrity integrity) {
        boolean showBalance = hasAuthority("account:balance:view");
        return new AccountDetail(a.getId(), a.getLegacyId(), a.getCode(), a.getName(),
                a.getBankAccountNo(), a.getAccountType(), a.getCurrencyId(),
                currency.code(), currency.name(), currency.exchangeRate(),
                currency.baseCurrency(),
                showBalance ? a.getInitBalance() : null,
                showBalance ? a.getReceiptsTotal() : null,
                showBalance ? a.getPaymentsTotal() : null,
                showBalance ? a.getBalanceAdjustmentsTotal() : null,
                showBalance ? a.getBalanceCurrent() : null,
                showBalance ? a.getBalanceFloor() : null,
                showBalance ? plainOrNull(a.getInitBalance()) : null,
                showBalance ? plainOrNull(a.getReceiptsTotal()) : null,
                showBalance ? plainOrNull(a.getPaymentsTotal()) : null,
                showBalance ? plainOrNull(a.getBalanceAdjustmentsTotal()) : null,
                showBalance ? plainOrNull(a.getBalanceCurrent()) : null,
                showBalance ? plainOrNull(a.getBalanceFloor()) : null,
                plainOrNull(currency.exchangeRate()),
                a.getParentLegacyId(), a.getStyleLegacyId(), a.getStyleId(),
                a.getStatus(), a.isAutoCreated(),
                showBalance && integrity != null ? integrity.flowBalance() : null,
                showBalance && integrity != null ? integrity.difference() : null,
                showBalance && integrity != null
                        ? plainOrNull(integrity.flowBalance()) : null,
                showBalance && integrity != null
                        ? plainOrNull(integrity.difference()) : null,
                showBalance && integrity != null
                        ? integrity.difference().signum()==0 : null,
                showBalance && integrity != null ? integrity.flowCount() : null,
                showBalance && integrity != null ? integrity.latestFlowAt() : null);
    }

    private BalanceIntegrity balanceIntegrity(UUID accountId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT flow_balance,balance_difference,
                               active_flow_count,latest_flow_at
                        FROM v_account_balance_integrity
                        WHERE account_id=:accountId
                        """)
                .setParameter("accountId", accountId));
        if (rows.size()!=1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "账户余额完整性投影缺失或重复，请先运行财务对账");
        }
        Object[] row=rows.getFirst();
        return new BalanceIntegrity(
                decimal(row[0]),decimal(row[1]),
                ((Number)row[2]).longValue(),
                row[3]==null?null:row[3].toString());
    }

    private AccountListItem toList(Account a, CurrencyMeta currency) {
        boolean showBalance = hasAuthority("account:balance:view");
        return new AccountListItem(a.getId(), a.getLegacyId(), a.getCode(), a.getName(),
                a.getBankAccountNo(), a.getAccountType(), a.getCurrencyId(),
                currency.code(), currency.name(), currency.exchangeRate(),
                currency.baseCurrency(),
                showBalance ? a.getInitBalance() : null,
                showBalance ? a.getReceiptsTotal() : null,
                showBalance ? a.getPaymentsTotal() : null,
                showBalance ? a.getBalanceAdjustmentsTotal() : null,
                showBalance ? a.getBalanceCurrent() : null,
                showBalance ? a.getBalanceFloor() : null,
                showBalance ? plainOrNull(a.getInitBalance()) : null,
                showBalance ? plainOrNull(a.getReceiptsTotal()) : null,
                showBalance ? plainOrNull(a.getPaymentsTotal()) : null,
                showBalance ? plainOrNull(a.getBalanceAdjustmentsTotal()) : null,
                showBalance ? plainOrNull(a.getBalanceCurrent()) : null,
                showBalance ? plainOrNull(a.getBalanceFloor()) : null,
                plainOrNull(currency.exchangeRate()),
                a.getStatus());
    }

    private Map<UUID, CurrencyMeta> currencyMetaFor(Collection<Account> accounts) {
        List<UUID> ids = accounts.stream()
                .map(Account::getCurrencyId)
                .filter(Objects::nonNull)
                .distinct()
                .toList();
        if (ids.isEmpty()) return Map.of();
        Map<UUID, CurrencyMeta> result = new LinkedHashMap<>();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT id, code, name, exchange_rate, is_base_currency
                        FROM currencies
                        WHERE id IN (:ids)
                        """)
                .setParameter("ids", ids));
        for (Object[] row : rows) {
            result.put((UUID) row[0], new CurrencyMeta(
                    row[1] == null ? "—" : row[1].toString(),
                    row[2] == null ? "未命名币种" : row[2].toString(),
                    row[3] == null ? null : decimal(row[3]),
                    Boolean.TRUE.equals(row[4])));
        }
        return result;
    }

    private static CurrencyMeta currencyMetaOf(
            UUID currencyId, Map<UUID, CurrencyMeta> meta) {
        if (currencyId == null) {
            return new CurrencyMeta("—", "未设置币种", null, false);
        }
        return meta.getOrDefault(
                currencyId, new CurrencyMeta("—", "币种资料缺失", null, false));
    }

    private record CurrencyMeta(
            String code, String name, BigDecimal exchangeRate, boolean baseCurrency) {
    }

    private record BalanceIntegrity(
            BigDecimal flowBalance,
            BigDecimal difference,
            long flowCount,
            String latestFlowAt) {}

    private String resolveCode(AccountSaveRequest req, Account existing) {
        String code = req.getCode() == null ? null : req.getCode().trim();
        if (code == null || code.isEmpty()) {
            return existing == null ? masterCodeService.nextCode(CODE_PREFIX) : existing.getCode();
        }
        boolean duplicate = existing == null
                ? repo.existsByCodeIgnoreCaseAndDeletedFalse(code)
                : repo.existsByCodeIgnoreCaseAndDeletedFalseAndIdNot(code, existing.getId());
        if (duplicate) {
            throw new ApiException(ErrorCode.CONFLICT, "编号已存在：" + code);
        }
        return code;
    }

    private Map<String, String> currencyLabels() {
        Map<String, String> labels = new LinkedHashMap<>();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT id, code, name FROM currencies
                WHERE COALESCE(is_deleted,FALSE)=FALSE
                """));
        for (Object[] row : rows) {
            String code = row[1] == null ? "" : row[1].toString().trim();
            String name = row[2] == null ? "" : row[2].toString().trim();
            String label = code.isEmpty() ? name : name.isEmpty() ? code : code + " · " + name;
            labels.put(String.valueOf(row[0]), label);
        }
        return labels;
    }

    private static String facetLabel(
            String field, String value, Map<String, String> currencyLabels) {
        if ("accountType".equals(field)) return accountTypeLabel(value);
        if ("currencyId".equals(field)) return currencyLabels.getOrDefault(value, value);
        return value;
    }

    private static String accountTypeLabel(String value) {
        return switch (value == null ? "" : value) {
            case TYPE_BANK -> "银行账户";
            case TYPE_CASH -> "现金";
            case TYPE_CHECK -> "本公司支票";
            case TYPE_FOREIGN_CHECK -> "外来支票";
            case TYPE_THIRD_PARTY -> "第三方支付";
            case TYPE_OFFSHORE -> "境外账户";
            case TYPE_GENERAL -> "一般账户";
            default -> value;
        };
    }

    private static String changedHistoricalFields(
            boolean currencyChanged, boolean openingChanged, boolean styleChanged) {
        List<String> fields = new ArrayList<>();
        if (currencyChanged) fields.add("币别");
        if (openingChanged) fields.add("期初余额");
        if (styleChanged) fields.add("会计科目");
        return String.join("、", fields);
    }

    private static boolean hasAuthority(String authority) {
        var authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication == null || !authentication.isAuthenticated()) return false;
        if (authentication.getPrincipal() instanceof com.uten.imp.security.AuthUser user
                && user.isSuperAdmin()) {
            return true;
        }
        return authentication.getAuthorities().stream()
                .anyMatch(granted -> authority.equals(granted.getAuthority()));
    }

    private static BigDecimal decimal(Object value) {
        if (value instanceof BigDecimal amount) return amount;
        if (value instanceof Number number) return BigDecimal.valueOf(number.doubleValue());
        return value == null ? BigDecimal.ZERO : new BigDecimal(value.toString());
    }

    private static String plainOrNull(BigDecimal value) {
        return value == null ? null : value.toPlainString();
    }

    private Account requireAccount(UUID id) {
        return repo.findById(id)
                .filter(a -> !a.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "账户不存在"));
    }

    /** 正常 API 只按 UUID 选择科目；legacy 值只能作为与 UUID 一致的兼容影子。 */
    private void applyStyleReference(AccountSaveRequest req, Account account) {
        applyStyleReference(req.getStyleId(), req.getStyleLegacyId(), account);
    }

    private void applyStyleReference(
            UUID styleId, Integer styleLegacyId, Account account) {
        if (styleId == null) {
            if (styleLegacyId != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "styleLegacyId 不能用于建立关联，请选择会计科目 UUID");
            }
            return;
        }
        @SuppressWarnings("unchecked")
        List<Object[]> matches = em.createNativeQuery("""
                        SELECT id, legacy_id
                        FROM payment_styles
                        WHERE COALESCE(is_deleted,false)=false
                          AND status='使用'
                          AND category='ACCOUNT'
                          AND NOT EXISTS (
                              SELECT 1 FROM payment_styles child
                              WHERE child.parent_id=payment_styles.id
                                AND COALESCE(child.is_deleted,false)=false)
                          AND id=:styleId
                        """)
                .setParameter("styleId", styleId)
                .getResultList();
        if (matches.size() != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "会计科目不存在、已禁用或不是可过账的账户类叶节点");
        }
        Object[] resolved = matches.getFirst();
        Integer canonicalLegacyId = resolved[1] == null
                ? null : ((Number) resolved[1]).intValue();
        if (styleLegacyId != null
                && !Objects.equals(styleLegacyId, canonicalLegacyId)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "会计科目 UUID 与 legacy 影子不一致");
        }
        account.setStyleId((UUID) resolved[0]);
        account.setStyleLegacyId(canonicalLegacyId);
    }
}
