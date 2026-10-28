package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationListItem;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationQueryFilter;
import com.uten.imp.common.util.NameRefKeyword;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 账户流水查询服务（只读）。流水写入由各 finance_*审核 Service 用 EntityManager 直插
 * （{@code FinanceReceiptService.insertReconciliation} 等）。
 *
 * <p>报表 S 帐户进出流水帐的核心数据源；前端"账户流水"列表页查询入口。
 */
@Service
@RequiredArgsConstructor
public class FinanceReconciliationService {

    private final FinanceReconciliationRepository repo;
    private final EntityManager em;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额/单据号可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate",
            "inAmount", "inAmount",
            "outAmount", "outAmount",
            // 2026-09-25 单号列统一：单据号可排序。
            "billNo", "billNo", "counterpartName","counterpartName");
    private static final Map<String,com.uten.imp.common.util.JpaColumnSearch.Field> HEADER_FIELDS=Map.of(
            "billDate",com.uten.imp.common.util.JpaColumnSearch.Field.instant("billDate"),
            "billNo",com.uten.imp.common.util.JpaColumnSearch.Field.text("billNo"),
            "counterpartName",com.uten.imp.common.util.JpaColumnSearch.Field.text("counterpartName"),
            "inAmount",com.uten.imp.common.util.JpaColumnSearch.Field.decimal("inAmount"),
            "outAmount",com.uten.imp.common.util.JpaColumnSearch.Field.decimal("outAmount"));

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('account:view') and hasAuthority('account:balance:view') "
            + "and hasAuthority('account:flow:view')")
    public PageResponse<FinanceReconciliationListItem> list(FinanceReconciliationQueryFilter f, int page, int size, String sort, String order) {
        requireAmountAccount(f,sort);
        Specification<FinanceReconciliation> spec = reconciliationSpec(f);
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        var searchPage = NameRefKeyword.page(spec,pageable,sort!=null&&ALLOWED_SORT.containsKey(sort)?null:f.keyword());
        Page<FinanceReconciliation> p = repo.findAll(searchPage.specification(), searchPage.pageable());
        return new PageResponse<>(p.map(this::toList).getContent(), p);
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一份谓词分组计数。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('account:view') and hasAuthority('account:balance:view') "
            + "and hasAuthority('account:flow:view')")
    public Map<String, List<Map<String, Object>>> facets(FinanceReconciliationQueryFilter f) {
        return Map.of("billNo",
                com.uten.imp.common.web.TableFacets.groupCount(
                        em, FinanceReconciliation.class, reconciliationSpec(f), "billNo"));
    }

    /** 列表谓词（list 与 facets 共用，2026-09-25 单号列统一抽出；billNo=表头单据号精确匹配）。 */
    private Specification<FinanceReconciliation> reconciliationSpec(FinanceReconciliationQueryFilter f) {
        requireAmountAccount(f,null);
        var searches=com.uten.imp.common.util.JpaColumnSearch.validate(f.columnSearch(),HEADER_FIELDS);
        return (Root<FinanceReconciliation> root,
                jakarta.persistence.criteria.CriteriaQuery<?> q,
                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                // 全行可搜（2026-10-09「行里显示什么就能按什么搜」）：单据号 + 引用主档名称
                //（经 NameRefKeyword 转外键 IN 子查询，count 同谓词派生）。
                ps.add(NameRefKeyword.match(root, q, cb, f.keyword(), kw -> {
                var kws = NameRefKeyword.keywords();
                kws.add(NameRefKeyword.text(cb, root.get("billNo"), kw));
                NameRefKeyword.byName(kws, q, cb, root.get("accountId"),
                        com.uten.imp.features.master.account.Account.class, "name", kw);
                NameRefKeyword.byName(kws, q, cb, root.get("accountId"),
                        com.uten.imp.features.master.account.Account.class, "code", kw);
                return cb.or(kws.toArray(new Predicate[0]));
                }));
            }
            if (f.accountId() != null) ps.add(cb.equal(root.get("accountId"), f.accountId()));
            if (f.sourceDocType() != null && !f.sourceDocType().isBlank())
                ps.add(cb.equal(root.get("sourceDocType"), f.sourceDocType()));
            if (f.entryKind() != null && !f.entryKind().isBlank())
                ps.add(cb.equal(root.get("entryKind"), f.entryKind()));
            if (f.sourceDocId() != null) ps.add(cb.equal(root.get("sourceDocId"), f.sourceDocId()));
            if (f.checkNo() != null && !f.checkNo().isBlank()) ps.add(cb.equal(root.get("checkNo"), f.checkNo()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            // 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配。
            if (f.billNo() != null && !f.billNo().isBlank()) {
                ps.add(cb.equal(root.get("billNo"), f.billNo().trim()));
            }
            if(f.reversalOfId()!=null)ps.add(cb.equal(root.get("reversalOfId"),f.reversalOfId()));
            ps.add(com.uten.imp.common.util.JpaColumnSearch.predicate(root,q,cb,searches,HEADER_FIELDS));
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    private FinanceReconciliationListItem toList(FinanceReconciliation r) {
        return new FinanceReconciliationListItem(r.getId(), r.getBillNo(), r.getSourceDocType(),
                r.getSourceDocId(), r.getAccountId(), r.getCheckNo(), r.getCounterpartName(),
                r.getInAmount(), r.getOutAmount(), r.getBillDate(), r.getSettledDate(),
                r.getSourceRemark(), r.getLegacyBstyle(), r.getEntryKind(), r.getReversalOfId());
    }

    private static void requireAmountAccount(FinanceReconciliationQueryFilter f,String sort) {
        boolean amountSearch=f.columnSearch().entrySet().stream().anyMatch(entry->java.util.Set.of("inAmount","outAmount").contains(entry.getKey())&&entry.getValue()!=null&&!entry.getValue().isBlank());
        if(f.accountId()==null&&(amountSearch||"inAmount".equals(sort)||"outAmount".equals(sort)))
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"按原币收入或支出筛选、排序前，请先选择账户");
    }
}
