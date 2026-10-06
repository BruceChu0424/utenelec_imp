package com.uten.imp.features.subcontract.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.kit.SubcontractKitService;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.OrderProgress;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

/**
 * Pure rules of the subcontract document tool: number shape, person-free node text, the neutral reply and the
 * detail-view audit of each document kind (one record per successful read, none for a refused or unknown number
 * or a re-check).
 */
class SubcontractOrderAiChatToolTest {

    @Test
    void nodeDetailKeepsFixedWordingOnly() {
        assertThat(SubcontractOrderAiChatTool.safeDetail("已领 0/100 个，还缺 100 个")).isEqualTo("已领 0/100 个，还缺 100 个");
        assertThat(SubcontractOrderAiChatTool.safeDetail("财务审批通过(审批人：张三)")).isNull();
        assertThat(SubcontractOrderAiChatTool.safeDetail("退回原因: 价格")).isNull();
        assertThat(SubcontractOrderAiChatTool.safeDetail(" ")).isNull();
    }

    @Test
    void numberShapeAndNeutralReply() {
        assertThat(SubcontractOrderAiChatTool.documentNo(Map.of("documentNo", " eb20261006000001"))).isEqualTo("EB20261006000001");
        assertThatThrownBy(() -> SubcontractOrderAiChatTool.documentNo(Map.of("orderNo", "EB1"))).isInstanceOf(ApiException.class);
        assertThat(SubcontractOrderAiChatTool.NOT_FOUND).isEqualTo("没有找到你能查看的这张单据。请核对单号是否完整、有没有输错；"
                + "如果这张单不在你的查看范围内(比如由别的同事负责)，这里同样查不到，可以请负责的同事或主管查看。");
    }

    @Test
    void aFoundOrderLeavesTheOrderDetailViewRecordOnceAndAReCheckLeavesNone() {
        Fixture fixture = new Fixture();
        UUID orderId = fixture.order("EO20261006000001", true, null);

        Map<String, Object> result = fixture.tool.execute(Map.of("documentNo", "eo20261006000001"));
        assertThat((String) result.get("reply")).contains("委外订货单 EO20261006000001", "财务已批准");
        verify(fixture.audit).record("view_subcontract_order_detail", "subcontract_orders", orderId, "EO20261006000001",
                null, "委外订货单(AI 助手查询)");

        Map<String, Object> evidence = evidence(result);
        fixture.tool.authorizeResultRead(evidence);
        verifyNoMoreInteractions(fixture.audit);
    }

    @Test
    void aFoundApplicationLeavesTheApplicationDetailViewRecordWithItsLegacyId() {
        Fixture fixture = new Fixture();
        UUID applicationId = fixture.application("EB20261006000001", 12);
        Map<String, Object> result = fixture.tool.execute(Map.of("documentNo", "EB20261006000001"));
        assertThat((String) result.get("reply")).contains("委外申请单 EB20261006000001", "已全部下单");
        verify(fixture.audit).record("view_subcontract_application_detail", "subcontract_applications", applicationId,
                "EB20261006000001", 12, "委外申请单(AI 助手查询)");
    }

    @Test
    void unknownOrOutOfScopeNumbersAndAMissingPermissionLeaveNoViewRecord() {
        Fixture fixture = new Fixture();
        fixture.order("EO20261006000002", false, null);
        Map<String, Object> hidden = fixture.tool.execute(Map.of("documentNo", "EO20261006000002"));
        Map<String, Object> unknown = fixture.tool.execute(Map.of("documentNo", "EO20991231999999"));
        assertThat(hidden.get("reply")).isEqualTo(SubcontractOrderAiChatTool.NOT_FOUND).isEqualTo(unknown.get("reply"));
        verify(fixture.progress, never()).progress(any());

        // An application without the application view permission is hidden the same way.
        fixture.application("EB20261006000002", null);
        when(fixture.reader.getPermissions()).thenReturn(Set.of("subcontract_order:view"));
        assertThat(fixture.tool.execute(Map.of("documentNo", "EB20261006000002")).get("reply"))
                .isEqualTo(SubcontractOrderAiChatTool.NOT_FOUND);

        when(fixture.reader.getPermissions()).thenReturn(Set.of());
        assertThatThrownBy(() -> fixture.tool.execute(Map.of("documentNo", "EB20261006000002")))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        verifyNoInteractions(fixture.audit);
    }

    @Test
    void aViewThatCannotBeRecordedAnswersNothing() {
        Fixture fixture = new Fixture();
        fixture.application("EB20261006000003", null);
        doThrow(new IllegalStateException("Authenticated detail viewer is missing"))
                .when(fixture.audit).record(any(), any(), any(), any(), any(), any());
        assertThatThrownBy(() -> fixture.tool.execute(Map.of("documentNo", "EB20261006000003")))
                .isInstanceOf(IllegalStateException.class);
    }

    /** The tool's own evidence map, copied with typed keys (no unchecked cast). */
    private static Map<String, Object> evidence(Map<String, Object> result) {
        Map<String, Object> evidence = new java.util.HashMap<>();
        ((Map<?, ?>) result.get("_toolEvidence")).forEach((key, value) -> evidence.put((String) key, value));
        return evidence;
    }

    /** The tool over mocked reads: a subcontract reader with both view permissions. */
    private static final class Fixture {
        final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
        final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        final AuthUser reader = mock(AuthUser.class);
        final SubcontractDocumentAccessPolicy documents = mock(SubcontractDocumentAccessPolicy.class);
        final SubcontractOrderProgressService progress = mock(SubcontractOrderProgressService.class);
        final JdbcTemplate jdbc = mock(JdbcTemplate.class);
        final AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);
        final SubcontractOrderAiChatTool tool = new SubcontractOrderAiChatTool(access, current, documents, progress,
                mock(SubcontractKitService.class), jdbc, new ObjectMapper(),
                Clock.fixed(Instant.parse("2026-10-06T01:00:00Z"), ZoneOffset.UTC), audit);

        Fixture() {
            when(access.hasDomain("SUBCONTRACT")).thenReturn(true);
            when(reader.getPermissions()).thenReturn(Set.of("subcontract_order:view", "subcontract_application:view"));
            when(current.get()).thenReturn(Optional.of(reader));
        }

        /** An approved, open order with no lines, inside the reader's owner scope or not. */
        UUID order(String billNo, boolean ownerScope, Integer legacyId) {
            UUID orderId = UUID.randomUUID();
            UUID maker = UUID.randomUUID();
            Map<String, Object> head = new java.util.HashMap<>(Map.of("id", orderId, "maker_id", maker, "status", 1,
                    "is_closed", false, "bill_date", "2026-10-06"));
            head.put("legacy_id", legacyId);
            when(jdbc.queryForList(contains("FROM subcontract_orders"), eq(billNo))).thenReturn(List.of(head));
            when(documents.canRead(maker)).thenReturn(ownerScope);
            when(progress.progress(orderId)).thenReturn(mock(OrderProgress.class));
            return orderId;
        }

        /** An approved application with no open lines (everything already ordered). */
        UUID application(String billNo, Integer legacyId) {
            UUID applicationId = UUID.randomUUID();
            Map<String, Object> head = new java.util.HashMap<>(Map.of("id", applicationId, "status", 1,
                    "is_closed", false, "bill_date", "2026-10-06"));
            head.put("legacy_id", legacyId);
            when(jdbc.queryForList(contains("FROM subcontract_applications"), eq(billNo))).thenReturn(List.of(head));
            return applicationId;
        }
    }
}
