package com.uten.imp.responsibility;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.responsibility.dto.DataHandoverAction;
import com.uten.imp.responsibility.dto.DataHandoverPreview;
import com.uten.imp.responsibility.dto.DataHandoverPreviewItem;
import com.uten.imp.responsibility.dto.DataHandoverRequest;
import com.uten.imp.responsibility.dto.DataHandoverResult;
import com.uten.imp.security.EmployeeHandoverVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.sql.Date;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * Transfers mutable employee responsibilities while preserving every historical actor field.
 *
 * <p>The service deliberately never updates maker/approver/created_by or posted document facts.
 * A completed handover scope is the authority used by the visibility layer for the source
 * employee's historical documents.</p>
 */
@Service
@RequiredArgsConstructor
public class DataHandoverService {

    public static final List<String> ALL_SCOPES = List.of(
            "goods", "client", "sales", "finance",
            "purchase", "subcontract", "production_plan", "stock_doc");
    private static final Set<String> ALL_SCOPE_SET = Set.copyOf(ALL_SCOPES);

    private final EntityManager em;
    private final ObjectMapper objectMapper;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ClientHandoverEventRecorder clientEvents;
    private final EmployeeHandoverVisibility handoverVisibility;
    private final EmployeeHandoverAuthorization authorization;

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public DataHandoverPreview preview(
            UUID sourceEmployeeId, UUID targetEmployeeId, Collection<String> requestedScopes) {
        requireDistinctSourceAndTarget(sourceEmployeeId, targetEmployeeId);
        authorization.requireAuthorized(sourceEmployeeId, targetEmployeeId);
        EmployeeFact source = employee(sourceEmployeeId, false);
        EmployeeFact target = targetEmployeeId == null
                ? null : eligibleTarget(targetEmployeeId, false);
        return buildPreview(source, target, normalizeScopes(requestedScopes), true);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public DataHandoverPreview previewOffboarding(
            UUID sourceEmployeeId, UUID defaultTargetEmployeeId) {
        requireDistinctSourceAndTarget(sourceEmployeeId, defaultTargetEmployeeId);
        authorization.requireAuthorized(sourceEmployeeId, defaultTargetEmployeeId);
        EmployeeFact source = employee(sourceEmployeeId, false);
        EmployeeFact defaultTarget = defaultTargetEmployeeId == null
                ? null : eligibleTarget(defaultTargetEmployeeId, false);
        return buildOffboardingPreview(source, defaultTarget);
    }

    @Transactional(isolation = Isolation.REPEATABLE_READ)
    public DataHandoverResult executeManual(DataHandoverRequest request) {
        return execute(request, "MANUAL", true);
    }

    @Transactional
    public Map<String, Long> executeOffboarding(
            UUID requestId,
            UUID sourceEmployeeId,
            UUID defaultTargetEmployeeId,
            String reason,
            LocalDate effectiveDate) {
        requireDistinctSourceAndTarget(sourceEmployeeId, defaultTargetEmployeeId);
        authorization.requireAuthorized(sourceEmployeeId, defaultTargetEmployeeId);
        lockOffboardingExtraRows(sourceEmployeeId);
        EmployeeFact source = employee(sourceEmployeeId, false);
        EmployeeFact defaultTarget = defaultTargetEmployeeId == null
                ? null : eligibleTarget(defaultTargetEmployeeId, false);
        Set<UUID> scopeRecipients = dataScopeRecipientEmployeeIds(
                sourceEmployeeId, ALL_SCOPE_SET);
        lockEmployeeRows(scopeRecipients);
        lockResponsibilityRows(sourceEmployeeId, ALL_SCOPE_SET, false);
        clientEvents.lockViewerClients(sourceEmployeeId);
        DataHandoverPreview preview = buildOffboardingPreview(source, defaultTarget);
        requireNoBlockers(preview, "离职数据交接被阻止：");
        if (preview.requiresTarget()) {
            throw conflict("仍有未指定接手人的数据范围，请选择默认接手人");
        }

        Map<UUID, LinkedHashSet<String>> groupedScopes = new LinkedHashMap<>();
        for (String scope : ALL_SCOPES) {
            boolean hasWork = preview.items().stream().anyMatch(item ->
                    scope.equals(item.scope()) && item.count() > 0
                            && (item.action() == DataHandoverAction.TRANSFER
                            || item.action() == DataHandoverAction.HISTORY_ACCESS));
            if (!hasWork) continue;
            UUID effectiveTarget = preview.scopeTargetEmployeeIds().get(scope);
            if (effectiveTarget == null) {
                throw conflict("交接范围 " + scope + " 缺少有效接手人");
            }
            groupedScopes.computeIfAbsent(effectiveTarget, ignored -> new LinkedHashSet<>())
                    .add(scope);
        }

        LinkedHashSet<UUID> accountEmployees = new LinkedHashSet<>(scopeRecipients);
        accountEmployees.add(sourceEmployeeId);
        accountEmployees.addAll(groupedScopes.keySet());
        if (defaultTargetEmployeeId != null) accountEmployees.add(defaultTargetEmployeeId);
        lockAccounts(accountEmployees);
        for (UUID targetId : groupedScopes.keySet()) activeAccount(targetId, false);
        if (defaultTargetEmployeeId != null) activeAccount(defaultTargetEmployeeId, false);

        Map<String, Long> summary = new LinkedHashMap<>();
        for (Map.Entry<UUID, LinkedHashSet<String>> group : groupedScopes.entrySet()) {
            UUID childRequestId = derivedOffboardingRequestId(
                    requestId, group.getKey(), group.getValue());
            DataHandoverResult child = execute(new DataHandoverRequest(
                    childRequestId, sourceEmployeeId, group.getKey(),
                    group.getValue(), reason, effectiveDate), "OFFBOARDING", false);
            mergeSummary(summary, child.resultSummary());
        }
        mergeSummary(summary, applyOffboardingExtras(
                source, defaultTarget, currentUser.requireId(),
                currentUser.requireEmployeeId(), preview));
        summary.put("total", summary.entrySet().stream()
                .filter(entry -> !"total".equals(entry.getKey()))
                .mapToLong(Map.Entry::getValue).sum());
        return Collections.unmodifiableMap(summary);
    }

    @Transactional
    public boolean beginOffboarding(
            UUID requestId,
            UUID employeeId,
            UUID defaultSuccessorEmployeeId,
            LocalDate effectiveDate,
            String resignType,
            String reason,
            String handoverReason,
            Set<String> checklistCodes) {
        if (requestId == null) throw validation("requestId 必填");
        UUID actorUserId = currentUser.requireId();
        tx.bind();
        handoverCoordinatorLock();
        advisoryLock(requestId);
        authorization.requireAuthorized(employeeId, defaultSuccessorEmployeeId);
        String codes = canonicalChecklistCodes(checklistCodes);

        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT employee_id, default_successor_employee_id, effective_date,
                               resign_type, reason, handover_reason,
                               array_to_string(checklist_codes, ','),
                               employment_generation,
                               default_successor_employment_generation, status
                        FROM employee_offboarding_events
                        WHERE request_id=:requestId
                        """)
                .setParameter("requestId", requestId)
                .getResultList();
        if (!rows.isEmpty()) {
            Object[] row = rows.getFirst();
            boolean same = Objects.equals(employeeId, uuid(row[0]))
                    && Objects.equals(defaultSuccessorEmployeeId, uuid(row[1]))
                    && Objects.equals(effectiveDate, localDate(row[2]))
                    && Objects.equals(resignType, text(row[3]))
                    && Objects.equals(reason, text(row[4]))
                    && Objects.equals(handoverReason, text(row[5]))
                    && Objects.equals(codes, text(row[6]));
            if (!same) throw conflict("requestId 已用于不同的离职办理请求");
            if (!"COMPLETED".equals(text(row[9]))) {
                throw conflict("同一离职办理请求正在执行");
            }
            EmployeeFact replaySource;
            if (defaultSuccessorEmployeeId == null) {
                replaySource = employee(employeeId, true);
            } else {
                replaySource = lockEmployees(
                        employeeId, defaultSuccessorEmployeeId).source();
            }
            authorization.requireAuthorized(employeeId, defaultSuccessorEmployeeId);
            long currentGeneration = employmentGeneration(employeeId);
            long storedGeneration = ((Number) row[7]).longValue();
            Long currentSuccessorGeneration = defaultSuccessorEmployeeId == null
                    ? null : employmentGeneration(defaultSuccessorEmployeeId);
            Long storedSuccessorGeneration = row[8] == null
                    ? null : ((Number) row[8]).longValue();
            if (currentGeneration != storedGeneration
                    || !Objects.equals(
                    currentSuccessorGeneration, storedSuccessorGeneration)
                    || !"resigned".equals(replaySource.status())) {
                throw conflict("该requestId属于已结束的上一段任职，不能用于当前任职");
            }
            return true;
        }

        // Lock canonical participants before the event INSERT takes employee/user FK locks.
        lockOffboardingParticipants(employeeId, defaultSuccessorEmployeeId);
        long employmentGeneration = employmentGeneration(employeeId);
        Long successorEmploymentGeneration = defaultSuccessorEmployeeId == null
                ? null : employmentGeneration(defaultSuccessorEmployeeId);
        em.createNativeQuery("""
                        INSERT INTO employee_offboarding_events(
                            request_id, employee_id, default_successor_employee_id,
                            effective_date, resign_type, reason, handover_reason,
                            checklist_codes, employment_generation,
                            default_successor_employment_generation,
                            status, result_summary, actor_user_id)
                        VALUES (
                            :requestId, :employeeId, :successorId,
                            :effectiveDate, :resignType, :reason, :handoverReason,
                            CAST(:codes AS TEXT[]), :employmentGeneration,
                            :successorEmploymentGeneration,
                            'EXECUTING', '{}'::jsonb, :actor)
                        """)
                .setParameter("requestId", requestId)
                .setParameter("employeeId", employeeId)
                .setParameter("successorId", defaultSuccessorEmployeeId)
                .setParameter("effectiveDate", effectiveDate)
                .setParameter("resignType", resignType)
                .setParameter("reason", reason)
                .setParameter("handoverReason", handoverReason)
                .setParameter("codes", "{" + codes + "}")
                .setParameter("employmentGeneration", employmentGeneration)
                .setParameter("successorEmploymentGeneration", successorEmploymentGeneration)
                .setParameter("actor", actorUserId)
                .executeUpdate();
        return false;
    }

    @Transactional
    public void completeOffboarding(UUID requestId, Map<String, Long> resultSummary) {
        int updated = em.createNativeQuery("""
                        UPDATE employee_offboarding_events
                        SET status='COMPLETED', result_summary=CAST(:summary AS jsonb),
                            completed_at=now()
                        WHERE request_id=:requestId AND status='EXECUTING'
                        """)
                .setParameter("summary", json(resultSummary == null ? Map.of() : resultSummary))
                .setParameter("requestId", requestId)
                .executeUpdate();
        if (updated != 1) throw conflict("离职办理请求状态已变化，请刷新后重试");
    }

    @Transactional
    public void lockOffboardingParticipants(
            UUID sourceEmployeeId, UUID defaultTargetEmployeeId) {
        requireDistinctSourceAndTarget(sourceEmployeeId, defaultTargetEmployeeId);
        handoverCoordinatorLock();
        authorization.requireAuthorized(sourceEmployeeId, defaultTargetEmployeeId);
        if (defaultTargetEmployeeId == null) {
            EmployeeFact source = employee(sourceEmployeeId, true);
            authorization.requireAuthorized(sourceEmployeeId, null);
            if ("resigned".equals(source.status())) throw conflict("该员工已离职");
            return;
        }
        LockedPair pair = lockEmployees(sourceEmployeeId, defaultTargetEmployeeId);
        authorization.requireAuthorized(sourceEmployeeId, defaultTargetEmployeeId);
        if ("resigned".equals(pair.source().status())) throw conflict("该员工已离职");
        requireEligibleTarget(pair.target(), true);
    }

    private DataHandoverResult execute(
            DataHandoverRequest request, String mode, boolean includeWholePersonExtras) {
        if (request == null || request.requestId() == null
                || request.sourceEmployeeId() == null || request.targetEmployeeId() == null) {
            throw validation("requestId、sourceEmployeeId、targetEmployeeId 必填");
        }
        if (request.sourceEmployeeId().equals(request.targetEmployeeId())) {
            throw validation("接手人不能与交接人相同");
        }
        if (request.effectiveDate() == null || request.effectiveDate().isAfter(BusinessTime.today())) {
            throw validation("交接生效日期不能为空或晚于今天");
        }
        String reason = request.reason() == null ? "" : request.reason().trim();
        if (reason.isEmpty() || reason.length() > 2000) {
            throw validation("交接原因须为 1–2000 个字符");
        }
        Set<String> scopes = "MANUAL".equals(mode)
                ? normalizeExecutionScopes(request.scopes())
                : normalizeScopes(request.scopes());
        authorization.requireAuthorized(request.sourceEmployeeId(), request.targetEmployeeId());
        UUID actorUserId = currentUser.requireId();
        UUID actorEmployeeId = currentUser.requireEmployeeId();
        tx.bind();
        handoverCoordinatorLock();
        advisoryLock(request.requestId());
        LockedPair pair = lockEmployees(request.sourceEmployeeId(), request.targetEmployeeId());
        authorization.requireAuthorized(request.sourceEmployeeId(), request.targetEmployeeId());
        EmployeeFact source = pair.source();
        long sourceEmploymentGeneration = employmentGeneration(source.id());
        long targetEmploymentGeneration = employmentGeneration(pair.target().id());
        Optional<DataHandoverResult> replay = replay(
                request, mode, reason, scopes,
                sourceEmploymentGeneration, targetEmploymentGeneration);
        if (replay.isPresent()) return replay.get();

        EmployeeFact target = requireEligibleTarget(pair.target(), true);
        Set<UUID> scopeRecipients = dataScopeRecipientEmployeeIds(source.id(), scopes);
        lockEmployeeRows(scopeRecipients);
        lockResponsibilityRows(source.id(), scopes, includeWholePersonExtras);
        LinkedHashSet<UUID> accountEmployees = new LinkedHashSet<>(scopeRecipients);
        accountEmployees.add(source.id());
        accountEmployees.add(target.id());
        lockAccounts(accountEmployees);
        AccountFact targetAccount = activeAccount(target.id(), false);

        DataHandoverPreview preview = buildPreview(
                source, target, scopes, includeWholePersonExtras);
        requireNoBlockers(preview, "数据交接被阻止：");
        if (preview.total() == 0) {
            throw conflict("所选范围当前没有可交接的责任或历史数据");
        }

        Set<String> graphScopes = effectiveGraphScopes(preview, scopes);
        UUID handoverId = UUID.randomUUID();
        long sequenceNo = ((Number) em.createNativeQuery("""
                        INSERT INTO employee_data_handovers
                            (id, request_id, source_employee_id, target_employee_id, mode,
                             effective_date, reason, requested_scopes,
                             source_employment_generation, target_employment_generation,
                             status, result_summary, created_by_user_id)
                        VALUES
                            (:id, :requestId, :sourceId, :targetId, :mode,
                             :effectiveDate, :reason, CAST(:requestedScopes AS TEXT[]),
                             :sourceEmploymentGeneration, :targetEmploymentGeneration,
                             'EXECUTING', CAST(:summary AS jsonb), :actor)
                        RETURNING sequence_no
                        """)
                .setParameter("id", handoverId)
                .setParameter("requestId", request.requestId())
                .setParameter("sourceId", source.id())
                .setParameter("targetId", target.id())
                .setParameter("mode", mode)
                .setParameter("effectiveDate", request.effectiveDate())
                .setParameter("reason", reason)
                .setParameter("requestedScopes", textArrayLiteral(scopes))
                .setParameter("sourceEmploymentGeneration", sourceEmploymentGeneration)
                .setParameter("targetEmploymentGeneration", targetEmploymentGeneration)
                .setParameter("summary", "{}")
                .setParameter("actor", actorUserId)
                .getSingleResult()).longValue();
        for (String scope : graphScopes) {
            em.createNativeQuery("""
                            INSERT INTO employee_data_handover_scopes(handover_id, scope)
                            VALUES (:handoverId, :scope)
                            """)
                    .setParameter("handoverId", handoverId)
                    .setParameter("scope", scope)
                    .executeUpdate();
        }

        boolean retainSourceClientViewer = "MANUAL".equals(mode)
                && CurrentEmployeeStatusPolicy.isCurrentEmployee(source.status())
                && account(source.id(), false)
                .filter(value -> "active".equals(value.status()) && !value.deleted())
                .isPresent();
        Map<String, Long> summary = applyTransfers(
                source, target, targetAccount, actorUserId, actorEmployeeId,
                scopes, reason, preview, includeWholePersonExtras,
                retainSourceClientViewer);
        String summaryJson = json(summary);
        int completed = em.createNativeQuery("""
                        UPDATE employee_data_handovers
                        SET status = 'COMPLETED', result_summary = CAST(:summary AS jsonb)
                        WHERE id = :id AND status = 'EXECUTING'
                        """)
                .setParameter("summary", summaryJson)
                .setParameter("id", handoverId)
                .executeUpdate();
        if (completed != 1) throw conflict("交接批次状态已变化，请刷新后重试");
        return new DataHandoverResult(
                handoverId, sequenceNo, request.requestId(), source.id(), target.id(),
                mode, "COMPLETED", scopes, summary, false);
    }

    /** Offboarding-only cleanup fallback. Normal target handover already applies these counts. */
    @Transactional
    public void cleanupDepartingEmployee(UUID sourceEmployeeId) {
        UUID actorUserId = currentUser.requireId();
        UUID actorEmployeeId = currentUser.requireEmployeeId();
        tx.bind();
        disablePersonalOverrides(sourceEmployeeId);
        disableManagerDelegations(sourceEmployeeId, actorUserId);
        hardenDepartingAccount(sourceEmployeeId);
        deleteDataScopes(sourceEmployeeId);
        expireAttachmentUploadSessions(sourceEmployeeId);
        clientEvents.revokeViewerForOffboarding(
                sourceEmployeeId, actorUserId,
                "员工离职：撤销离职员工的客户只读可见权限");
        rejectPendingProfileChanges(sourceEmployeeId, actorEmployeeId, actorUserId);
        releaseClaims(sourceEmployeeId, actorUserId, actorEmployeeId);
    }

    private DataHandoverPreview buildPreview(
            EmployeeFact source, EmployeeFact target, Set<String> scopes,
            boolean includeWholePersonExtras) {
        List<DataHandoverPreviewItem> items = new ArrayList<>();
        if (scopes.contains("goods")) {
            add(items, "goods.owner", "货品负责人", "goods", count(
                    "SELECT count(*) FROM goods WHERE owner_employee_id=:source AND is_deleted=false", source.id()), DataHandoverAction.TRANSFER);
            add(items, "mould.keeper", "模具保管人", "goods", count(
                    "SELECT count(*) FROM moulds WHERE keeper_id=:source AND is_deleted=false", source.id()), DataHandoverAction.TRANSFER);
        }
        if (scopes.contains("client")) {
            add(items, "client.owner", "客户负责人(内销、外贸、OEM统一)", "client", count(
                    "SELECT count(*) FROM clients WHERE owner_employee_id=:source AND is_deleted=false", source.id()), DataHandoverAction.TRANSFER);
            add(items, "client.scopeDelegations",
                    "查看该员工全部客户的授权(精确展开到本次转出客户)", "client",
                    count("""
                            SELECT count(*) FROM user_data_scopes data_scope
                            JOIN users recipient ON recipient.id=data_scope.user_id
                            WHERE data_scope.owner_employee_id=:source
                              AND data_scope.scope='client'
                              AND recipient.employee_id<>:source
                              AND data_scope.owner_employment_generation=(
                                  SELECT count(*) FROM employment_history history
                                  WHERE history.employee_id=data_scope.owner_employee_id
                                    AND history.event_type='rehire')
                              AND EXISTS (
                                  SELECT 1 FROM clients client
                                  WHERE client.owner_employee_id=:source
                                    AND client.is_deleted=false)
                            """, source.id()), DataHandoverAction.TRANSFER);
        }
        if (scopes.contains("purchase")) {
            add(items, "supplier.owner", "供应商负责人", "purchase", count(
                    "SELECT count(*) FROM suppliers WHERE owner_employee_id=:source AND is_deleted=false", source.id()), DataHandoverAction.TRANSFER);
            add(items, "supplierReturn.purchase", "采购供应商退回任务", "purchase", count(
                    "SELECT count(*) FROM supplier_return_tasks WHERE owner_employee_id=:source AND order_type='PURCHASE' AND status='PENDING_RETURN'", source.id()), DataHandoverAction.TRANSFER);
            add(items, "inboundExpectation.purchase", "采购未结预计到货任务", "purchase", count("""
                    SELECT count(*) FROM inbound_expectations
                    WHERE owner_employee_id=:source AND order_type='PURCHASE' AND status='OPEN'
                    """, source.id()), DataHandoverAction.TRANSFER);
            add(items, "arrivalException.purchase", "采购未结到货异常后续责任", "purchase", count("""
                    SELECT count(*) FROM procurement_arrival_exceptions
                    WHERE owner_employee_id=:source AND order_type='PURCHASE'
                      AND status NOT IN ('CLOSED','CANCELED')
                    """, source.id()), DataHandoverAction.TRANSFER);
        }
        if (scopes.contains("subcontract")) {
            add(items, "supplierReturn.subcontract", "委外供应商退回任务", "subcontract", count(
                    "SELECT count(*) FROM supplier_return_tasks WHERE owner_employee_id=:source AND order_type='SUBCONTRACT' AND status='PENDING_RETURN'", source.id()), DataHandoverAction.TRANSFER);
            add(items, "inboundExpectation.subcontract", "委外未结预计到货任务", "subcontract", count("""
                    SELECT count(*) FROM inbound_expectations
                    WHERE owner_employee_id=:source AND order_type='SUBCONTRACT' AND status='OPEN'
                    """, source.id()), DataHandoverAction.TRANSFER);
            add(items, "arrivalException.subcontract", "委外未结到货异常后续责任", "subcontract", count("""
                    SELECT count(*) FROM procurement_arrival_exceptions
                    WHERE owner_employee_id=:source AND order_type='SUBCONTRACT'
                      AND status NOT IN ('CLOSED','CANCELED')
                    """, source.id()), DataHandoverAction.TRANSFER);
        }
        if (scopes.contains("sales")) {
            add(items, "websiteInquiry.assignee", "未完成官网询盘", "sales", count("""
                    SELECT count(*) FROM website_inquiries
                    WHERE assignee_employee_id=:source AND status IN ('new','following')
                    """, source.id()), DataHandoverAction.TRANSFER);
            add(items, "visitor.host", "未来待确认访客", "sales", count("""
                    SELECT count(*) FROM visitor_applications
                    WHERE host_employee_id=:source AND status IN ('pending','hostReviewing')
                      AND planned_visit_at > current_timestamp AND is_deleted=false
                    """, source.id()), DataHandoverAction.TRANSFER);
            add(items, "visitor.approved", "未来已批准访客需先人工改接待人", "sales", count("""
                    SELECT count(*) FROM visitor_applications
                    WHERE host_employee_id=:source AND status='approved'
                      AND planned_visit_at > current_timestamp AND is_deleted=false
                    """, source.id()), DataHandoverAction.BLOCKING);
        }
        if (scopes.contains("production_plan")) {
            add(items, "rdTask.assignee", "未完成研发任务", "production_plan", count("""
                    SELECT count(*) FROM rd_tasks
                    WHERE assignee_employee_id=:source AND status IN ('OPEN','IN_PROGRESS') AND is_deleted=false
                    """, source.id()), DataHandoverAction.TRANSFER);
            add(items, "productionPlan.worker", "草稿生产计划跟单/生产责任", "production_plan", count("""
                    SELECT count(*) FROM production_plans
                    WHERE status=0 AND is_deleted=false AND (seller_id=:source OR worker_id=:source)
                    """, source.id()), DataHandoverAction.TRANSFER);
            long ready = count("""
                    SELECT count(*) FROM production_execution_segments
                    WHERE responsible_employee_id=:source AND status IN ('READY','WAITING') AND is_deleted=false
                    """, source.id());
            long compatible = target == null ? ready : compatibleSegments(source.id(), target.id());
            add(items, "productionSegment.assignable", "可改派生产执行段", "production_plan", compatible, DataHandoverAction.TRANSFER);
            if (target != null) {
                add(items, "productionSegment.organization", "接手人不属于原生产车间/班组", "production_plan",
                        Math.max(0, ready - compatible), DataHandoverAction.BLOCKING);
            }
            add(items, "productionSegment.started", "已派工或生产中执行段", "production_plan", count("""
                    SELECT count(*) FROM production_execution_segments
                    WHERE responsible_employee_id=:source AND status IN ('DISPATCHED','IN_PROGRESS') AND is_deleted=false
                    """, source.id()), DataHandoverAction.BLOCKING);
        }
        if (scopes.contains("finance")) {
            add(items, "asset.custodian", "未终态固定资产", "finance", count("""
                    SELECT count(*) FROM fixed_assets
                    WHERE custodian_employee_id=:source AND lifecycle_status <> 'DISPOSED' AND is_deleted=false
                    """, source.id()), DataHandoverAction.BLOCKING);
            add(items, "deferred.responsible", "未终态待摊事项", "finance", count("""
                    SELECT count(*) FROM deferred_expenses
                    WHERE responsible_employee_id=:source
                      AND lifecycle_status NOT IN ('COMPLETED','TERMINATED') AND is_deleted=false
                    """, source.id()), DataHandoverAction.BLOCKING);
        }
        for (String scope : scopes) {
            long history = historicalDocumentCount(scope, source.id());
            add(items, "history." + scope, "保留原操作人的历史数据访问", scope,
                    history, DataHandoverAction.HISTORY_ACCESS);
            if (target != null && handoverGraphCycle(source.id(), target.id(), scope)) {
                add(items, "handoverCycle." + scope,
                        "该范围的既有交接链会形成循环", scope,
                        1, DataHandoverAction.BLOCKING);
            }
        }
        if (includeWholePersonExtras && scopes.equals(ALL_SCOPE_SET)) {
            add(items, "organization.departmentManager", "仍担任部门负责人，须先在部门资料改负责人", "organization", count(
                    "SELECT count(*) FROM departments WHERE manager_id=:source AND is_deleted=false", source.id()), DataHandoverAction.BLOCKING);
            add(items, "organization.supervisor", "直属下级上级关系", "organization", count(
                    "SELECT count(*) FROM employees WHERE supervisor_id=:source AND is_deleted=false", source.id()), DataHandoverAction.TRANSFER);
            if (target != null) {
                add(items, "organization.supervisorCycle", "接手人位于原下级链，转移会形成循环", "organization",
                        supervisorCycle(source.id(), target.id()) ? 1 : 0, DataHandoverAction.BLOCKING);
            }
            add(items, "workflow.claims", "临时任务认领(自动释放，不转给接手人)", "workflow", count("""
                    SELECT (SELECT count(*) FROM task_claims WHERE claimed_by=:source AND released_at IS NULL)
                         + (SELECT count(*) FROM hr_task_claims WHERE claimed_by=:source AND released_at IS NULL)
                    """, source.id()), DataHandoverAction.RELEASE);
        }

        boolean requiresTarget = items.stream().anyMatch(item -> item.count() > 0
                && (item.action() == DataHandoverAction.TRANSFER
                || item.action() == DataHandoverAction.HISTORY_ACCESS));
        if (target == null && requiresTarget) {
            add(items, "target.required", "存在需交接的数据，请选择接手人", "all", 1, DataHandoverAction.BLOCKING);
        }
        Map<String, UUID> targets = new LinkedHashMap<>();
        if (target != null) scopes.forEach(scope -> targets.put(scope, target.id()));
        return previewResult(source.id(), target == null ? null : target.id(), scopes,
                items, requiresTarget, targets);
    }

    private DataHandoverPreview buildOffboardingPreview(
            EmployeeFact source, EmployeeFact defaultTarget) {
        List<DataHandoverPreviewItem> items = new ArrayList<>();
        Map<String, UUID> targets = new LinkedHashMap<>();
        boolean requiresTarget = false;
        for (String scope : ALL_SCOPES) {
            EmployeeFact effective = existingEligibleSuccessor(source.id(), scope);
            if (effective == null) effective = defaultTarget;
            DataHandoverPreview part = buildPreview(
                    source, effective, Set.of(scope), false);
            part.items().stream()
                    .filter(item -> !"target.required".equals(item.key()))
                    .forEach(items::add);
            if (effective != null) targets.put(scope, effective.id());
            if (effective == null && part.requiresTarget()) requiresTarget = true;
        }

        add(items, "organization.departmentManager",
                "仍担任部门负责人，须先在部门资料改负责人", "organization", count(
                        "SELECT count(*) FROM departments WHERE manager_id=:source AND is_deleted=false",
                        source.id()), DataHandoverAction.BLOCKING);
        long directReports = count(
                "SELECT count(*) FROM employees WHERE supervisor_id=:source AND is_deleted=false",
                source.id());
        add(items, "organization.supervisor", "直属下级上级关系", "organization",
                directReports, DataHandoverAction.TRANSFER);
        if (directReports > 0) {
            if (defaultTarget == null) {
                requiresTarget = true;
            } else {
                targets.put("organization", defaultTarget.id());
                add(items, "organization.supervisorCycle",
                        "默认接手人位于原下级链，转移会形成循环", "organization",
                        supervisorCycle(source.id(), defaultTarget.id()) ? 1 : 0,
                        DataHandoverAction.BLOCKING);
            }
        }
        add(items, "workflow.claims", "临时任务认领(自动释放，不转给接手人)",
                "workflow", count("""
                        SELECT (SELECT count(*) FROM task_claims
                                WHERE claimed_by=:source AND released_at IS NULL)
                             + (SELECT count(*) FROM hr_task_claims
                                WHERE claimed_by=:source AND released_at IS NULL)
                        """, source.id()), DataHandoverAction.RELEASE);
        add(items, "workflow.profileChanges", "待处理个人资料申请(自动驳回)",
                "workflow", count("""
                        SELECT count(*) FROM profile_change_requests
                        WHERE employee_id=:source AND status='pending'
                        """, source.id()), DataHandoverAction.RELEASE);
        add(items, "access.dataScopes", "离职账号的数据查看范围(自动清除)",
                "access", count("""
                        SELECT count(*) FROM user_data_scopes data_scope
                        JOIN users account ON account.id=data_scope.user_id
                        WHERE account.employee_id=:source
                        """, source.id()), DataHandoverAction.RELEASE);
        add(items, "access.attachmentUploads",
                "未完成附件上传会话(自动失效并清理暂存对象)", "access", count("""
                        SELECT count(*) FROM attachment_upload_sessions upload_session
                        JOIN users account ON account.id=upload_session.user_id
                        WHERE account.employee_id=:source
                          AND upload_session.status IN ('PENDING','SCANNING')
                        """, source.id()), DataHandoverAction.RELEASE);
        add(items, "access.clientViewerGrants", "作为其他客户可见人的权限(自动撤销)",
                "access", count("""
                        SELECT count(*) FROM client_visibility_grants
                        WHERE grantee_employee_id=:source AND active=true
                        """, source.id()), DataHandoverAction.RELEASE);
        add(items, "access.personalOverrides", "个人权限覆盖(自动停用，不随复职恢复)",
                "access", count("""
                        SELECT count(*) FROM user_permission_overrides permission_override
                        JOIN users account ON account.id=permission_override.user_id
                        WHERE account.employee_id=:source AND permission_override.active=true
                        """, source.id()), DataHandoverAction.RELEASE);
        add(items, "access.managerDelegations", "本人获得或发出的经理权限委派(自动停用)",
                "access", count("""
                        SELECT count(*) FROM manager_permission_delegations delegation
                        WHERE delegation.enabled=true AND (
                            delegation.user_id IN (
                                SELECT id FROM users WHERE employee_id=:source)
                            OR delegation.granted_by_user_id IN (
                                SELECT id FROM users WHERE employee_id=:source))
                        """, source.id()), DataHandoverAction.RELEASE);
        add(items, "access.accountHardening", "外网访问与复职凭据恢复保护",
                "access", count("""
                        SELECT count(*) FROM users
                        WHERE employee_id=:source AND is_deleted=false
                          AND (remote_access=true OR must_change_password=false
                               OR temp_password_expires_at IS NOT NULL)
                        """, source.id()), DataHandoverAction.RELEASE);

        if (requiresTarget) {
            add(items, "target.required", "存在需交接的数据，请选择默认接手人",
                    "all", 1, DataHandoverAction.BLOCKING);
        }
        return previewResult(source.id(),
                defaultTarget == null ? null : defaultTarget.id(),
                new LinkedHashSet<>(ALL_SCOPES), items, requiresTarget, targets);
    }

    private EmployeeFact existingEligibleSuccessor(UUID sourceId, String scope) {
        UUID current = handoverVisibility.currentResponsible(scope, sourceId);
        if (current == null || current.equals(sourceId)) return null;
        try {
            EmployeeFact target = employee(current, false);
            if (!CurrentEmployeeStatusPolicy.isCurrentEmployee(target.status())) return null;
            if ("production_plan".equals(scope)
                    && !Set.of("active", "probation").contains(target.status())) return null;
            if (account(target.id(), false)
                    .filter(value -> "active".equals(value.status()) && !value.deleted())
                    .isEmpty()) return null;
            return target;
        } catch (ApiException ignored) {
            return null;
        }
    }

    private DataHandoverPreview previewResult(
            UUID sourceId, UUID targetId, Set<String> scopes,
            List<DataHandoverPreviewItem> items, boolean requiresTarget,
            Map<String, UUID> targets) {
        long transfer = actionCount(items, DataHandoverAction.TRANSFER);
        long history = actionCount(items, DataHandoverAction.HISTORY_ACCESS);
        long release = actionCount(items, DataHandoverAction.RELEASE);
        long blocking = items.stream()
                .filter(item -> item.action() == DataHandoverAction.BLOCKING)
                .filter(item -> !"target.required".equals(item.key()))
                .mapToLong(DataHandoverPreviewItem::count).sum();
        long total = transfer + history + release + blocking;
        boolean hasBlockers = items.stream().anyMatch(item -> item.count() > 0
                && item.action() == DataHandoverAction.BLOCKING);
        return new DataHandoverPreview(
                sourceId, targetId, Collections.unmodifiableSet(new LinkedHashSet<>(scopes)),
                List.copyOf(items), hasBlockers, requiresTarget,
                transfer, history, release, blocking, total,
                Collections.unmodifiableMap(new LinkedHashMap<>(targets)),
                targetNames(targets));
    }

    private Map<String, String> targetNames(Map<String, UUID> targets) {
        if (targets == null || targets.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, full_name FROM employees
                        WHERE id IN (:ids) AND is_deleted=false
                        """)
                .setParameter("ids", new LinkedHashSet<>(targets.values()))
                .getResultList();
        Map<UUID, String> byId = new LinkedHashMap<>();
        rows.forEach(row -> byId.put(uuid(row[0]), text(row[1])));
        Map<String, String> result = new LinkedHashMap<>();
        targets.forEach((scope, employeeId) ->
                result.put(scope, byId.getOrDefault(employeeId, "")));
        return Collections.unmodifiableMap(result);
    }

    private static long actionCount(
            List<DataHandoverPreviewItem> items, DataHandoverAction action) {
        return items.stream().filter(item -> item.action() == action)
                .mapToLong(DataHandoverPreviewItem::count).sum();
    }

    private Map<String, Long> applyTransfers(
            EmployeeFact source, EmployeeFact target, AccountFact targetAccount,
            UUID actorUserId, UUID actorEmployeeId, Set<String> scopes, String reason,
            DataHandoverPreview preview, boolean includeWholePersonExtras,
            boolean retainSourceClientViewer) {
        Map<String, Long> expected = new LinkedHashMap<>();
        for (DataHandoverPreviewItem item : preview.items()) {
            if (item.action() == DataHandoverAction.TRANSFER
                    || item.action() == DataHandoverAction.RELEASE) {
                expected.put(item.key(), item.count());
            }
        }
        Map<String, Long> result = new LinkedHashMap<>();
        if (scopes.contains("client")) {
            ClientHandoverEventRecorder.TransferOutcome clientOutcome = clientEvents.transfer(
                    source.id(), target.id(), target.legacyId(), actorUserId, reason,
                    retainSourceClientViewer);
            changed("client.owner", clientOutcome.clientOwnerCount(), expected, result);
            changed("client.scopeDelegations", clientOutcome.scopeDelegationCount(),
                    expected, result);
        }
        if (scopes.contains("goods")) {
            changed("goods.owner", update("""
                    UPDATE goods SET owner_employee_id=:target, version=version+1,
                        updated_at=now(), updated_by=:actor
                    WHERE owner_employee_id=:source AND is_deleted=false
                    """, source.id(), target, targetAccount, actorUserId), expected, result);
            changed("mould.keeper", update("""
                    UPDATE moulds SET keeper_id=:target, keeper=:targetName,
                        updated_at=now(), updated_by=:actor
                    WHERE keeper_id=:source AND is_deleted=false
                    """, source.id(), target, targetAccount, actorUserId), expected, result);
        }
        if (scopes.contains("purchase")) {
            changed("supplier.owner", update("""
                    UPDATE suppliers SET owner_employee_id=:target, emp_id=:legacy,
                        version=version+1, updated_at=now(), updated_by=:actor
                    WHERE owner_employee_id=:source AND is_deleted=false
                    """, source.id(), target, targetAccount, actorUserId), expected, result);
            changed("supplierReturn.purchase", updateReturnTasks(
                    source.id(), target.id(), targetAccount.userId(), "PURCHASE"), expected, result);
            changed("inboundExpectation.purchase", updateInboundExpectations(
                    source.id(), target.id(), "PURCHASE"), expected, result);
            changed("arrivalException.purchase", updateArrivalExceptions(
                    source.id(), target, targetAccount, "PURCHASE"), expected, result);
        }
        if (scopes.contains("subcontract")) {
            changed("supplierReturn.subcontract", updateReturnTasks(
                    source.id(), target.id(), targetAccount.userId(), "SUBCONTRACT"), expected, result);
            changed("inboundExpectation.subcontract", updateInboundExpectations(
                    source.id(), target.id(), "SUBCONTRACT"), expected, result);
            changed("arrivalException.subcontract", updateArrivalExceptions(
                    source.id(), target, targetAccount, "SUBCONTRACT"), expected, result);
        }
        if (scopes.contains("sales")) {
            changed("websiteInquiry.assignee", update("""
                    UPDATE website_inquiries SET assignee_employee_id=:target,
                        updated_at=now(), updated_by=:actor
                    WHERE assignee_employee_id=:source AND status IN ('new','following')
                    """, source.id(), target, targetAccount, actorUserId), expected, result);
            changed("visitor.host", update("""
                    UPDATE visitor_applications SET host_employee_id=:target,
                        host_department_id=:targetDepartment, updated_at=now(), updated_by=:actor
                    WHERE host_employee_id=:source AND status IN ('pending','hostReviewing')
                      AND planned_visit_at > current_timestamp AND is_deleted=false
                    """, source.id(), target, targetAccount, actorUserId), expected, result);
        }
        if (scopes.contains("production_plan")) {
            changed("rdTask.assignee", update("""
                    UPDATE rd_tasks SET assignee_employee_id=:target, row_version=row_version+1,
                        updated_at=now(), updated_by=:actor
                    WHERE assignee_employee_id=:source AND status IN ('OPEN','IN_PROGRESS') AND is_deleted=false
                    """, source.id(), target, targetAccount, actorUserId), expected, result);
            changed("productionPlan.worker", update("""
                    UPDATE production_plans
                    SET seller_id=CASE WHEN seller_id=:source THEN :target ELSE seller_id END,
                        worker_id=CASE WHEN worker_id=:source THEN :target ELSE worker_id END,
                        updated_at=now(), updated_by=:actor
                    WHERE status=0 AND is_deleted=false AND (seller_id=:source OR worker_id=:source)
                    """, source.id(), target, targetAccount, actorUserId), expected, result);
            changed("productionSegment.assignable", updateCompatibleSegments(
                    source.id(), target.id(), actorUserId), expected, result);
        }
        if (includeWholePersonExtras && scopes.equals(ALL_SCOPE_SET)) {
            changed("organization.supervisor", update("""
                    UPDATE employees SET supervisor_id=:target, version=version+1,
                        updated_at=now(), updated_by=:actor
                    WHERE supervisor_id=:source AND is_deleted=false
                    """, source.id(), target, targetAccount, actorUserId), expected, result);
            long released = releaseClaims(source.id(), actorUserId, actorEmployeeId);
            changed("workflow.claims", released, expected, result);
        }
        preview.items().stream()
                .filter(item -> item.action() == DataHandoverAction.HISTORY_ACCESS)
                .forEach(item -> result.put(item.key(), item.count()));
        result.put("total", result.values().stream().mapToLong(Long::longValue).sum());
        return Collections.unmodifiableMap(result);
    }

    private Map<String, Long> applyOffboardingExtras(
            EmployeeFact source, EmployeeFact defaultTarget,
            UUID actorUserId, UUID actorEmployeeId, DataHandoverPreview preview) {
        Map<String, Long> expected = new LinkedHashMap<>();
        preview.items().stream()
                .filter(item -> item.action() == DataHandoverAction.TRANSFER
                        || item.action() == DataHandoverAction.RELEASE)
                .forEach(item -> expected.put(item.key(), item.count()));
        Map<String, Long> result = new LinkedHashMap<>();
        if (expected.getOrDefault("organization.supervisor", 0L) > 0) {
            if (defaultTarget == null) throw conflict("直属下级仍需指定默认接手人");
            changed("organization.supervisor", update("""
                    UPDATE employees SET supervisor_id=:target, version=version+1,
                        updated_at=now(), updated_by=:actor
                    WHERE supervisor_id=:source AND is_deleted=false
                    """, source.id(), defaultTarget,
                    activeAccount(defaultTarget.id(), false), actorUserId), expected, result);
        }
        changed("workflow.claims",
                releaseClaims(source.id(), actorUserId, actorEmployeeId), expected, result);
        changed("workflow.profileChanges",
                rejectPendingProfileChanges(source.id(), actorEmployeeId, actorUserId),
                expected, result);
        changed("access.personalOverrides",
                disablePersonalOverrides(source.id()), expected, result);
        changed("access.managerDelegations",
                disableManagerDelegations(source.id(), actorUserId), expected, result);
        changed("access.accountHardening",
                hardenDepartingAccount(source.id()), expected, result);
        changed("access.dataScopes", deleteDataScopes(source.id()), expected, result);
        changed("access.attachmentUploads",
                expireAttachmentUploadSessions(source.id()), expected, result);
        changed("access.clientViewerGrants",
                clientEvents.revokeViewerForOffboarding(
                        source.id(), actorUserId,
                        "员工离职：撤销离职员工的客户只读可见权限"),
                expected, result);
        return result;
    }

    private int update(String sql, UUID sourceId, EmployeeFact target,
                       AccountFact targetAccount, UUID actorUserId) {
        Query query = em.createNativeQuery(sql)
                .setParameter("source", sourceId)
                .setParameter("target", target.id())
                .setParameter("actor", actorUserId);
        if (sql.contains(":legacy")) query.setParameter("legacy", target.legacyId() == null ? null : target.legacyId().toString());
        if (sql.contains(":targetName")) query.setParameter("targetName", target.name());
        if (sql.contains(":targetDepartment")) query.setParameter("targetDepartment", target.departmentId());
        return query.executeUpdate();
    }

    private int updateInboundExpectations(UUID sourceId, UUID targetId, String type) {
        return em.createNativeQuery("""
                        UPDATE inbound_expectations
                        SET owner_employee_id=:target, updated_at=now()
                        WHERE owner_employee_id=:source AND order_type=:type AND status='OPEN'
                        """)
                .setParameter("target", targetId)
                .setParameter("source", sourceId)
                .setParameter("type", type)
                .executeUpdate();
    }

    private int updateArrivalExceptions(
            UUID sourceId, EmployeeFact target, AccountFact targetAccount, String type) {
        return em.createNativeQuery("""
                        UPDATE procurement_arrival_exceptions
                        SET owner_user_id=:targetUser, owner_employee_id=:target,
                            owner_name_snapshot=:targetName, version=version+1, updated_at=now()
                        WHERE owner_employee_id=:source AND order_type=:type
                          AND status NOT IN ('CLOSED','CANCELED')
                        """)
                .setParameter("targetUser", targetAccount.userId())
                .setParameter("target", target.id())
                .setParameter("targetName", target.name())
                .setParameter("source", sourceId)
                .setParameter("type", type)
                .executeUpdate();
    }

    private int updateReturnTasks(UUID sourceId, UUID targetId, UUID targetUserId, String type) {
        return em.createNativeQuery("""
                        UPDATE supplier_return_tasks
                        SET owner_user_id=:targetUser, owner_employee_id=:target,
                            version=version+1, updated_at=now()
                        WHERE owner_employee_id=:source AND order_type=:type AND status='PENDING_RETURN'
                        """)
                .setParameter("targetUser", targetUserId).setParameter("target", targetId)
                .setParameter("source", sourceId).setParameter("type", type).executeUpdate();
    }

    private int updateCompatibleSegments(UUID sourceId, UUID targetId, UUID actorUserId) {
        return em.createNativeQuery("""
                        UPDATE production_execution_segments segment
                        SET responsible_employee_id=:target, updated_by=:actor
                        WHERE segment.responsible_employee_id=:source
                          AND segment.status IN ('READY','WAITING') AND segment.is_deleted=false
                          AND EXISTS (
                              SELECT 1
                              FROM employees target_employee
                              JOIN departments target_department
                                ON target_department.id=target_employee.department_id
                               AND target_department.is_deleted=false
                              LEFT JOIN departments team
                                ON team.id=segment.team_department_id AND team.is_deleted=false
                              LEFT JOIN departments workshop
                                ON workshop.id=segment.workshop_department_id AND workshop.is_deleted=false
                              WHERE target_employee.id=:target AND target_employee.is_deleted=false
                                AND target_employee.status IN ('active','probation')
                                AND ((segment.team_department_id IS NOT NULL
                                      AND target_department.path LIKE team.path || '%')
                                  OR (segment.team_department_id IS NULL
                                      AND segment.workshop_department_id IS NOT NULL
                                      AND target_department.path LIKE workshop.path || '%')
                                  OR (segment.team_department_id IS NULL
                                      AND segment.workshop_department_id IS NULL))
                          )
                        """)
                .setParameter("target", targetId).setParameter("actor", actorUserId)
                .setParameter("source", sourceId).executeUpdate();
    }

    private long releaseClaims(UUID sourceId, UUID actorUserId, UUID actorEmployeeId) {
        int common = em.createNativeQuery("""
                        UPDATE task_claims SET released_at=now(), released_by=:actorEmployee,
                            release_reason='employee_handover', updated_at=now(), updated_by=:actorUser
                        WHERE claimed_by=:source AND released_at IS NULL
                        """)
                .setParameter("actorEmployee", actorEmployeeId).setParameter("actorUser", actorUserId)
                .setParameter("source", sourceId).executeUpdate();
        int hr = em.createNativeQuery("""
                        UPDATE hr_task_claims SET released_at=now(),
                            remark=CASE WHEN remark IS NULL OR btrim(remark)='' THEN '人员数据交接自动释放'
                                ELSE remark || E'\n人员数据交接自动释放' END,
                            updated_at=now(), updated_by=:actorUser
                        WHERE claimed_by=:source AND released_at IS NULL
                        """)
                .setParameter("actorUser", actorUserId).setParameter("source", sourceId).executeUpdate();
        return (long) common + hr;
    }

    private long compatibleSegments(UUID sourceId, UUID targetId) {
        return countWithTarget("""
                SELECT count(*) FROM production_execution_segments segment
                JOIN employees target_employee ON target_employee.id=:target AND target_employee.is_deleted=false
                JOIN departments target_department ON target_department.id=target_employee.department_id
                    AND target_department.is_deleted=false
                LEFT JOIN departments team ON team.id=segment.team_department_id AND team.is_deleted=false
                LEFT JOIN departments workshop ON workshop.id=segment.workshop_department_id AND workshop.is_deleted=false
                WHERE segment.responsible_employee_id=:source
                  AND segment.status IN ('READY','WAITING') AND segment.is_deleted=false
                  AND target_employee.status IN ('active','probation')
                  AND ((segment.team_department_id IS NOT NULL AND target_department.path LIKE team.path || '%')
                    OR (segment.team_department_id IS NULL AND segment.workshop_department_id IS NOT NULL
                        AND target_department.path LIKE workshop.path || '%')
                    OR (segment.team_department_id IS NULL AND segment.workshop_department_id IS NULL))
                """, sourceId, targetId);
    }

    private boolean supervisorCycle(UUID sourceId, UUID targetId) {
        return countWithTarget("""
                WITH RECURSIVE descendants(id) AS (
                    SELECT id FROM employees WHERE supervisor_id=:source AND is_deleted=false
                    UNION
                    SELECT employee.id FROM employees employee
                    JOIN descendants parent ON employee.supervisor_id=parent.id
                    WHERE employee.is_deleted=false
                )
                SELECT count(*) FROM descendants WHERE id=:target
                """, sourceId, targetId) > 0;
    }

    private boolean handoverGraphCycle(UUID sourceId, UUID targetId, String scope) {
        Number count = (Number) em.createNativeQuery("""
                        WITH RECURSIVE ranked_edges AS (
                            SELECT handover.source_employee_id,
                                   handover.target_employee_id,
                                   handover.target_employment_generation,
                                   row_number() OVER (
                                       PARTITION BY handover.source_employee_id
                                       ORDER BY handover.sequence_no DESC) AS position
                            FROM employee_data_handovers handover
                            JOIN employee_data_handover_scopes handover_scope
                              ON handover_scope.handover_id=handover.id
                            JOIN employees source_employee
                              ON source_employee.id=handover.source_employee_id
                             AND source_employee.is_deleted=false
                            WHERE handover.status='COMPLETED'
                              AND handover_scope.scope=:scope
                              AND handover.source_employment_generation=(
                                  SELECT count(*) FROM employment_history history
                                  WHERE history.employee_id=handover.source_employee_id
                                    AND history.event_type='rehire')
                        ), latest_edges AS (
                            SELECT ranked.source_employee_id, ranked.target_employee_id
                            FROM ranked_edges ranked
                            JOIN employees target_employee
                              ON target_employee.id=ranked.target_employee_id
                             AND target_employee.is_deleted=false
                            WHERE ranked.position=1
                              AND ranked.target_employment_generation=(
                                  SELECT count(*) FROM employment_history history
                                  WHERE history.employee_id=ranked.target_employee_id
                                    AND history.event_type='rehire')
                        ), reachable(employee_id) AS (
                            SELECT CAST(:target AS uuid)
                            UNION
                            SELECT edge.target_employee_id
                            FROM latest_edges edge
                            JOIN reachable prior ON prior.employee_id=edge.source_employee_id
                        )
                        SELECT count(*) FROM reachable WHERE employee_id=:source
                        """)
                .setParameter("scope", scope)
                .setParameter("target", targetId)
                .setParameter("source", sourceId)
                .getSingleResult();
        return count.longValue() > 0;
    }

    private Set<UUID> dataScopeRecipientEmployeeIds(
            UUID sourceId, Collection<String> scopes) {
        if (scopes == null || !scopes.contains("client")) return Set.of();
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery("""
                        SELECT DISTINCT recipient.employee_id
                        FROM user_data_scopes data_scope
                        JOIN users recipient ON recipient.id=data_scope.user_id
                        WHERE data_scope.owner_employee_id=:source
                          AND data_scope.scope='client'
                          AND data_scope.owner_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=data_scope.owner_employee_id
                                AND history.event_type='rehire')
                          AND recipient.employee_id IS NOT NULL
                        ORDER BY recipient.employee_id
                        """)
                .setParameter("source", sourceId)
                .getResultList();
        LinkedHashSet<UUID> result = new LinkedHashSet<>();
        rows.forEach(value -> result.add(uuid(value)));
        return Collections.unmodifiableSet(result);
    }

    private long historicalDocumentCount(String scope, UUID sourceId) {
        String sql = switch (scope) {
            case "sales" -> """
                    SELECT (SELECT count(*) FROM sales_quotes WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM sales_orders WHERE owner_employee_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM sales_shipments WHERE owner_employee_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM sales_other_shipments WHERE owner_employee_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM sales_returns WHERE owner_employee_id=:source AND is_deleted=false)
                    """;
            case "finance" -> """
                    SELECT (SELECT count(*) FROM finance_payments WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM finance_receipts WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM finance_expenses WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM finance_bank_transfers WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM finance_other_incomes WHERE maker_id=:source AND is_deleted=false)
                    """;
            case "purchase" -> """
                    SELECT (SELECT count(*) FROM purchase_orders WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM purchase_receipts WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM purchase_returns WHERE maker_id=:source AND is_deleted=false)
                    """;
            case "subcontract" -> """
                    SELECT (SELECT count(*) FROM subcontract_orders WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM subcontract_inquiries WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM subcontract_material_issues WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM subcontract_material_returns WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM subcontract_receipts WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM subcontract_returns WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM subcontract_wastes WHERE maker_id=:source AND is_deleted=false)
                    """;
            case "production_plan" -> """
                    SELECT (SELECT count(*) FROM production_plans WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM production_daily_reports WHERE maker_id=:source AND is_deleted=false)
                         + (SELECT count(*) FROM production_material_analyses
                            WHERE maker_id=:source AND is_deleted=false)
                    """;
            case "stock_doc" -> "SELECT count(*) FROM stock_documents WHERE maker_id=:source AND is_deleted=false";
            default -> null;
        };
        return sql == null ? 0 : count(sql, sourceId);
    }

    private void lockResponsibilityRows(
            UUID sourceId, Set<String> scopes, boolean includeWholePersonExtras) {
        if (scopes.contains("client")) lock("SELECT id FROM clients WHERE owner_employee_id=:source AND is_deleted=false ORDER BY id FOR UPDATE", sourceId);
        if (scopes.contains("goods")) {
            lock("SELECT id FROM goods WHERE owner_employee_id=:source AND is_deleted=false ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM moulds WHERE keeper_id=:source AND is_deleted=false ORDER BY id FOR UPDATE", sourceId);
        }
        if (scopes.contains("purchase")) {
            lock("SELECT id FROM suppliers WHERE owner_employee_id=:source AND is_deleted=false ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM inbound_expectations WHERE owner_employee_id=:source AND order_type='PURCHASE' AND status='OPEN' ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM procurement_arrival_exceptions WHERE owner_employee_id=:source AND order_type='PURCHASE' AND status NOT IN ('CLOSED','CANCELED') ORDER BY id FOR UPDATE", sourceId);
        }
        if (scopes.contains("subcontract")) {
            lock("SELECT id FROM inbound_expectations WHERE owner_employee_id=:source AND order_type='SUBCONTRACT' AND status='OPEN' ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM procurement_arrival_exceptions WHERE owner_employee_id=:source AND order_type='SUBCONTRACT' AND status NOT IN ('CLOSED','CANCELED') ORDER BY id FOR UPDATE", sourceId);
        }
        if (scopes.contains("purchase") || scopes.contains("subcontract")) lock("SELECT id FROM supplier_return_tasks WHERE owner_employee_id=:source AND status='PENDING_RETURN' ORDER BY id FOR UPDATE", sourceId);
        if (scopes.contains("sales")) {
            lock("SELECT id FROM website_inquiries WHERE assignee_employee_id=:source AND status IN ('new','following') ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM visitor_applications WHERE host_employee_id=:source AND status IN ('pending','hostReviewing','approved') AND planned_visit_at>current_timestamp ORDER BY id FOR UPDATE", sourceId);
        }
        if (scopes.contains("production_plan")) {
            lock("SELECT id FROM rd_tasks WHERE assignee_employee_id=:source AND status IN ('OPEN','IN_PROGRESS') ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM production_plans WHERE status=0 AND (seller_id=:source OR worker_id=:source) ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM production_execution_segments WHERE responsible_employee_id=:source AND status IN ('READY','WAITING','DISPATCHED','IN_PROGRESS') ORDER BY id FOR UPDATE", sourceId);
        }
        if (scopes.contains("finance")) {
            lock("SELECT id FROM fixed_assets WHERE custodian_employee_id=:source AND lifecycle_status<>'DISPOSED' ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM deferred_expenses WHERE responsible_employee_id=:source AND lifecycle_status NOT IN ('COMPLETED','TERMINATED') ORDER BY id FOR UPDATE", sourceId);
        }
        if (includeWholePersonExtras && scopes.equals(ALL_SCOPE_SET)) {
            lock("SELECT id FROM departments WHERE manager_id=:source AND is_deleted=false ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM employees WHERE supervisor_id=:source AND is_deleted=false ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM task_claims WHERE claimed_by=:source AND released_at IS NULL ORDER BY id FOR UPDATE", sourceId);
            lock("SELECT id FROM hr_task_claims WHERE claimed_by=:source AND released_at IS NULL ORDER BY id FOR UPDATE", sourceId);
        }
    }

    private void lockOffboardingExtraRows(UUID sourceId) {
        lock("SELECT id FROM departments WHERE manager_id=:source AND is_deleted=false ORDER BY id FOR UPDATE", sourceId);
        lock("SELECT id FROM employees WHERE supervisor_id=:source AND is_deleted=false ORDER BY id FOR UPDATE", sourceId);
        lock("SELECT id FROM task_claims WHERE claimed_by=:source AND released_at IS NULL ORDER BY id FOR UPDATE", sourceId);
        lock("SELECT id FROM hr_task_claims WHERE claimed_by=:source AND released_at IS NULL ORDER BY id FOR UPDATE", sourceId);
        lock("SELECT id FROM profile_change_requests WHERE employee_id=:source AND status='pending' ORDER BY id FOR UPDATE", sourceId);
        lock("""
                SELECT upload_session.id FROM attachment_upload_sessions upload_session
                JOIN users account ON account.id=upload_session.user_id
                WHERE account.employee_id=:source
                  AND upload_session.status IN ('PENDING','SCANNING')
                ORDER BY upload_session.id FOR UPDATE OF upload_session
                """, sourceId);
    }

    private void lock(String sql, UUID sourceId) {
        em.createNativeQuery(sql).setParameter("source", sourceId).getResultList();
    }

    private void lockEmployeeRows(Collection<UUID> employeeIds) {
        if (employeeIds == null || employeeIds.isEmpty()) return;
        em.createNativeQuery("""
                        SELECT id FROM employees
                        WHERE id IN (:employeeIds) AND is_deleted=false
                        ORDER BY id FOR UPDATE
                        """)
                .setParameter("employeeIds", employeeIds)
                .getResultList();
    }

    private void lockAccounts(Collection<UUID> employeeIds) {
        if (employeeIds == null || employeeIds.isEmpty()) return;
        em.createNativeQuery("""
                        SELECT id FROM users
                        WHERE employee_id IN (:employeeIds)
                        ORDER BY id FOR UPDATE
                        """)
                .setParameter("employeeIds", employeeIds)
                .getResultList();
    }

    private LockedPair lockEmployees(UUID sourceId, UUID targetId) {
        List<UUID> ids = new ArrayList<>(List.of(sourceId, targetId));
        ids.sort(UUID::compareTo);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, status, legacy_id, full_name, department_id
                        FROM employees WHERE id IN (:ids) AND is_deleted=false
                        ORDER BY id FOR UPDATE
                        """).setParameter("ids", ids).getResultList();
        Map<UUID, EmployeeFact> facts = new LinkedHashMap<>();
        for (Object[] row : rows) {
            EmployeeFact fact = employeeFact(row);
            facts.put(fact.id(), fact);
        }
        EmployeeFact source = facts.get(sourceId);
        EmployeeFact target = facts.get(targetId);
        if (source == null) throw new ApiException(ErrorCode.NOT_FOUND, "交接员工不存在");
        if (target == null) throw new ApiException(ErrorCode.NOT_FOUND, "接手员工不存在");
        return new LockedPair(source, target);
    }

    private EmployeeFact employee(UUID id, boolean forUpdate) {
        String lock = forUpdate ? " FOR UPDATE" : "";
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, status, legacy_id, full_name, department_id
                        FROM employees WHERE id=:id AND is_deleted=false
                        """ + lock).setParameter("id", id).getResultList();
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "员工不存在");
        return employeeFact(rows.getFirst());
    }

    private EmployeeFact employeeFact(Object[] row) {
        return new EmployeeFact(uuid(row[0]), text(row[1]),
                row[2] == null ? null : ((Number) row[2]).intValue(), text(row[3]), uuid(row[4]));
    }

    private EmployeeFact eligibleTarget(UUID id, boolean forUpdate) {
        return requireEligibleTarget(employee(id, forUpdate), false);
    }

    private EmployeeFact requireEligibleTarget(EmployeeFact target, boolean accountAlreadyLockedLater) {
        if (!CurrentEmployeeStatusPolicy.isCurrentEmployee(target.status())) {
            throw validation("接手人必须是在职、试用或留职停薪员工");
        }
        if (!accountAlreadyLockedLater) activeAccount(target.id(), false);
        return target;
    }

    private AccountFact activeAccount(UUID employeeId, boolean forUpdate) {
        return account(employeeId, forUpdate)
                .filter(account -> "active".equals(account.status()) && !account.deleted())
                .orElseThrow(() -> validation("接手人必须有正常可用的登录账号"));
    }

    private Optional<AccountFact> account(UUID employeeId, boolean forUpdate) {
        String lock = forUpdate ? " FOR UPDATE" : "";
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, status, is_deleted FROM users WHERE employee_id=:employeeId
                        """ + lock).setParameter("employeeId", employeeId).getResultList();
        if (rows.isEmpty()) return Optional.empty();
        Object[] row = rows.getFirst();
        return Optional.of(new AccountFact(uuid(row[0]), text(row[1]), Boolean.TRUE.equals(row[2])));
    }

    private Optional<DataHandoverResult> replay(
            DataHandoverRequest request, String mode, String reason, Set<String> scopes,
            long sourceEmploymentGeneration, long targetEmploymentGeneration) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, sequence_no, source_employee_id, target_employee_id, mode,
                               effective_date, reason, source_employment_generation,
                               target_employment_generation,
                               status, result_summary,
                               array_to_string(requested_scopes, ',')
                        FROM employee_data_handovers WHERE request_id=:requestId
                        """).setParameter("requestId", request.requestId()).getResultList();
        if (rows.isEmpty()) return Optional.empty();
        Object[] row = rows.getFirst();
        UUID id = uuid(row[0]);
        Set<String> requestedScopes = scopesFromCsv(text(row[11]));
        boolean same = request.sourceEmployeeId().equals(uuid(row[2]))
                && request.targetEmployeeId().equals(uuid(row[3]))
                && mode.equals(text(row[4]))
                && request.effectiveDate().equals(localDate(row[5]))
                && reason.equals(text(row[6]))
                && sourceEmploymentGeneration == ((Number) row[7]).longValue()
                && targetEmploymentGeneration == ((Number) row[8]).longValue()
                && scopes.equals(requestedScopes);
        if (!same) throw conflict("requestId 已用于不同的数据交接请求");
        if (!"COMPLETED".equals(text(row[9]))) throw conflict("同一交接请求正在执行");
        return Optional.of(new DataHandoverResult(
                id, ((Number) row[1]).longValue(), request.requestId(),
                request.sourceEmployeeId(), request.targetEmployeeId(), mode, "COMPLETED",
                requestedScopes, summary(row[10]), true));
    }

    private Set<String> effectiveGraphScopes(
            DataHandoverPreview preview, Set<String> requestedScopes) {
        LinkedHashSet<String> effective = new LinkedHashSet<>();
        for (String scope : requestedScopes) {
            boolean hasGraphAuthority = preview.items().stream().anyMatch(item ->
                    scope.equals(item.scope()) && item.count() > 0
                            && (item.action() == DataHandoverAction.HISTORY_ACCESS
                            || item.action() == DataHandoverAction.TRANSFER
                            && !"client.scopeDelegations".equals(item.key())));
            if (hasGraphAuthority) effective.add(scope);
        }
        return Collections.unmodifiableSet(effective);
    }

    private static String textArrayLiteral(Collection<String> values) {
        if (values == null || values.isEmpty()) return "{}";
        return "{" + String.join(",", values) + "}";
    }

    private Set<String> scopesFromCsv(String csv) {
        if (csv == null || csv.isBlank()) return Set.of();
        LinkedHashSet<String> values = new LinkedHashSet<>();
        for (String value : csv.split(",")) {
            if (!value.isBlank()) values.add(value);
        }
        return Collections.unmodifiableSet(values);
    }

    private Set<String> storedScopes(UUID handoverId) {
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery("""
                        SELECT scope FROM employee_data_handover_scopes
                        WHERE handover_id=:id ORDER BY scope
                        """).setParameter("id", handoverId).getResultList();
        LinkedHashSet<String> scopes = new LinkedHashSet<>();
        rows.forEach(row -> scopes.add(text(row)));
        return Collections.unmodifiableSet(scopes);
    }

    private void handoverCoordinatorLock() {
        em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended('employee-data-handover-coordinator', 0))
                        """)
                .getSingleResult();
    }

    private void advisoryLock(UUID requestId) {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(CAST(:id AS text), 0))")
                .setParameter("id", requestId).getSingleResult();
    }

    private Set<String> normalizeExecutionScopes(Collection<String> requested) {
        if (requested == null || requested.isEmpty()) {
            throw validation("人工交接必须明确选择至少一个数据范围");
        }
        for (String scope : requested) {
            if (scope == null || scope.isBlank()) {
                throw validation("人工交接范围不能为空");
            }
        }
        return normalizeScopes(requested);
    }

    private Set<String> normalizeScopes(Collection<String> requested) {
        if (requested == null || requested.isEmpty()) {
            return Collections.unmodifiableSet(new LinkedHashSet<>(ALL_SCOPES));
        }
        LinkedHashSet<String> normalized = new LinkedHashSet<>();
        for (String raw : requested) {
            if (raw == null || raw.isBlank()) continue;
            String scope = raw.trim().toLowerCase(Locale.ROOT);
            if (!ALL_SCOPE_SET.contains(scope)) throw validation("未知交接范围: " + raw);
            normalized.add(scope);
        }
        if (normalized.isEmpty()) return Collections.unmodifiableSet(new LinkedHashSet<>(ALL_SCOPES));
        LinkedHashSet<String> ordered = new LinkedHashSet<>();
        ALL_SCOPES.stream().filter(normalized::contains).forEach(ordered::add);
        return Collections.unmodifiableSet(ordered);
    }

    private long count(String sql, UUID sourceId) {
        return ((Number) em.createNativeQuery(sql).setParameter("source", sourceId).getSingleResult()).longValue();
    }

    private long countWithTarget(String sql, UUID sourceId, UUID targetId) {
        return ((Number) em.createNativeQuery(sql).setParameter("source", sourceId)
                .setParameter("target", targetId).getSingleResult()).longValue();
    }

    private static void add(List<DataHandoverPreviewItem> items, String key, String label,
                            String scope, long count, DataHandoverAction action) {
        if (count > 0) items.add(new DataHandoverPreviewItem(key, label, scope, count, action));
    }

    private static void changed(String key, long actual, Map<String, Long> expected,
                                Map<String, Long> result) {
        long anticipated = expected.getOrDefault(key, 0L);
        if (actual != anticipated) {
            throw conflict("交接预览后数据已变化(" + key + ")，请刷新后重试");
        }
        if (actual > 0) result.put(key, actual);
    }

    private int disablePersonalOverrides(UUID sourceEmployeeId) {
        return em.createNativeQuery("""
                        UPDATE user_permission_overrides permission_override
                        SET active=false, row_version=row_version+1
                        WHERE permission_override.active=true
                          AND permission_override.user_id IN (
                              SELECT id FROM users WHERE employee_id=:source)
                        """)
                .setParameter("source", sourceEmployeeId)
                .executeUpdate();
    }

    private int disableManagerDelegations(
            UUID sourceEmployeeId, UUID actorUserId) {
        return em.createNativeQuery("""
                        UPDATE manager_permission_delegations delegation
                        SET enabled=false, row_version=row_version+1,
                            updated_by=:actorUserId
                        WHERE delegation.enabled=true AND (
                            delegation.user_id IN (
                                SELECT id FROM users WHERE employee_id=:source)
                            OR delegation.granted_by_user_id IN (
                                SELECT id FROM users WHERE employee_id=:source))
                        """)
                .setParameter("source", sourceEmployeeId)
                .setParameter("actorUserId", actorUserId)
                .executeUpdate();
    }

    private int hardenDepartingAccount(UUID sourceEmployeeId) {
        return em.createNativeQuery("""
                        UPDATE users
                        SET remote_access=false, must_change_password=true,
                            temp_password_expires_at=NULL
                        WHERE employee_id=:source AND is_deleted=false
                          AND (remote_access=true OR must_change_password=false
                               OR temp_password_expires_at IS NOT NULL)
                        """)
                .setParameter("source", sourceEmployeeId)
                .executeUpdate();
    }

    private int deleteDataScopes(UUID sourceEmployeeId) {
        return account(sourceEmployeeId, false)
                .map(value -> em.createNativeQuery(
                                "DELETE FROM user_data_scopes WHERE user_id=:userId")
                        .setParameter("userId", value.userId())
                        .executeUpdate())
                .orElse(0);
    }

    private int expireAttachmentUploadSessions(UUID sourceEmployeeId) {
        return em.createNativeQuery("""
                        UPDATE attachment_upload_sessions upload_session
                        SET status='EXPIRED',
                            last_failure_code='EXPIRY_CLEANUP_PENDING',
                            completed_at=now(), updated_at=now()
                        WHERE upload_session.status IN ('PENDING','SCANNING')
                          AND upload_session.user_id IN (
                              SELECT id FROM users WHERE employee_id=:source)
                        """)
                .setParameter("source", sourceEmployeeId)
                .executeUpdate();
    }

    private int rejectPendingProfileChanges(
            UUID sourceEmployeeId, UUID actorEmployeeId, UUID actorUserId) {
        return em.createNativeQuery("""
                        UPDATE profile_change_requests
                        SET status='rejected', reviewed_by=:actorEmployee,
                            reviewed_at=now(), review_comment='员工离职，申请自动驳回',
                            updated_at=now()
                        WHERE employee_id=:source AND status='pending'
                        """)
                .setParameter("actorEmployee", actorEmployeeId)
                .setParameter("source", sourceEmployeeId)
                .executeUpdate();
    }

    private static void mergeSummary(
            Map<String, Long> destination, Map<String, Long> addition) {
        if (addition == null) return;
        addition.forEach((key, value) -> {
            if (!"total".equals(key) && value != null) destination.merge(key, value, Long::sum);
        });
    }

    private long employmentGeneration(UUID employeeId) {
        return ((Number) em.createNativeQuery("""
                        SELECT count(*) FROM employment_history
                        WHERE employee_id=:employeeId AND event_type='rehire'
                        """)
                .setParameter("employeeId", employeeId)
                .getSingleResult()).longValue();
    }

    private static UUID derivedOffboardingRequestId(
            UUID requestId, UUID targetId, Collection<String> scopes) {
        String material = "OFFBOARDING|" + requestId + "|" + targetId + "|"
                + String.join(",", scopes);
        return UUID.nameUUIDFromBytes(material.getBytes(StandardCharsets.UTF_8));
    }

    private static String canonicalChecklistCodes(Set<String> codes) {
        if (codes == null || codes.isEmpty()) throw validation("离职确认清单必填");
        return codes.stream().sorted().reduce((left, right) -> left + "," + right)
                .orElseThrow(() -> validation("离职确认清单必填"));
    }

    private static void requireDistinctSourceAndTarget(UUID sourceId, UUID targetId) {
        if (sourceId == null) throw validation("sourceEmployeeId 必填");
        if (sourceId.equals(targetId)) throw validation("接手人不能与交接人相同");
    }

    private static void requireNoBlockers(
            DataHandoverPreview preview, String messagePrefix) {
        if (!preview.hasBlockers()) return;
        String labels = preview.items().stream()
                .filter(item -> item.action() == DataHandoverAction.BLOCKING
                        && item.count() > 0)
                .map(item -> item.label() + " " + item.count() + " 项")
                .reduce((left, right) -> left + "；" + right)
                .orElse("存在未处理阻塞项");
        throw new ApiException(ErrorCode.CONFLICT, messagePrefix + labels);
    }

    private String json(Map<String, Long> value) {
        try {
            return objectMapper.writeValueAsString(value);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("无法序列化交接结果", error);
        }
    }

    private Map<String, Long> summary(Object value) {
        try {
            Map<String, Long> parsed = objectMapper.readValue(
                    Objects.toString(value, "{}"), new TypeReference<>() {});
            return Collections.unmodifiableMap(new LinkedHashMap<>(parsed));
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("无法读取既有交接结果", error);
        }
    }

    private static UUID uuid(Object value) {
        if (value == null) return null;
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    private static String text(Object value) {
        return value == null ? null : value.toString();
    }

    private static LocalDate localDate(Object value) {
        if (value instanceof LocalDate localDate) return localDate;
        if (value instanceof Date date) return date.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private record EmployeeFact(UUID id, String status, Integer legacyId, String name, UUID departmentId) {}
    private record AccountFact(UUID userId, String status, boolean deleted) {}
    private record LockedPair(EmployeeFact source, EmployeeFact target) {}
}
