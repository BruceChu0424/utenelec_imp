package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.UUID;

/**
 * V486 批准后改量的财务复核 case 开立（对齐销售 V482「改后重回待确认」）。
 *
 * <p>独立于 {@link ProcurementFinanceApprovalService}，不注入审批 port，避免
 * 「订货服务 → 审批服务 → port → 订货服务」的 Bean 环。改量在订货服务事务内
 * （{@code Propagation.MANDATORY}）先生效，再由本服务以改后快照开 PENDING case
 * （attempt+1），并发布 {@code PROCUREMENT_FINANCE_CHANGE_SUBMITTED} 事件——
 * 审批任务列表按 case 关联的事实账行标注「改后待复核 · 改量 N 处」，复核通过
 * 仅确认（订单已批准，不重复生效副作用）。
 */
@Service
@RequiredArgsConstructor
public class ProcurementApprovalReconfirmationService {

    public static final String EVENT_CHANGE_SUBMITTED =
            "PROCUREMENT_FINANCE_CHANGE_SUBMITTED";

    private final ObjectMapper objectMapper;

    private final JdbcTemplate jdbc;
    private final BusinessEventPublisher events;
    private final SecurityContextCurrentUser currentUser;

    public record PendingQuantityRevision(UUID caseId, long version, String snapshotHash) { }

    /** The order coordinator is already held; use the same order -> case lock order as finance decisions. */
    @Transactional(propagation = Propagation.MANDATORY)
    public PendingQuantityRevision lockPendingQuantityRevision(OrderSnapshot before) {
        if (!"PURCHASE".equals(before.orderType())) throw new ApiException(ErrorCode.CONFLICT, "当前订单不支持待审改量");
        var cases = jdbc.query("""
                SELECT id, version, snapshot_hash FROM procurement_order_approval_cases
                WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING' AND request_type='ORDER'
                FOR UPDATE
                """, (rs, index) -> new PendingQuantityRevision(rs.getObject("id", UUID.class),
                        rs.getLong("version"), rs.getString("snapshot_hash")), before.orderId());
        if (cases.size() != 1 || !HashUtil.sha256(canonicalSnapshotJson(before)).equals(cases.getFirst().snapshotHash())) {
            throw new ApiException(ErrorCode.CONFLICT, "订单待审内容已变化，请刷新后重试");
        }
        return cases.getFirst();
    }

    /** Amend one pending review in place, preserving its original facts in the append-only event history. */
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID refreshPendingQuantityCase(OrderSnapshot after, PendingQuantityRevision pending, long changeCount) {
        String json = canonicalSnapshotJson(after), hash = HashUtil.sha256(json);
        UUID actorUser = currentUser.requireId(), actorEmployee = currentUser.requireEmployeeId();
        int recorded = jdbc.update("""
                INSERT INTO procurement_order_approval_events(id,case_id,event_type,actor_user_id,actor_employee_id,event_snapshot)
                SELECT ?,id,'QUANTITY_CHANGED',?,?,jsonb_build_object(
                    'pendingRevision',true,'previousVersion',version,'previousSnapshotHash',snapshot_hash,
                    'previousSubmissionSnapshot',submission_snapshot,'previousDisplaySnapshot',display_snapshot,
                    'snapshotHash',?,'changeCount',?)
                FROM procurement_order_approval_cases
                WHERE id=? AND order_type='PURCHASE' AND order_id=? AND status='PENDING'
                  AND request_type='ORDER' AND version=? AND snapshot_hash=?
                """, UUID.randomUUID(), actorUser, actorEmployee, hash, changeCount,
                pending.caseId(), after.orderId(), pending.version(), pending.snapshotHash());
        int changed = jdbc.update("""
                UPDATE procurement_order_approval_cases SET amount_snapshot=?,submission_snapshot=CAST(? AS jsonb),
                    snapshot_hash=?,display_snapshot=NULL,version=version+1,updated_at=now()
                WHERE id=? AND order_type='PURCHASE' AND order_id=? AND status='PENDING'
                  AND request_type='ORDER' AND version=? AND snapshot_hash=?
                """, after.totalLocal(), json, hash, pending.caseId(), after.orderId(), pending.version(), pending.snapshotHash());
        if (recorded != 1 || changed != 1) throw new ApiException(ErrorCode.CONFLICT, "财务审核状态已变化，请刷新后重试");
        String eventType="PROCUREMENT_FINANCE_SUBMITTED";
        events.publishOnce(eventType,"PROCUREMENT_APPROVAL_CASE",pending.caseId(),
                Map.of("orderType",after.orderType(),"orderId",after.orderId(),"status","PENDING",
                        "version",pending.version()+1,"changeCount",changeCount),
                eventType+":"+pending.caseId()+":quantity:"+(pending.version()+1));
        return pending.caseId();
    }

    /**
     * 开立改量复核 case。必须运行在 change-qty 事务内；调用方保证订单已处于
     * 财务批准状态且快照为改后事实。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public UUID openReconfirmationCase(OrderSnapshot snapshot, long changeCount) {
        requireNoPendingCase(snapshot.orderType(), snapshot.orderId());
        int attempt = nextAttempt(snapshot.orderType(), snapshot.orderId());
        UUID caseId = UUID.randomUUID();
        UUID actorUser = currentUser.requireId();
        UUID actorEmployee = currentUser.requireEmployeeId();
        String snapshotJson = canonicalSnapshotJson(snapshot);
        String snapshotHash = HashUtil.sha256(snapshotJson);

        jdbc.update("""
                INSERT INTO procurement_order_approval_cases(
                    id, order_type, order_id, attempt, bill_no_snapshot,
                    amount_snapshot, submission_snapshot, snapshot_hash,
                    submitted_by_user_id, submitted_by_employee_id,
                    assignee_user_id, assignee_employee_id, assignee_name_snapshot,
                    status, version
                )
                VALUES (?, ?, ?, ?, ?, ?, CAST(? AS jsonb), ?, ?, ?, ?, ?, ?, 'PENDING', 1)
                """,
                caseId,
                snapshot.orderType(),
                snapshot.orderId(),
                attempt,
                snapshot.billNo(),
                snapshot.totalLocal(),
                snapshotJson,
                snapshotHash,
                actorUser,
                actorEmployee,
                null,
                null,
                null);
        jdbc.update("""
                INSERT INTO procurement_order_approval_events(
                    id, case_id, event_type, actor_user_id, actor_employee_id,
                    from_assignee_user_id, to_assignee_user_id, reason,
                    event_snapshot
                )
                VALUES (?, ?, 'SUBMITTED', ?, ?, NULL, NULL, NULL, CAST(? AS jsonb))
                """,
                UUID.randomUUID(),
                caseId,
                actorUser,
                actorEmployee,
                canonicalJson(Map.of(
                        "attempt", attempt,
                        "snapshotHash", snapshotHash,
                        "reconfirmation", true,
                        "changeCount", changeCount)));
        events.publishOnce(
                EVENT_CHANGE_SUBMITTED,
                "PROCUREMENT_APPROVAL_CASE",
                caseId,
                Map.of(
                        "orderType", snapshot.orderType(),
                        "orderId", snapshot.orderId(),
                        "status", "PENDING",
                        "version", 1L,
                        "changeCount", changeCount),
                EVENT_CHANGE_SUBMITTED + ":" + caseId);
        return caseId;
    }

    private void requireNoPendingCase(String orderType, UUID orderId) {
        Boolean pending = jdbc.queryForObject("""
                SELECT EXISTS(
                    SELECT 1
                    FROM procurement_order_approval_cases
                    WHERE order_type = ? AND order_id = ? AND status = 'PENDING'
                )
                """, Boolean.class, orderType, orderId);
        if (Boolean.TRUE.equals(pending)) {
            throw new ApiException(ErrorCode.CONFLICT, "订货单已在财务复核中");
        }
    }

    private int nextAttempt(String orderType, UUID orderId) {
        Integer attempt = jdbc.queryForObject("""
                SELECT COALESCE(MAX(attempt), 0) + 1
                FROM procurement_order_approval_cases
                WHERE order_type = ? AND order_id = ?
                """, Integer.class, orderType, orderId);
        return attempt == null ? 1 : attempt;
    }

    private String canonicalSnapshotJson(OrderSnapshot snapshot) {
        return ProcurementApprovalSnapshot.json(snapshot, objectMapper);
    }

    private String canonicalJson(Object value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("审批快照无法序列化", error);
        }
    }
}
