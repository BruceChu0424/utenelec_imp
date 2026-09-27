package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationListItem;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationQueryFilter;
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
            "billNo", "billNo");

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('account:view') and hasAuthority('account:balance:view') "
            + "and hasAuthority('account:flow:view')")
    public PageResponse<FinanceReconciliationListItem> list(FinanceReconciliationQueryFilter f, int page, int size, String sort, String order) {
        Specification<FinanceReconciliation> spec = reconciliationSpec(f);
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<FinanceReconciliation> p = repo.findAll(spec, pageable);
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
        return (Root<FinanceReconciliation> root,
                jakarta.persistence.criteria.CriteriaQuery<?> q,
                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
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
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    private FinanceReconciliationListItem toList(FinanceReconciliation r) {
        return new FinanceReconciliationListItem(r.getId(), r.getBillNo(), r.getSourceDocType(),
                r.getSourceDocId(), r.getAccountId(), r.getCheckNo(), r.getCounterpartName(),
                r.getInAmount(), r.getOutAmount(), r.getBillDate(), r.getSettledDate(),
                r.getSourceRemark(), r.getLegacyBstyle(), r.getEntryKind(), r.getReversalOfId());
    }
}
