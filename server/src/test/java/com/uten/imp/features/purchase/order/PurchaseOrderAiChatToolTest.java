package com.uten.imp.features.purchase.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.features.purchase.PurchaseDocumentAccessPolicy;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

/**
 * Pure rules of the purchase order status tool: which fact decides the status, number shape, neutral reply and the
 * detail-view audit (one record per successful read, none for a refused or unknown number or a re-check).
 */
class PurchaseOrderAiChatToolTest {
    private static final BigDecimal NONE = BigDecimal.ZERO;
    private static final BigDecimal SOME = BigDecimal.ONE;

    @Test
    void statusFollowsTheGoodsInTheOrderTheyMove() {
        LocalDate due = LocalDate.of(2026, 10, 13);
        assertThat(PurchaseOrderAiChatTool.state((short) 0, false, null, NONE, NONE, NONE, false, false, due)[0]).isEqualTo("草稿");
        assertThat(PurchaseOrderAiChatTool.state((short) 0, false, "PENDING", NONE, NONE, NONE, false, false, due)[0])
                .isEqualTo("财务审批中");
        assertThat(PurchaseOrderAiChatTool.state((short) 0, false, "REJECTED", NONE, NONE, NONE, false, false, due)[1])
                .contains("等采购修改后重新提交").doesNotContain("原因：");
        assertThat(PurchaseOrderAiChatTool.state((short) 1, false, "APPROVED", NONE, NONE, NONE, false, false, due)[1])
                .isEqualTo("财务已批准，等供应商送货，交货日期 2026-10-13。");
        assertThat(PurchaseOrderAiChatTool.state((short) 1, false, null, NONE, NONE, NONE, true, false, due)[0]).isEqualTo("部分到货");
        assertThat(PurchaseOrderAiChatTool.state((short) 1, false, null, NONE, NONE, SOME, true, true, due)[0]).isEqualTo("合格待入库");
        assertThat(PurchaseOrderAiChatTool.state((short) 1, false, null, NONE, SOME, SOME, true, true, due)[0]).isEqualTo("待品质检验");
        assertThat(PurchaseOrderAiChatTool.state((short) 1, true, null, SOME, SOME, SOME, true, true, due)[0])
                .as("over-receipt held for finance comes first").isEqualTo("到货超量待财务判定");
        assertThat(PurchaseOrderAiChatTool.state((short) 1, true, null, NONE, NONE, NONE, true, true, due)[0]).isEqualTo("已结案");
        assertThat(PurchaseOrderAiChatTool.state((short) -1, false, null, NONE, NONE, NONE, false, false, due)[0]).isEqualTo("已红冲");
        assertThat(PurchaseOrderAiChatTool.state((short) 2, false, null, NONE, NONE, NONE, false, false, due)[0]).isEqualTo("已取消");
    }

    @Test
    void numberShapeAndNeutralReply() {
        assertThat(PurchaseOrderAiChatTool.orderNo(Map.of("orderNo", "cd20261006000001"))).isEqualTo("CD20261006000001");
        assertThatThrownBy(() -> PurchaseOrderAiChatTool.orderNo(Map.of("orderNo", "CD-1 OR 1=1")))
                .isInstanceOf(ApiException.class);
        assertThat(PurchaseOrderAiChatTool.NOT_FOUND).isEqualTo("没有找到你能查看的这张单据。请核对单号是否完整、有没有输错；"
                + "如果这张单不在你的查看范围内(比如由别的同事负责)，这里同样查不到，可以请负责的同事或主管查看。");
    }

    @Test
    void aFoundOrderLeavesTheDetailPageViewRecordOnceAndAReCheckLeavesNone() {
        Fixture fixture = new Fixture();
        UUID orderId = fixture.order("CD20261006000001", true, 86);

        Map<String, Object> result = fixture.tool.execute(Map.of("orderNo", "cd20261006000001"));
        assertThat((String) result.get("reply")).contains("采购订货单 CD20261006000001", "财务已批准");
        // The detail page's own action, object table, bill number and legacy id; the label marks the AI source.
        verify(fixture.audit).record("view_purchase_order_detail", "purchase_orders", orderId, "CD20261006000001", 86,
                "采购订货单(AI 助手查询)");

        Map<String, Object> evidence = evidence(result);
        fixture.tool.authorizeResultRead(evidence);
        verifyNoMoreInteractions(fixture.audit);
    }

    @Test
    void aPendingFinanceReviewerSeesTheOrderAndLeavesTheSameViewRecord() {
        Fixture fixture = new Fixture();
        UUID orderId = fixture.order("CD20261006000002", false, null);
        when(fixture.approvals.canCurrentActorReviewPending("PURCHASE", orderId)).thenReturn(true);
        fixture.tool.execute(Map.of("orderNo", "CD20261006000002"));
        verify(fixture.audit).record("view_purchase_order_detail", "purchase_orders", orderId, "CD20261006000002", null,
                "采购订货单(AI 助手查询)");
    }

    @Test
    void unknownOrOutOfScopeNumbersAndAMissingPermissionLeaveNoViewRecord() {
        Fixture fixture = new Fixture();
        fixture.order("CD20261006000003", false, null);
        Map<String, Object> hidden = fixture.tool.execute(Map.of("orderNo", "CD20261006000003"));
        Map<String, Object> unknown = fixture.tool.execute(Map.of("orderNo", "CD20991231999999"));
        assertThat(hidden.get("reply")).isEqualTo(PurchaseOrderAiChatTool.NOT_FOUND).isEqualTo(unknown.get("reply"));
        // The object rule runs before anything of the hidden order is read.
        verify(fixture.orders, never()).detail(any());

        when(fixture.reader.getPermissions()).thenReturn(Set.of());
        assertThatThrownBy(() -> fixture.tool.execute(Map.of("orderNo", "CD20261006000003")))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        verifyNoInteractions(fixture.audit);
    }

    @Test
    void aViewThatCannotBeRecordedAnswersNothing() {
        Fixture fixture = new Fixture();
        fixture.order("CD20261006000004", true, null);
        doThrow(new IllegalStateException("Authenticated detail viewer is missing"))
                .when(fixture.audit).record(any(), any(), any(), any(), any(), any());
        assertThatThrownBy(() -> fixture.tool.execute(Map.of("orderNo", "CD20261006000004")))
                .isInstanceOf(IllegalStateException.class);
    }

    /** The tool's own evidence map, copied with typed keys (no unchecked cast). */
    private static Map<String, Object> evidence(Map<String, Object> result) {
        Map<String, Object> evidence = new java.util.HashMap<>();
        ((Map<?, ?>) result.get("_toolEvidence")).forEach((key, value) -> evidence.put((String) key, value));
        return evidence;
    }

    /** The tool over mocked reads: a purchase reader with the order view permission. */
    private static final class Fixture {
        final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final AuthUser reader = mock(AuthUser.class);
        final PurchaseDocumentAccessPolicy documents = mock(PurchaseDocumentAccessPolicy.class);
        final ProcurementApprovalProjectionQuery approvals = mock(ProcurementApprovalProjectionQuery.class);
        final PurchaseOrderService orders = mock(PurchaseOrderService.class);
        final JdbcTemplate jdbc = mock(JdbcTemplate.class);
        final AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);
        final PurchaseOrderAiChatTool tool = new PurchaseOrderAiChatTool(access, current, documents, approvals, orders,
                jdbc, new ObjectMapper(), Clock.fixed(Instant.parse("2026-10-06T01:00:00Z"), ZoneOffset.UTC), audit);

        Fixture() {
            when(access.hasDomain("PURCHASE")).thenReturn(true);
            when(reader.getPermissions()).thenReturn(Set.of("purchase_order:view"));
            when(current.get()).thenReturn(Optional.of(reader));
        }

        /** An approved order with no lines, visible through the owner scope or not. */
        UUID order(String billNo, boolean ownerScope, Integer legacyId) {
            UUID orderId = UUID.randomUUID();
            UUID maker = UUID.randomUUID();
            when(jdbc.queryForList(anyString(), eq(billNo))).thenReturn(List.of(Map.of("id", orderId, "maker_id", maker)));
            when(documents.canRead(maker)).thenReturn(ownerScope);
            OrderDetail detail = mock(OrderDetail.class);
            when(detail.getBillNo()).thenReturn(billNo);
            when(detail.getLegacyId()).thenReturn(legacyId);
            when(detail.getStatus()).thenReturn((short) 1);
            when(detail.getItems()).thenReturn(List.of());
            when(orders.detail(orderId)).thenReturn(detail);
            return orderId;
        }
    }
}
