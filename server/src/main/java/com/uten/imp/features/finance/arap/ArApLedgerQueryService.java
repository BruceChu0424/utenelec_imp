package com.uten.imp.features.finance.arap;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.finance.arap.dto.ArApLedgerDetail;
import com.uten.imp.features.finance.arap.dto.ArApLedgerListItem;
import com.uten.imp.features.finance.arap.dto.ArApLedgerQueryFilter;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import jakarta.persistence.criteria.Subquery;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
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
            "amountOriginal", "amountOriginal",
            "amountOriginalLocal", "amountOriginalLocal",
            "amountReceivedOriginal", "amountReceivedOriginal",
            "amountWriteOffOriginal", "amountWriteOffOriginal",
            "amountBalanceOriginal", "amountBalanceOriginal",
            "amountSettled", "amountSettled",
            "amountBalance", "amountBalance");

    private final ArApLedgerRepository repo;
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<ArApLedgerListItem> list(
            ArApLedgerQueryFilter filter, int page, int size, String sort, String order) {
        Specification<ArApLedger> spec = specification(filter);
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<ArApLedger> result = repo.findAll(spec, pageable);
        Map<UUID, LedgerMetadata> metadata = loadMetadata(
                result.getContent().stream().map(ArApLedger::getId).toList());
        return new PageResponse<>(
                result.getContent().stream()
                        .map(ledger -> toListItem(
                                ledger, metadata.getOrDefault(ledger.getId(), LedgerMetadata.EMPTY)))
                        .toList(),
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
        LedgerMetadata metadata = loadMetadata(List.of(id))
                .getOrDefault(id, LedgerMetadata.EMPTY);
        return toDetail(ledger, metadata);
    }

    private Specification<ArApLedger> specification(ArApLedgerQueryFilter f) {
        return (Root<ArApLedger> root, jakarta.persistence.criteria.CriteriaQuery<?> query,
                CriteriaBuilder cb) -> {
            List<Predicate> predicates = new ArrayList<>();
            predicates.add(cb.isFalse(root.get("deleted")));
            if (hasText(f.keyword())) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                Subquery<Integer> sourceMatch = query.subquery(Integer.class);
                Root<ArApSourceRef> source = sourceMatch.from(ArApSourceRef.class);
                sourceMatch.select(cb.literal(1)).where(
                        cb.equal(source.get("ledgerId"), root.get("id")),
                        cb.like(cb.lower(source.get("sourceNo")), like));
                predicates.add(cb.or(
                        cb.like(cb.lower(root.get("billNo")), like),
                        cb.like(cb.lower(root.get("sourceDocNo")), like),
                        cb.exists(sourceMatch)));
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

    private ArApLedgerListItem toListItem(ArApLedger ledger, LedgerMetadata metadata) {
        SettlementAmounts settlement = settlementAmounts(ledger);
        return new ArApLedgerListItem(
                ledger.getId(), ledger.getDirection(), ledger.getSourceDocType(),
                ledger.getSourceDocId(), ledger.getSourceDocNo(), ledger.getBillNo(),
                ledger.getBillDate(), ledger.getClientId(), ledger.getSupplierId(),
                ledger.getCurrencyId(), ledger.getAmountOriginalLocal(),
                ledger.getAmountSettled(), ledger.getAmountBalance(), ledger.isSettled(),
                ledger.getSettledDate(), ledger.getStatus(), ledger.getLegacyBstyle(),
                ledger.getRemark(), metadata.clientName(), metadata.supplierName(),
                metadata.currencyCode(), metadata.currencyName(), ledger.getExchangeRate(),
                ledger.getAmountOriginal(), settlement.receivedOriginal(),
                settlement.receivedLocal(), settlement.writeOffOriginal(),
                settlement.writeOffLocal(), settlement.balanceOriginal(),
                ledger.getDueDate(), ledger.getSettlementStyleLegacy(),
                metadata.salesOrderNos());
    }

    private ArApLedgerDetail toDetail(ArApLedger ledger, LedgerMetadata metadata) {
        SettlementAmounts settlement = settlementAmounts(ledger);
        return new ArApLedgerDetail(
                ledger.getId(), ledger.getDirection(), ledger.getSourceDocType(),
                ledger.getSourceDocId(), ledger.getSourceDocNo(), ledger.getBillNo(),
                ledger.getBillDate(), ledger.getDueDate(), ledger.getClientId(),
                ledger.getSupplierId(), ledger.getCurrencyId(), ledger.getExchangeRate(),
                ledger.getAmountOriginal(), ledger.getAmountOriginalLocal(),
                ledger.getAmountSettled(), ledger.getAmountBalance(), ledger.isSettled(),
                ledger.getSettledDate(), ledger.getSettlementTypeId(), ledger.getStatus(),
                ledger.getLegacySource(), ledger.getLegacyId(), ledger.getLegacyBstyle(),
                ledger.getRemark(), metadata.clientName(), metadata.supplierName(),
                metadata.currencyCode(), metadata.currencyName(),
                settlement.receivedOriginal(), settlement.receivedLocal(),
                settlement.writeOffOriginal(), settlement.writeOffLocal(),
                settlement.balanceOriginal(), ledger.getSettlementStyleLegacy(),
                metadata.salesOrderNos());
    }

    /**
     * V236 only upgrades the sales-receipt (AR) settlement model.  Purchase
     * payments still maintain the legacy local-currency settled/balance
     * columns, so exposing the new receipt-only split for AP would fabricate
     * zero paid amounts.  Keep AP on its existing authoritative local facts
     * and leave unsupported original-currency split values explicitly null.
     */
    private SettlementAmounts settlementAmounts(ArApLedger ledger) {
        if ("AR".equalsIgnoreCase(ledger.getDirection())) {
            return new SettlementAmounts(
                    ledger.getAmountReceivedOriginal(),
                    ledger.getAmountReceivedLocal(),
                    ledger.getAmountWriteOffOriginal(),
                    ledger.getAmountWriteOffLocal(),
                    ledger.getAmountBalanceOriginal());
        }
        return new SettlementAmounts(
                null,
                ledger.getAmountSettled(),
                null,
                BigDecimal.ZERO,
                null);
    }

    @SuppressWarnings("unchecked")
    private Map<UUID, LedgerMetadata> loadMetadata(Collection<UUID> ledgerIds) {
        if (ledgerIds == null || ledgerIds.isEmpty()) {
            return Map.of();
        }
        List<Object[]> rows = em.createNativeQuery("""
                SELECT ledger.id,
                       client.name,
                       supplier.name,
                       currency.code,
                       currency.name,
                       COALESCE(string_agg(
                           DISTINCT source.source_no,
                           chr(31) ORDER BY source.source_no), '') AS sales_order_nos
                FROM ar_ap_ledger ledger
                LEFT JOIN clients client ON client.id = ledger.client_id
                LEFT JOIN suppliers supplier ON supplier.id = ledger.supplier_id
                LEFT JOIN currencies currency ON currency.id = ledger.currency_id
                LEFT JOIN ar_ap_source_refs source
                  ON source.ledger_id = ledger.id
                 AND source.source_type = 'SALES_ORDER'
                WHERE ledger.id IN (:ledgerIds)
                GROUP BY ledger.id, client.name, supplier.name, currency.code, currency.name
                """)
                .setParameter("ledgerIds", ledgerIds)
                .getResultList();
        Map<UUID, LedgerMetadata> result = new HashMap<>();
        for (Object[] row : rows) {
            String joined = row[5] == null ? "" : String.valueOf(row[5]);
            List<String> orderNos = joined.isBlank()
                    ? List.of()
                    : List.of(joined.split("\u001f", -1));
            result.put((UUID) row[0], new LedgerMetadata(
                    (String) row[1], (String) row[2], (String) row[3], (String) row[4],
                    orderNos));
        }
        return result;
    }

    private record LedgerMetadata(
            String clientName,
            String supplierName,
            String currencyCode,
            String currencyName,
            List<String> salesOrderNos) {
        private static final LedgerMetadata EMPTY = new LedgerMetadata(
                null, null, null, null, List.of());
    }

    private record SettlementAmounts(
            BigDecimal receivedOriginal,
            BigDecimal receivedLocal,
            BigDecimal writeOffOriginal,
            BigDecimal writeOffLocal,
            BigDecimal balanceOriginal) {
    }
}
