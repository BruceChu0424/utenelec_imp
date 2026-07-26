package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationListItem;
import com.uten.imp.features.finance.reconciliation.dto.FinanceReconciliationQueryFilter;
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

import java.util.ArrayList;
import java.util.List;

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

    @Transactional(readOnly = true)
    public PageResponse<FinanceReconciliationListItem> list(FinanceReconciliationQueryFilter f, int page, int size) {
        Specification<FinanceReconciliation> spec = (Root<FinanceReconciliation> root,
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
            if (f.sourceDocId() != null) ps.add(cb.equal(root.get("sourceDocId"), f.sourceDocId()));
            if (f.checkNo() != null && !f.checkNo().isBlank()) ps.add(cb.equal(root.get("checkNo"), f.checkNo()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "billDate"));
        Page<FinanceReconciliation> p = repo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    private FinanceReconciliationListItem toList(FinanceReconciliation r) {
        return new FinanceReconciliationListItem(r.getId(), r.getBillNo(), r.getSourceDocType(),
                r.getSourceDocId(), r.getAccountId(), r.getCheckNo(), r.getCounterpartName(),
                r.getInAmount(), r.getOutAmount(), r.getBillDate(), r.getSettledDate(),
                r.getSourceRemark(), r.getLegacyBstyle());
    }
}
