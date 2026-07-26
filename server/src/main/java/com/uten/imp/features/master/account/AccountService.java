package com.uten.imp.features.master.account;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.account.dto.AccountDetail;
import com.uten.imp.features.master.account.dto.AccountFacets;
import com.uten.imp.features.master.account.dto.AccountListItem;
import com.uten.imp.features.master.account.dto.AccountQueryFilter;
import com.uten.imp.features.master.account.dto.AccountSaveRequest;
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
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 账户主档：扁平列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（account:edit）。
 *
 * <p>范式同 {@code CurrencyService}，加账户类型枚举与余额字段。
 * 收付款单据审核时由钱流 Service 维护 {@code receipts_total/payments_total/balance_current}，
 * 余额守恒 {@code balanceCurrent = initBalance + receiptsTotal − paymentsTotal}。
 *
 * <p>{@link #inferAccountType} 是迁移「按 AccName 关键字 CASE WHEN 映射」的 Java 版本单一事实源，
 * 供迁移脚本参考与运行时新建账户缺省类型推断；老库 AStyle 全为 1 已丢弃。
 */
@Service
@RequiredArgsConstructor
public class AccountService {

    /** 账户类型枚举值（对齐 V50 CHECK 约束）。 */
    public static final String TYPE_BANK = "BANK";
    public static final String TYPE_CASH = "CASH";
    public static final String TYPE_CHECK = "CHECK";
    public static final String TYPE_FOREIGN_CHECK = "FOREIGN_CHECK";
    public static final String TYPE_THIRD_PARTY = "THIRD_PARTY";
    public static final String TYPE_OFFSHORE = "OFFSHORE";
    public static final String TYPE_GENERAL = "GENERAL";

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS =
            Set.of("code", "bankAccountNo", "currencyId", "parentLegacyId", "styleLegacyId");

    /** facet 截断阈值。 */
    private static final int FACET_LIMIT = 50;

    /** facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。 */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("accountType", "account_type");
        FACET_COLUMNS.put("status", "status");
        FACET_COLUMNS.put("currencyId", "currency_id");
    }

    private final AccountRepository repo;
    private final TxSessionVars tx;
    private final EntityManager em;

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
    public PageResponse<AccountListItem> list(AccountQueryFilter f, int page, int size) {
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
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "code"));
        Page<Account> p = repo.findAll(spec, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Account> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    // ===== facets（各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public AccountFacets facets() {
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            String col = e.getValue();   // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL
            List<Object[]> rows = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from accounts "
                            + "where is_deleted = false and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .getResultList();
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from accounts where is_deleted = false and " + col + " is null")
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new AccountFacets(buckets.get("accountType"), buckets.get("status"),
                buckets.get("currencyId"), nullCounts);
    }

    // ===== 详情 / CRUD =====

    /** 全量字典（钱流单据选账户用）：返回全部未软删账户，按编号排序。 */
    @Transactional(readOnly = true)
    public List<AccountListItem> dict() {
        Specification<Account> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        return repo.findAll(spec, Sort.by(Sort.Direction.ASC, "code")).stream()
                .map(this::toList).toList();
    }

    @Transactional(readOnly = true)
    public AccountDetail detail(UUID id) {
        return toDetail(requireAccount(id));
    }

    @Transactional
    public AccountDetail create(AccountSaveRequest req) {
        tx.bind();
        Account a = new Account();
        apply(req, a);
        recomputeBalance(a);
        repo.save(a);
        return toDetail(a);
    }

    @Transactional
    public AccountDetail update(UUID id, AccountSaveRequest req) {
        tx.bind();
        Account a = requireAccount(id);
        apply(req, a);
        recomputeBalance(a);
        repo.save(a);
        return toDetail(a);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Account a = requireAccount(id);
        a.setDeleted(true);
        a.setDeletedAt(OffsetDateTime.now());
        repo.save(a);
    }

    /** 应用请求字段到实体（不含 receipts/payments/balance，由 Service 维护）。 */
    private void apply(AccountSaveRequest req, Account a) {
        a.setName(req.getName());
        a.setCode(req.getCode());
        a.setBankAccountNo(req.getBankAccountNo());
        a.setAccountType(req.getAccountType() == null || req.getAccountType().isBlank()
                ? inferAccountType(req.getName()) : req.getAccountType());
        a.setCurrencyId(req.getCurrencyId());
        if (req.getInitBalance() != null) a.setInitBalance(req.getInitBalance());
        if (req.getParentLegacyId() != null) a.setParentLegacyId(req.getParentLegacyId());
        if (req.getStyleLegacyId() != null) a.setStyleLegacyId(req.getStyleLegacyId());
        if (req.getStatus() != null && !req.getStatus().isBlank()) a.setStatus(req.getStatus());
    }

    /** 余额守恒：balance = init + receipts − payments。 */
    public static BigDecimal recomputeBalance(Account a) {
        BigDecimal init = nz(a.getInitBalance());
        BigDecimal rcv = nz(a.getReceiptsTotal());
        BigDecimal paid = nz(a.getPaymentsTotal());
        BigDecimal bal = init.add(rcv).subtract(paid);
        a.setBalanceCurrent(bal);
        return bal;
    }

    private static BigDecimal nz(BigDecimal x) {
        return x == null ? BigDecimal.ZERO : x;
    }

    private AccountDetail toDetail(Account a) {
        return new AccountDetail(a.getId(), a.getLegacyId(), a.getCode(), a.getName(),
                a.getBankAccountNo(), a.getAccountType(), a.getCurrencyId(),
                a.getInitBalance(), a.getReceiptsTotal(), a.getPaymentsTotal(), a.getBalanceCurrent(),
                a.getParentLegacyId(), a.getStyleLegacyId(), a.getStatus(), a.isAutoCreated());
    }

    private AccountListItem toList(Account a) {
        return new AccountListItem(a.getId(), a.getLegacyId(), a.getCode(), a.getName(),
                a.getBankAccountNo(), a.getAccountType(), a.getCurrencyId(),
                a.getInitBalance(), a.getReceiptsTotal(), a.getPaymentsTotal(), a.getBalanceCurrent(),
                a.getStatus());
    }

    private Account requireAccount(UUID id) {
        return repo.findById(id)
                .filter(a -> !a.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "账户不存在"));
    }
}
