package com.uten.imp.features.admin.workflow;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.workflow.WorkflowResponsibilityContracts.Responsibility;
import com.uten.imp.features.admin.workflow.WorkflowResponsibilityContracts.Reviewer;
import com.uten.imp.features.admin.workflow.WorkflowResponsibilityContracts.UpdateRequest;
import com.uten.imp.features.auth.PasswordService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

@Service
@RequiredArgsConstructor
public class WorkflowResponsibilityService {

    public static final String PURCHASE_BEHAVIOR = "PURCHASE_ORDER_FINANCE_APPROVAL";
    public static final String SUBCONTRACT_BEHAVIOR = "SUBCONTRACT_ORDER_FINANCE_APPROVAL";
    private static final List<String> BEHAVIORS =
            List.of(PURCHASE_BEHAVIOR, SUBCONTRACT_BEHAVIOR);
    private static final Set<String> BEHAVIOR_SET = Set.copyOf(BEHAVIORS);

    private final JdbcTemplate jdbc;
    private final WorkflowReviewerEligibility eligibility;
    private final PasswordService passwordService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public List<Responsibility> list() {
        Map<String, Responsibility> configured = new LinkedHashMap<>();
        List<Responsibility> rows = jdbc.query("""
                SELECT behavior_code, assignee_user_id, assignee_employee_id,
                       assignee_name_snapshot, version, updated_at
                FROM workflow_responsibility_assignments
                ORDER BY behavior_code
                """, (rs, rowNum) -> map(rs));
        rows.forEach(row -> configured.put(row.behaviorCode(), row));
        return BEHAVIORS.stream()
                .map(code -> configured.getOrDefault(
                        code,
                        new Responsibility(code, null, null, null, 0, null)))
                .toList();
    }

    @Transactional(readOnly = true)
    public List<Reviewer> reviewers() {
        return eligibility.eligibleReviewers().stream()
                .map(row -> new Reviewer(
                        row.userId(),
                        row.employeeId(),
                        row.employeeName(),
                        row.departmentId(),
                        row.departmentName()))
                .toList();
    }

    @Transactional
    public Responsibility update(String rawBehaviorCode, UpdateRequest request) {
        String behaviorCode = requireBehavior(rawBehaviorCode);
        passwordService.verifyPassword(request.password());
        tx.bind();

        long expectedVersion = request.expectedVersion() == null
                ? -1
                : request.expectedVersion();
        WorkflowReviewerEligibility.EligibleReviewer reviewer =
                eligibility.requireEligible(request.assigneeUserId());
        UUID actor = currentUser.requireId();

        List<Responsibility> locked = jdbc.query("""
                SELECT behavior_code, assignee_user_id, assignee_employee_id,
                       assignee_name_snapshot, version, updated_at
                FROM workflow_responsibility_assignments
                WHERE behavior_code = ?
                FOR UPDATE
                """, (rs, rowNum) -> map(rs), behaviorCode);

        if (locked.isEmpty()) {
            if (expectedVersion != 0) {
                throw concurrentChange();
            }
            jdbc.update("""
                    INSERT INTO workflow_responsibility_assignments(
                        behavior_code, assignee_user_id, assignee_employee_id,
                        assignee_name_snapshot, version, created_by, updated_by
                    )
                    VALUES (?, ?, ?, ?, 1, ?, ?)
                    """,
                    behaviorCode,
                    reviewer.userId(),
                    reviewer.employeeId(),
                    reviewer.employeeName(),
                    actor,
                    actor);
        } else {
            Responsibility current = locked.getFirst();
            if (current.version() != expectedVersion) {
                throw concurrentChange();
            }
            int changed = jdbc.update("""
                    UPDATE workflow_responsibility_assignments
                    SET assignee_user_id = ?,
                        assignee_employee_id = ?,
                        assignee_name_snapshot = ?,
                        version = version + 1,
                        updated_at = now(),
                        updated_by = ?
                    WHERE behavior_code = ? AND version = ?
                    """,
                    reviewer.userId(),
                    reviewer.employeeId(),
                    reviewer.employeeName(),
                    actor,
                    behaviorCode,
                    expectedVersion);
            if (changed != 1) {
                throw concurrentChange();
            }
        }
        return findRequired(behaviorCode);
    }

    private Responsibility findRequired(String behaviorCode) {
        return jdbc.queryForObject("""
                SELECT behavior_code, assignee_user_id, assignee_employee_id,
                       assignee_name_snapshot, version, updated_at
                FROM workflow_responsibility_assignments
                WHERE behavior_code = ?
                """, (rs, rowNum) -> map(rs), behaviorCode);
    }

    private static Responsibility map(java.sql.ResultSet rs)
            throws java.sql.SQLException {
        return new Responsibility(
                rs.getString("behavior_code"),
                rs.getObject("assignee_user_id", UUID.class),
                rs.getObject("assignee_employee_id", UUID.class),
                rs.getString("assignee_name_snapshot"),
                rs.getLong("version"),
                rs.getObject("updated_at", OffsetDateTime.class));
    }

    private static String requireBehavior(String raw) {
        String behavior = raw == null ? "" : raw.trim().toUpperCase();
        if (!BEHAVIOR_SET.contains(behavior)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "不支持的流程行为");
        }
        return behavior;
    }

    private static ApiException concurrentChange() {
        return new ApiException(ErrorCode.CONFLICT, "负责人配置已变化，请刷新后重试");
    }
}
