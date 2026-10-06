package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.OrderProgressTimelineEvent;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
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
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

/**
 * Pure rules of the sales order progress tool: number shape, person-free step text, the shared neutral reply and
 * the detail-view audit (one record per successful read, none for a refused or unknown number or a re-check).
 */
class SalesOrderAiChatToolTest {

    @Test
    void orderNumberIsFoldedToTheStoredShapeAndAnythingElseAsksAgain() {
        assertThat(SalesOrderAiChatTool.orderNo(Map.of("orderNo", " xd2026 1006000003 "))).isEqualTo("XD20261006000003");
        assertThat(SalesOrderAiChatTool.orderNo(Map.of("orderNo", "ＸＤ２０２６１００６０００００３"))).isEqualTo("XD20261006000003");
        for (Object bad : new Object[]{"XD2026'; DROP", "订单XD1", "X", 12}) {
            assertThatThrownBy(() -> SalesOrderAiChatTool.orderNo(Map.of("orderNo", bad)))
                    .isInstanceOf(ApiException.class)
                    .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        }
        assertThatThrownBy(() -> SalesOrderAiChatTool.orderNo(Map.of("orderNo", "XD1", "ownerId", "x")))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void stepsKeepOnlyFixedServerWordingAndNeverAPersonOrReason() {
        OffsetDateTime at = OffsetDateTime.parse("2026-10-05T20:00:00Z");
        var approvedWithName = SalesOrderAiChatTool.step(new OrderProgressTimelineEvent(60, "PRODUCTION_PLAN", "生产计划下达",
                "下达人", "张三", at, OrderProgressTimelineEvent.DONE, "已审核下达(审核人：李四)", "PRODUCTION_PLAN", null, "JH1"));
        assertThat(approvedWithName.detail()).isNull();
        assertThat(approvedWithName.toString()).doesNotContain("张三", "李四");
        assertThat(approvedWithName.day()).as("business day in Asia/Shanghai").isEqualTo("2026-10-06");

        var runningWithReason = SalesOrderAiChatTool.step(new OrderProgressTimelineEvent(51, "PURCHASE_ORDER", "物料准备-采购订货",
                "采购人", "王五", null, OrderProgressTimelineEvent.CURRENT, "财务审批驳回：价格太高", null, null, "CD1"));
        assertThat(runningWithReason.detail()).isNull();
        assertThat(runningWithReason.state()).isEqualTo("进行中");

        var waiting = SalesOrderAiChatTool.step(new OrderProgressTimelineEvent(30, "FINANCE_CONFIRMED", "财务审核",
                null, null, null, OrderProgressTimelineEvent.CURRENT, "等待财务审核组确认", null, null, null));
        assertThat(waiting.detail()).isEqualTo("等待财务审核组确认");
    }

    @Test
    void notFoundIsTheNeutralReplySharedByAllDocumentTools() {
        // The same literal is pinned in the purchase and subcontract tool tests.
        assertThat(SalesOrderAiChatTool.NOT_FOUND).isEqualTo("没有找到你能查看的这张单据。请核对单号是否完整、有没有输错；"
                + "如果这张单不在你的查看范围内(比如由别的同事负责)，这里同样查不到，可以请负责的同事或主管查看。");
        assertThat(SalesOrderAiChatTool.stageLabel("WAREHOUSE_PENDING")).isEqualTo("等仓库出货");
    }

    @Test
    void aFoundOrderLeavesTheDetailPageViewRecordOnceAndAReCheckLeavesNone() {
        Fixture fixture = new Fixture();
        UUID orderId = UUID.randomUUID();
        fixture.rows(new Object[]{orderId, 0, "2026-10-06", "2026-10-20", false, false, null});

        Map<String, Object> result = fixture.tool.execute(Map.of("orderNo", " xd20261006000003 "));
        assertThat((String) result.get("reply")).contains("销售订货单 XD20261006000003", "草稿");
        // The same action and object table as the order detail page; the label says the AI assistant read it.
        verify(fixture.audit).record("view_sales_order_detail", "sales_orders", orderId, "XD20261006000003", null,
                "销售订货单(AI 助手查询)");

        // Showing a stored answer again re-reads the facts in the reader's scope but is not a new view.
        Map<String, Object> evidence = evidence(result);
        fixture.tool.authorizeResultRead(evidence);
        verifyNoMoreInteractions(fixture.audit);
    }

    @Test
    void anImportedOrderPassesItsLegacyIdLikeTheDetailPage() {
        Fixture fixture = new Fixture();
        UUID orderId = UUID.randomUUID();
        fixture.rows(new Object[]{orderId, 0, "2026-10-06", null, false, false, 86});
        fixture.tool.execute(Map.of("orderNo", "XD-OLD-86"));
        // The recorder turns a legacy id into the registered history action, exactly as for the detail page.
        verify(fixture.audit).record("view_sales_order_detail", "sales_orders", orderId, "XD-OLD-86", 86,
                "销售订货单(AI 助手查询)");
    }

    @Test
    void unknownOrOutOfScopeNumbersAndAMissingPermissionLeaveNoViewRecord() {
        Fixture fixture = new Fixture();
        // The scoped query finds nothing for an unknown number and for an order of another owner alike.
        fixture.rows();
        Map<String, Object> hidden = fixture.tool.execute(Map.of("orderNo", "XD20991231999999"));
        assertThat(hidden.get("reply")).isEqualTo(SalesOrderAiChatTool.NOT_FOUND);
        Map<String, Object> evidence = evidence(hidden);
        fixture.tool.authorizeResultRead(evidence);

        when(fixture.reader.getPermissions()).thenReturn(Set.of());
        assertThatThrownBy(() -> fixture.tool.execute(Map.of("orderNo", "XD20261006000003")))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        verifyNoInteractions(fixture.audit);
    }

    @Test
    void aViewThatCannotBeRecordedAnswersNothing() {
        Fixture fixture = new Fixture();
        fixture.rows(new Object[]{UUID.randomUUID(), 0, "2026-10-06", null, false, false, null});
        doThrow(new IllegalStateException("Authenticated detail viewer is missing"))
                .when(fixture.audit).record(any(), any(), any(), any(), any(), any());
        assertThatThrownBy(() -> fixture.tool.execute(Map.of("orderNo", "XD20261006000003")))
                .isInstanceOf(IllegalStateException.class);
    }

    /** The tool's own evidence map, copied with typed keys (no unchecked cast). */
    private static Map<String, Object> evidence(Map<String, Object> result) {
        Map<String, Object> evidence = new java.util.HashMap<>();
        ((Map<?, ?>) result.get("_toolEvidence")).forEach((key, value) -> evidence.put((String) key, value));
        return evidence;
    }

    /** The tool over mocked reads: a sales reader with the order view permission and an all-visible scope. */
    private static final class Fixture {
        final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final AuthUser reader = mock(AuthUser.class);
        final SalesDocumentAccessPolicy documents = mock(SalesDocumentAccessPolicy.class);
        final EntityManager em = mock(EntityManager.class);
        final Query query = mock(Query.class);
        final AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);
        final SalesOrderAiChatTool tool = new SalesOrderAiChatTool(access, current, documents,
                mock(SalesOrderService.class), mock(SalesOrderTimelineService.class), em, new ObjectMapper(),
                Clock.fixed(Instant.parse("2026-10-06T01:00:00Z"), ZoneOffset.UTC), audit);

        Fixture() {
            when(access.hasDomain("SALES")).thenReturn(true);
            when(reader.getPermissions()).thenReturn(Set.of("sales_order:view"));
            when(current.get()).thenReturn(Optional.of(reader));
            when(documents.nativeReadScope(anyString(), anyString()))
                    .thenReturn(new DocumentAccessPolicy.NativeReadScope("TRUE", null, Set.of()));
            when(em.createNativeQuery(anyString())).thenReturn(query);
        }

        void rows(Object[]... rows) {
            when(query.getResultList()).thenReturn(List.of(rows));
        }
    }
}
