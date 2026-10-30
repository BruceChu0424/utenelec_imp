package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.CompanyBrandingReadPort;
import com.uten.imp.common.export.ProcurementOrderPrintDocument;
import com.uten.imp.common.export.ProcurementOrderPrintDocument.PrintLine;
import com.uten.imp.common.export.ProcurementOrderPrintSupport;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.subcontract.order.dto.OrderItemDto;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.util.UUID;
import static com.uten.imp.common.export.ProcurementOrderPrintSupport.*;

/** Exports current readable order facts without advancing approval or material issue workflows. */
@Service
@RequiredArgsConstructor
public class SubcontractOrderPrintService {
    private final SubcontractOrderService orders;
    private final EntityManager em;
    private final CompanyBrandingReadPort branding;
    private final EmployeeNameResolver employeeNames;

    @PreAuthorize("hasAnyAuthority('subcontract_order:view','finance_order_approval:view')")
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ProcurementOrderPrintDocument read(UUID id) {
        var detail = orders.detail(id);
        String finance = detail.getFinanceApproval() == null ? null : detail.getFinanceApproval().status();
        boolean approved = financeApproved(detail.getStatus(), finance);
        var facts = ProcurementOrderPrintSupport.read(em, branding, employeeNames, Domain.SUBCONTRACT, id, approved);
        Object[] header = facts.header();
        var lines = detail.getItems().stream()
                .map(item -> line(item, ProcurementOrderPrintSupport.line(facts, item.getId()))).toList();
        boolean masked = detail.isPriceMasked();
        var closure = detail.getClosureRequest();
        String label = status(detail.getStatus(), finance, closure == null ? null : closure.status(),
                closure == null ? null : closure.executionMode());
        // 2026-10-30 用户口径: 委外订货单打印同时给委外成品与委外物料(直属物料)及
        // 对应关系(物料行指向成品行号), 不能只打印成品。
        var materials = detail.getMaterials() == null ? java.util.List.<ProcurementOrderPrintDocument.MaterialLine>of()
                : detail.getMaterials().stream().map(line -> new ProcurementOrderPrintDocument.MaterialLine(
                        line.orderItemId(), line.orderLineNo(), line.goodsCode(), line.goodsName(),
                        line.colorName(), line.unitName(), line.bomUnitQty(), line.plannedQty())).toList();
        return new ProcurementOrderPrintDocument(detail.getId(), text(detail.getBillNo()), detail.getBillDate(),
                detail.getDeliverDate(), facts.companyName(), text(header[9]), text(header[0]), text(header[1]),
                first(text(header[2]), text(header[3])), join(text(header[7]), text(header[8])),
                masked ? "" : text(header[4]), masked ? "" : text(header[5]), masked ? "" : text(header[6]),
                masked ? null : decimal(detail.getTotalOriginal()), masked, text(detail.getRemark()),
                text(detail.getMakerName()), facts.reviewerName(), label, lines, approved, "SUBCONTRACT", materials);
    }

    static PrintLine line(OrderItemDto item, Object[] goods) {
        // Subcontract quantity is the actual ordered finished quantity; purchase gift semantics do not apply.
        return new PrintLine(item.getId(), item.getLineNo(),
                first(text(item.getGoodsCodeSnapshot()), text(goods[1])),
                first(text(item.getGoodsNameSnapshot()), text(goods[2])), text(goods[3]), text(goods[4]),
                text(goods[6]), text(goods[7]), decimal(item.getQty()), decimal(item.getQty()), null,
                text(goods[5]), text(item.getRemark()), item.getDeliverDate());
    }
}
