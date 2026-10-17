package com.uten.imp.features.purchase.order;

import com.uten.imp.application.port.CompanyBrandingReadPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemDto;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.Optional;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class PurchaseOrderPrintServiceTest {
    private final UUID id = UUID.randomUUID(), itemId = UUID.randomUUID(), reviewer = UUID.randomUUID();
    private final PurchaseOrderService orders = mock(PurchaseOrderService.class);
    private final EntityManager em = mock(EntityManager.class);
    private final EmployeeNameResolver names = mock(EmployeeNameResolver.class);
    private final CompanyBrandingReadPort branding = mock(CompanyBrandingReadPort.class);
    private final OrderDetail detail = mock(OrderDetail.class);
    private final OrderItemDto item = mock(OrderItemDto.class);
    private final Query header = mock(Query.class), lines = mock(Query.class), cases = mock(Query.class);
    private final PurchaseOrderPrintService service = new PurchaseOrderPrintService(orders, em, branding, names);

    @BeforeEach void setup() {
        when(orders.detail(id)).thenReturn(detail);
        when(detail.getId()).thenReturn(id);
        when(detail.getStatus()).thenReturn((short) 1);
        var approval = mock(FinanceApproval.class);
        when(approval.status()).thenReturn("APPROVED");
        when(detail.getFinanceApproval()).thenReturn(approval);
        when(detail.getBillNo()).thenReturn("CD-1");
        when(detail.getMakerName()).thenReturn("制单员");
        when(detail.getTotalOriginal()).thenReturn(new BigDecimal("90071992547409.91"));
        when(detail.getItems()).thenReturn(List.of(item));
        when(item.getId()).thenReturn(itemId);
        when(item.getGoodsCodeSnapshot()).thenReturn("FROZEN-1");
        when(item.getGoodsNameSnapshot()).thenReturn("单据冻结名称");
        when(item.getQty()).thenReturn(new BigDecimal("10"));
        when(item.getGiftQty()).thenReturn(new BigDecimal("2"));
        when(item.getQuantitySemantics()).thenReturn("CHARGED_PLUS_GIFT_V1");
        when(item.getPhysicalQtyExact()).thenReturn("12.0000");
        when(branding.currentIdentity()).thenReturn(new CompanyBrandingReadPort.Identity(2, "当前公司", List.of()));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            return sql.contains("procurement_order_approval_cases") ? cases
                    : sql.contains("FROM purchase_order_items") ? lines : header;
        });
        for (Query query : List.of(header, lines, cases)) when(query.setParameter(eq("id"), eq(id))).thenReturn(query);
        when(header.getSingleResult()).thenReturn(new Object[]{"供应商", "联系人", "123", "456", "人民币", "CNY", "月结", "总仓", "A区", "789"});
        when(lines.getResultList()).thenReturn(List.<Object[]>of(new Object[]{itemId, "TODAY", "今天名称", "型号", "规格", "紫铜", "白色", "个"}));
        when(cases.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"APPROVED", reviewer}));
        when(names.nameOf(reviewer)).thenReturn("实际复核员");
    }

    @Test void resolvesFrozenIdentityExactPhysicalQuantityAndActualLatestFinanceReviewer() {
        var document = service.read(id);
        assertThat(document.companyName()).isEqualTo("当前公司");
        assertThat(document.companyPhone()).isEqualTo("789");
        assertThat(document.totalOriginal()).isEqualTo("90071992547409.91");
        assertThat(document.reviewerName()).isEqualTo("实际复核员");
        assertThat(document.lines().getFirst().goodsCode()).isEqualTo("FROZEN-1");
        assertThat(document.lines().getFirst().goodsName()).isEqualTo("单据冻结名称");
        assertThat(document.lines().getFirst().physicalQty()).isEqualTo("12.0000");
        assertThat(document.lines().getFirst().giftQty()).isEqualTo("2");
        assertThat(document.lines().getFirst().material()).isEqualTo("紫铜");
    }

    @Test void maskedCommercialFactsCannotReappearInSupplierPrint() {
        when(detail.isPriceMasked()).thenReturn(true);
        var document = service.read(id);
        assertThat(document.priceMasked()).isTrue();
        assertThat(document.totalOriginal()).isNull();
        assertThat(document.currencyCode()).isEmpty();
        assertThat(document.currencyName()).isEmpty();
        assertThat(document.settlementMethod()).isEmpty();
        assertThat(document.lines()).hasSize(1);
    }

    @Test void pendingReconfirmationNeverPrintsPreviousOrAssignedReviewer() {
        when(detail.getFinanceApproval().status()).thenReturn("PENDING");
        when(cases.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"PENDING", null}));
        var document = service.read(id);
        assertThat(document.reviewerName()).isEmpty();
        assertThat(document.statusLabel()).isEqualTo("改量待财务复核");
        verifyNoInteractions(names);
    }

    @Test void legacyApprovedWithoutFinanceEvidenceLeavesSignatureBlank() {
        when(cases.getResultList()).thenReturn(List.of());
        assertThat(service.read(id).reviewerName()).isEmpty();
        when(detail.getStatus()).thenReturn((short) 0);
        assertThat(service.read(id).reviewerName()).isEmpty();
        verifyNoInteractions(names);
    }

    @Test void ownerDenialStopsBeforeAnyPrintFactQueries() {
        when(orders.detail(id)).thenThrow(new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在"));
        assertThatThrownBy(() -> service.read(id)).isInstanceOf(ApiException.class);
        verifyNoInteractions(em, branding, names);
    }

    @Test void legacyGiftDoesNotGetAddedAgain() {
        when(item.getQuantitySemantics()).thenReturn("LEGACY_RECORDED");
        when(item.getPhysicalQtyExact()).thenReturn("10");
        var document = service.read(id);
        assertThat(document.lines().getFirst().physicalQty()).isEqualTo("10");
        assertThat(document.lines().getFirst().giftQty()).isNull();
    }

    @Test void controllerRecordsAnAuthorizedPrintPreviewUsingTheReadableAuditContract() {
        var audit = mock(AuditService.class);
        var currentUser = mock(SecurityContextCurrentUser.class);
        var actor = mock(AuthUser.class);
        UUID actorId = UUID.randomUUID();
        when(actor.getId()).thenReturn(actorId);
        when(actor.getLoginAccount()).thenReturn("reader");
        when(currentUser.get()).thenReturn(Optional.of(actor));
        var recorder = new AuditDetailViewRecorder(audit, currentUser);
        var controller = new PurchaseOrderController(orders, mock(ProcurementFinanceApprovalService.class), recorder);
        ReflectionTestUtils.setField(controller, "printService", service);
        assertThat(controller.printData(id).id()).isEqualTo(id);
        verify(audit).logSuccessfulDetailView(actorId, "reader", "view_purchase_order_detail",
                "purchase_orders", id, "采购单打印预览", "CD-1", null);
    }
}
