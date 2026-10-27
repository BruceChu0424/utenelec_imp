package com.uten.imp.features.subcontract.order;

import com.uten.imp.application.port.CompanyBrandingReadPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.order.dto.OrderDetail;
import com.uten.imp.features.subcontract.order.dto.OrderItemDto;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
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

class SubcontractOrderPrintServiceTest {
    private final UUID id = UUID.randomUUID(), itemId = UUID.randomUUID(), reviewer = UUID.randomUUID();
    private final SubcontractOrderService orders = mock(SubcontractOrderService.class);
    private final EntityManager em = mock(EntityManager.class);
    private final EmployeeNameResolver names = mock(EmployeeNameResolver.class);
    private final CompanyBrandingReadPort branding = mock(CompanyBrandingReadPort.class);
    private final OrderDetail detail = mock(OrderDetail.class);
    private final OrderItemDto item = mock(OrderItemDto.class);
    private final Query header = mock(Query.class), lines = mock(Query.class), cases = mock(Query.class);
    private final SubcontractOrderPrintService service = new SubcontractOrderPrintService(orders, em, branding, names);

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
        
        
        
        when(branding.currentIdentity()).thenReturn(new CompanyBrandingReadPort.Identity(2, "当前公司", List.of()));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            return sql.contains("procurement_order_approval_cases") ? cases
                    : sql.contains("FROM subcontract_order_items") ? lines : header;
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
        assertThat(document.financeApproved()).isTrue();
        assertThat(document.lines().getFirst().goodsCode()).isEqualTo("FROZEN-1");
        assertThat(document.lines().getFirst().goodsName()).isEqualTo("单据冻结名称");
        assertThat(document.lines().getFirst().physicalQty()).isEqualTo("10");
        assertThat(document.lines().getFirst().giftQty()).isNull();
        assertThat(document.orderType()).isEqualTo("SUBCONTRACT");
        assertThat(document.lines().getFirst().material()).isEqualTo("紫铜");
    }

    @Test void terminatedHistoryPrintKeepsCommercialApprovalAndSignatureWhileClearlyMarkingTheOrderEnded() {
        when(detail.getClosureRequest()).thenReturn(new com.uten.imp.application.port.ProcurementOrderClosureReadPort.ClosureRequestView(
                UUID.randomUUID(),"APPROVED","CLOSE","供应商停止供货",null,null,null,null));

        var document=service.read(id);

        assertThat(document.statusLabel()).isEqualTo("已结束(历史财务批准)");
        assertThat(document.financeApproved()).isTrue();
        assertThat(document.reviewerName()).isEqualTo("实际复核员");
        assertThat(document.totalOriginal()).isEqualTo("90071992547409.91");
        verify(em).createNativeQuery(contains("request_type='ORDER'"));
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

    @Test void pendingReconfirmationCanExportCurrentFactsWithoutAnApprovalSignature() {
        when(detail.getFinanceApproval().status()).thenReturn("PENDING");
        var document = service.read(id);
        assertThat(document.financeApproved()).isFalse();
        assertThat(document.statusLabel()).isEqualTo("改量待财务复核");
        assertThat(document.reviewerName()).isEmpty();
        assertThat(document.lines()).hasSize(1);
        verifyNoInteractions(names);
        verify(em, never()).createNativeQuery(contains("procurement_order_approval_cases"));
    }

    @ParameterizedTest
    @CsvSource({"0,DRAFT", "0,PENDING", "0,REJECTED", "1,REJECTED",
            "1,LEGACY_EFFECTIVE", "-1,APPROVED", "2,APPROVED", "0,APPROVED"})
    void readableUnapprovedOrInactiveDocumentsKeepTheirRealStatusAndBlankFinanceSignature(short status, String financeStatus) {
        when(detail.getStatus()).thenReturn(status);
        when(detail.getFinanceApproval().status()).thenReturn(financeStatus);
        var document = service.read(id);
        assertThat(document.financeApproved()).isFalse();
        assertThat(document.reviewerName()).isEmpty();
        assertThat(document.contentDigest()).matches("[a-f0-9]{64}");
        verifyNoInteractions(names);
    }

    @Test void missingFinanceProjectionPrintsReadableHistoricalFactsWithoutInventingApproval() {
        when(detail.getFinanceApproval()).thenReturn(null);
        var document = service.read(id);
        assertThat(document.financeApproved()).isFalse();
        assertThat(document.statusLabel()).isEqualTo("历史已审");
        assertThat(document.reviewerName()).isEmpty();
    }

    @Test void missingOrderStatusNeverInventsAnApprovalSignature() {
        when(detail.getStatus()).thenReturn(null);
        var document = service.read(id);
        assertThat(document.financeApproved()).isFalse();
        assertThat(document.reviewerName()).isEmpty();
    }

    @Test void approvedWithoutRecordedReviewerLeavesSignatureBlank() {
        when(cases.getResultList()).thenReturn(List.of());
        assertThat(service.read(id).reviewerName()).isEmpty();
        verifyNoInteractions(names);
    }

    @Test void ownerDenialStopsBeforeAnyPrintFactQueries() {
        when(orders.detail(id)).thenThrow(new ApiException(ErrorCode.NOT_FOUND, "采购订货单不存在"));
        assertThatThrownBy(() -> service.read(id)).isInstanceOf(ApiException.class);
        verifyNoInteractions(em, branding, names);
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
        var controller = new SubcontractOrderController(orders, mock(ProcurementFinanceApprovalService.class), mock(SubcontractOrderProgressService.class), recorder);
        ReflectionTestUtils.setField(controller, "printService", service);
        assertThat(controller.printData(id).id()).isEqualTo(id);
        verify(audit).logSuccessfulDetailView(actorId, "reader", "view_subcontract_order_detail",
                "subcontract_orders", id, "委外单打印预览", "CD-1", null);
    }

    @Test void controllerRecordsTheCurrentPendingPrintWithoutAdvancingFinance() {
        var recorder = mock(AuditDetailViewRecorder.class);
        var controller = new SubcontractOrderController(orders, mock(ProcurementFinanceApprovalService.class), mock(SubcontractOrderProgressService.class), recorder);
        ReflectionTestUtils.setField(controller, "printService", service);
        when(detail.getFinanceApproval().status()).thenReturn("PENDING");
        var document = controller.printData(id);
        assertThat(document.financeApproved()).isFalse();
        assertThat(document.reviewerName()).isEmpty();
        verify(recorder).record("view_subcontract_order_detail", "subcontract_orders", id, "CD-1", null, "委外单打印预览");
    }

}
