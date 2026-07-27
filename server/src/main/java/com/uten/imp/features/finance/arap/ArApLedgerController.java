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
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 应收应付台账 API（钱流管理 · 只读查询）。
 *
 * <p>立帐 / 反立帐由销售/采购/委外审核 Service 跨模块调用 {@link ArApLedgerService}，
 * 不暴露 POST/DELETE 端点（用户不直接编辑台账）。
 *
 * <ul>
 *   <li>GET /api/finance/ar-ap?direction=&sourceDocType=&partyId=&settled=&dateFrom=&dateTo=&page=&size= → 分页</li>
 *   <li>GET /api/finance/ar-ap/{id} → 详情</li>
 * </ul>
 *
 * <p>权限：{@code ar_ap_ledger:view}（V57 种子化，view 给所有部门）。
 */
@RestController
@RequestMapping("/api/finance/ar-ap")
@RequiredArgsConstructor
public class ArApLedgerController {

    private final ArApLedgerRepository repo;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate",
            "amountOriginalLocal", "amountOriginalLocal",
            "amountSettled", "amountSettled",
            "amountBalance", "amountBalance");

    @GetMapping
    @PreAuthorize("hasAuthority('ar_ap_ledger:view')")
    public PageResponse<ArApLedgerListItem> list(
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String direction,
            @RequestParam(required = false) String sourceDocType,
            @RequestParam(required = false) UUID partyId,
            @RequestParam(required = false) UUID clientId,
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) UUID currencyId,
            @RequestParam(required = false) Boolean settled,
            @RequestParam(required = false) Short status,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(required = false) String sourceDocNo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) String order) {
        ArApLedgerQueryFilter f = new ArApLedgerQueryFilter(
                keyword, direction, sourceDocType, partyId, clientId, supplierId, currencyId,
                settled, status, dateFrom, dateTo, sourceDocNo);
        Specification<ArApLedger> spec = (Root<ArApLedger> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                          CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("billNo")), like),
                        cb.like(cb.lower(root.get("sourceDocNo")), like)));
            }
            if (f.direction() != null && !f.direction().isBlank()) ps.add(cb.equal(root.get("direction"), f.direction()));
            if (f.sourceDocType() != null && !f.sourceDocType().isBlank()) ps.add(cb.equal(root.get("sourceDocType"), f.sourceDocType()));
            if (f.partyId() != null) {
                // 智能匹配：AR→client_id, AP→supplier_id；若同时给 direction 精确，否则 OR 两边
                if ("AR".equals(f.direction())) ps.add(cb.equal(root.get("clientId"), f.partyId()));
                else if ("AP".equals(f.direction())) ps.add(cb.equal(root.get("supplierId"), f.partyId()));
                else ps.add(cb.or(
                        cb.equal(root.get("clientId"), f.partyId()),
                        cb.equal(root.get("supplierId"), f.partyId())));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.supplierId() != null) ps.add(cb.equal(root.get("supplierId"), f.supplierId()));
            if (f.currencyId() != null) ps.add(cb.equal(root.get("currencyId"), f.currencyId()));
            if (f.settled() != null) ps.add(cb.equal(root.get("settled"), f.settled()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.sourceDocNo() != null && !f.sourceDocNo().isBlank()) ps.add(cb.equal(root.get("sourceDocNo"), f.sourceDocNo()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<ArApLedger> p = repo.findAll(spec, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('ar_ap_ledger:view')")
    public ArApLedgerDetail detail(@PathVariable UUID id) {
        ArApLedger l = repo.findById(id)
                .filter(x -> !x.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "应收应付记录不存在"));
        return toDetail(l);
    }

    private ArApLedgerListItem toList(ArApLedger l) {
        return new ArApLedgerListItem(
                l.getId(), l.getDirection(), l.getSourceDocType(), l.getSourceDocId(), l.getSourceDocNo(),
                l.getBillNo(), l.getBillDate(), l.getClientId(), l.getSupplierId(), l.getCurrencyId(),
                l.getAmountOriginalLocal(), l.getAmountSettled(), l.getAmountBalance(),
                l.isSettled(), l.getSettledDate(), l.getStatus(), l.getLegacyBstyle(), l.getRemark());
    }

    private ArApLedgerDetail toDetail(ArApLedger l) {
        return new ArApLedgerDetail(
                l.getId(), l.getDirection(), l.getSourceDocType(), l.getSourceDocId(), l.getSourceDocNo(),
                l.getBillNo(), l.getBillDate(), l.getDueDate(), l.getClientId(), l.getSupplierId(),
                l.getCurrencyId(), l.getExchangeRate(), l.getAmountOriginal(), l.getAmountOriginalLocal(),
                l.getAmountSettled(), l.getAmountBalance(), l.isSettled(), l.getSettledDate(),
                l.getSettlementTypeId(), l.getStatus(), l.getLegacySource(), l.getLegacyId(),
                l.getLegacyBstyle(), l.getRemark());
    }
}
