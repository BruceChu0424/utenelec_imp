package com.uten.imp.features.finance.arap;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.finance.arap.dto.ArApLedgerDetail;
import com.uten.imp.features.finance.arap.dto.ArApLedgerListItem;
import com.uten.imp.features.finance.arap.dto.ArApLedgerQueryFilter;
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
import java.util.Map;
import java.util.UUID;

/**
 * 应收应付台账只读应用服务。
 *
 * <p>Controller 只负责 HTTP 参数与权限；查询条件、分页、排序和 DTO 映射集中在本类，
 * 避免 Web 层直接依赖 Repository。
 */
@Service
@RequiredArgsConstructor
public class ArApLedgerQueryService {

    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate",
            "amountOriginalLocal", "amountOriginalLocal",
            "amountSettled", "amountSettled",
            "amountBalance", "amountBalance");

    private final ArApLedgerRepository repo;

    @Transactional(readOnly = true)
    public PageResponse<ArApLedgerListItem> list(
            ArApLedgerQueryFilter filter, int page, int size, String sort, String order) {
        Specification<ArApLedger> spec = specification(filter);
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<ArApLedger> result = repo.findAll(spec, pageable);
        return new PageResponse<>(
                result.map(this::toListItem).getContent(),
                page,
                size,
                result.getTotalElements(),
                result.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ArApLedgerDetail detail(UUID id) {
        ArApLedger ledger = repo.findById(id)
                .filter(item -> !item.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "应收应付记录不存在"));
        return toDetail(ledger);
    }

    private Specification<ArApLedger> specification(ArApLedgerQueryFilter f) {
        return (Root<ArApLedger> root, jakarta.persistence.criteria.CriteriaQuery<?> query,
                CriteriaBuilder cb) -> {
            List<Predicate> predicates = new ArrayList<>();
            predicates.add(cb.isFalse(root.get("deleted")));
            if (hasText(f.keyword())) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                predicates.add(cb.or(
                        cb.like(cb.lower(root.get("billNo")), like),
                        cb.like(cb.lower(root.get("sourceDocNo")), like)));
            }
            if (hasText(f.direction())) {
                predicates.add(cb.equal(root.get("direction"), f.direction()));
            }
            if (hasText(f.sourceDocType())) {
                predicates.add(cb.equal(root.get("sourceDocType"), f.sourceDocType()));
            }
            if (f.partyId() != null) {
                if ("AR".equals(f.direction())) {
                    predicates.add(cb.equal(root.get("clientId"), f.partyId()));
                } else if ("AP".equals(f.direction())) {
                    predicates.add(cb.equal(root.get("supplierId"), f.partyId()));
                } else {
                    predicates.add(cb.or(
                            cb.equal(root.get("clientId"), f.partyId()),
                            cb.equal(root.get("supplierId"), f.partyId())));
                }
            }
            if (f.clientId() != null) {
                predicates.add(cb.equal(root.get("clientId"), f.clientId()));
            }
            if (f.supplierId() != null) {
                predicates.add(cb.equal(root.get("supplierId"), f.supplierId()));
            }
            if (f.currencyId() != null) {
                predicates.add(cb.equal(root.get("currencyId"), f.currencyId()));
            }
            if (f.settled() != null) {
                predicates.add(cb.equal(root.get("settled"), f.settled()));
            }
            if (f.status() != null) {
                predicates.add(cb.equal(root.get("status"), f.status()));
            }
            if (hasText(f.sourceDocNo())) {
                predicates.add(cb.equal(root.get("sourceDocNo"), f.sourceDocNo()));
            }
            if (f.dateFrom() != null) {
                predicates.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            }
            if (f.dateTo() != null) {
                predicates.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            }
            return cb.and(predicates.toArray(new Predicate[0]));
        };
    }

    private boolean hasText(String value) {
        return value != null && !value.isBlank();
    }

    private ArApLedgerListItem toListItem(ArApLedger ledger) {
        return new ArApLedgerListItem(
                ledger.getId(), ledger.getDirection(), ledger.getSourceDocType(),
                ledger.getSourceDocId(), ledger.getSourceDocNo(), ledger.getBillNo(),
                ledger.getBillDate(), ledger.getClientId(), ledger.getSupplierId(),
                ledger.getCurrencyId(), ledger.getAmountOriginalLocal(),
                ledger.getAmountSettled(), ledger.getAmountBalance(), ledger.isSettled(),
                ledger.getSettledDate(), ledger.getStatus(), ledger.getLegacyBstyle(),
                ledger.getRemark());
    }

    private ArApLedgerDetail toDetail(ArApLedger ledger) {
        return new ArApLedgerDetail(
                ledger.getId(), ledger.getDirection(), ledger.getSourceDocType(),
                ledger.getSourceDocId(), ledger.getSourceDocNo(), ledger.getBillNo(),
                ledger.getBillDate(), ledger.getDueDate(), ledger.getClientId(),
                ledger.getSupplierId(), ledger.getCurrencyId(), ledger.getExchangeRate(),
                ledger.getAmountOriginal(), ledger.getAmountOriginalLocal(),
                ledger.getAmountSettled(), ledger.getAmountBalance(), ledger.isSettled(),
                ledger.getSettledDate(), ledger.getSettlementTypeId(), ledger.getStatus(),
                ledger.getLegacySource(), ledger.getLegacyId(), ledger.getLegacyBstyle(),
                ledger.getRemark());
    }
}
