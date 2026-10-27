package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.CompanyBrandingReadPort;
import com.uten.imp.common.export.ProcurementOrderPrintDocument;
import com.uten.imp.common.export.ProcurementOrderPrintDocument.PrintLine;
import com.uten.imp.common.export.ProcurementOrderPrintSupport;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;
import static com.uten.imp.common.export.ProcurementOrderPrintSupport.*;

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
    public ProcurementOrderPrintDocument read(UUID id) {
        OrderDetail detail = orders.detail(id);
        var facts = ProcurementOrderPrintSupport.read(em, branding, employeeNames,
                ProcurementOrderPrintSupport.Domain.PURCHASE, id, commerciallyApproved(detail));
        Object[] header = facts.header();
        List<PrintLine> lines = detail.getItems().stream()
                .map(item -> line(item, ProcurementOrderPrintSupport.line(facts, item.getId()))).toList();
        boolean masked = detail.isPriceMasked();
        return new ProcurementOrderPrintDocument(detail.getId(), text(detail.getBillNo()), detail.getBillDate(),
                detail.getDeliverDate(), facts.companyName(), text(header[9]),
                text(header[0]), text(header[1]), first(text(header[2]), text(header[3])),
                join(text(header[7]), text(header[8])), masked ? "" : text(header[4]),
                masked ? "" : text(header[5]), masked ? "" : text(header[6]),
                masked ? null : decimal(detail.getTotalOriginal()), masked,
                text(detail.getRemark()), text(detail.getMakerName()), facts.reviewerName(),
                status(detail), lines, commerciallyApproved(detail), "PURCHASE");
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
        var closure = detail.getClosureRequest();
        String label = ProcurementOrderPrintSupport.status(detail.getStatus(),
                detail.getFinanceApproval() == null ? null : detail.getFinanceApproval().status(),
                closure == null ? null : closure.status(), closure == null ? null : closure.executionMode());
        return "已结束(取消剩余)".equals(label) ? "已结束(采购取消剩余)" : label;
    }

    static boolean commerciallyApproved(OrderDetail detail) {
        return financeApproved(detail.getStatus(),
                detail.getFinanceApproval() == null ? null : detail.getFinanceApproval().status());
    }
}
