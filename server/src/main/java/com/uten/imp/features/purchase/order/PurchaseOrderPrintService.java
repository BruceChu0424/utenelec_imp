package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.CompanyBrandingReadPort;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** A supplier-facing print snapshot, authorized by the same document policy as detail. */
@Service
@RequiredArgsConstructor
public class PurchaseOrderPrintService {
    private final PurchaseOrderService orders;
    private final EntityManager em;
    private final CompanyBrandingReadPort branding;
    private final EmployeeNameResolver employeeNames;

    @PreAuthorize("hasAnyAuthority('purchase_order:view','finance_order_approval:view')")
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public PrintDocument read(UUID id) {
        // Resolve owner visibility before querying any supplier, employee or commercial facts.
        OrderDetail detail = orders.detail(id);
        // The latest case governs the current revision, including quantity reconfirmation.
        // A historical effective status alone is not evidence of finance approval.
        if (detail.getStatus() == null || detail.getStatus() != 1
                || detail.getFinanceApproval() == null
                || !"APPROVED".equals(detail.getFinanceApproval().status())) {
            throw new ApiException(ErrorCode.BUSINESS, "仅财务审核通过的采购单可导出单据");
        }
        Object[] header = (Object[]) em.createNativeQuery("""
                SELECT s.name, s.linkman, s.phone, s.mobile,
                       c.name, c.code, sm.name, w.name, w.location,
                       (SELECT support_phone FROM platform_branding WHERE id = 1)
                FROM purchase_orders o
                LEFT JOIN suppliers s ON s.id = o.supplier_id
                LEFT JOIN currencies c ON c.id = o.currency_id
                LEFT JOIN settlement_methods sm ON sm.id = o.settlement_method_id
                LEFT JOIN warehouses w ON w.id = o.warehouse_id
                WHERE o.id = :id
                """).setParameter("id", id).getSingleResult();
        Map<UUID, Object[]> descriptions = new LinkedHashMap<>();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT i.id, g.code, g.name, g.model, g.spec, g.material, c.name, u.name
                FROM purchase_order_items i
                LEFT JOIN goods g ON g.id = i.goods_id
                LEFT JOIN colors c ON c.id = i.color_id
                LEFT JOIN units u ON u.id = i.unit_id
                WHERE i.order_id = :id
                ORDER BY i.line_no, i.id
                """).setParameter("id", id).getResultList();
        rows.forEach(row -> descriptions.put((UUID) row[0], row));
        List<PrintLine> lines = detail.getItems().stream().map(item -> {
            Object[] goods = descriptions.get(item.getId());
            if (goods == null) throw new ApiException(ErrorCode.CONFLICT, "采购明细已变化，请刷新后重试打印");
            return line(item, goods);
        }).toList();
        String reviewerName = approvedReviewer(detail);
        boolean masked = detail.isPriceMasked();
        return new PrintDocument(detail.getId(), text(detail.getBillNo()), detail.getBillDate(),
                detail.getDeliverDate(), branding.currentIdentity().companyName(), text(header[9]),
                text(header[0]), text(header[1]), first(text(header[2]), text(header[3])),
                join(text(header[7]), text(header[8])), masked ? "" : text(header[4]),
                masked ? "" : text(header[5]), masked ? "" : text(header[6]),
                masked ? null : decimal(detail.getTotalOriginal()), masked,
                text(detail.getRemark()), text(detail.getMakerName()), reviewerName,
                status(detail), lines);
    }

    private String approvedReviewer(OrderDetail detail) {
        if (detail.getStatus() == null || detail.getStatus() != 1) return "";
        // A reconfirmation may be decided by a different finance employee than the first approval.
        // Never print the assigned reviewer or an earlier approval against an unreviewed revision.
        @SuppressWarnings("unchecked")
        List<Object[]> cases = em.createNativeQuery("""
                SELECT status, decided_by_employee_id
                FROM procurement_order_approval_cases
                WHERE order_type = 'PURCHASE' AND order_id = :id
                ORDER BY attempt DESC LIMIT 1
                """).setParameter("id", detail.getId()).getResultList();
        if (cases.isEmpty()) return ""; // Legacy audit identity is not evidence of a finance decision.
        Object[] latest = cases.getFirst();
        if (!"APPROVED".equals(latest[0]) || latest[1] == null) return "";
        return text(employeeNames.nameOf((UUID) latest[1]));
    }

    static PrintLine line(OrderItemDto item, Object[] goods) {
        return new PrintLine(item.getId(), item.getLineNo(),
                first(text(item.getGoodsCodeSnapshot()), text(goods[1])),
                first(text(item.getGoodsNameSnapshot()), text(goods[2])),
                text(goods[3]), text(goods[4]), text(goods[6]), text(goods[7]),
                item.getPhysicalQtyExact(), decimal(item.getQty()),
                com.uten.imp.common.finance.ProcurementQuantities.isExtraGift(item.getQuantitySemantics())
                        ? decimal(item.getGiftQty()) : null,
                text(goods[5]), text(item.getRemark()), item.getDeliverDate());
    }

    static String status(OrderDetail detail) {
        if (detail.getStatus() != null && detail.getStatus() == 2) return "已取消";
        if (detail.getStatus() != null && detail.getStatus() == -1) return "已反审";
        String finance = detail.getFinanceApproval() == null ? "" : detail.getFinanceApproval().status();
        return switch (finance) {
            case "PENDING" -> detail.getStatus() != null && detail.getStatus() == 1 ? "改量待财务复核" : "等待财务审核";
            case "REJECTED" -> "财务退回";
            case "APPROVED" -> "财务已通过";
            default -> detail.getStatus() != null && detail.getStatus() == 1 ? "历史已审" : "草稿";
        };
    }

    private static String decimal(BigDecimal value) { return value == null ? null : value.toPlainString(); }
    private static String text(Object value) { return value == null ? "" : value.toString().trim(); }
    private static String first(String primary, String fallback) { return primary.isBlank() ? fallback : primary; }
    private static String join(String first, String second) { return second.isBlank() ? first : first + " " + second; }

    public record PrintDocument(UUID id, String billNo, LocalDate billDate, LocalDate deliverDate,
            String companyName, String companyPhone, String supplierName, String supplierContact,
            String supplierPhone, String deliveryPlace, String currencyName, String currencyCode,
            String settlementMethod, String totalOriginal, boolean priceMasked, String remark,
            String makerName, String reviewerName, String statusLabel, List<PrintLine> lines) {}

    public record PrintLine(UUID id, Integer lineNo, String goodsCode, String goodsName,
            String model, String spec, String colorName, String unitName, String physicalQty,
            String chargedQty, String giftQty, String material, String remark, LocalDate deliverDate) {}
}
