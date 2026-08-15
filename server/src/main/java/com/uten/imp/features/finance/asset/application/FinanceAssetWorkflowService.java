package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.features.finance.asset.domain.AssetPeriod;
import com.uten.imp.features.finance.asset.domain.AssetPostingPolicy;
import com.uten.imp.features.finance.asset.domain.AssetSubmissionPolicy;
import com.uten.imp.features.finance.asset.domain.CorporateAssetBookPolicy;
import com.uten.imp.features.finance.asset.domain.FinanceAssetStateMachine;
import com.uten.imp.features.finance.asset.domain.StraightLineScheduleCalculator;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Draft and recognition workflow. Posted accounting facts are delegated to the GL writer. */
@Service
@RequiredArgsConstructor
public class FinanceAssetWorkflowService {

    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");

    private final EntityManager em;
    private final TxSessionVars tx;
    private final FinanceAssetAuthorization authorization;
    private final FinanceAssetFeatureGate featureGate;
    private final DocNumberService docNumbers;
    private final FinanceAssetLedgerPostingService ledger;
    private final FinanceAssetPeriodService periods;
    private final ObjectMapper objectMapper;

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult createFixed(AssetWorkbenchRequests.FixedAssetDraft request) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.EDIT);
        BigDecimal salvage = residual(request.categoryId(), request.salvageRate());
        AssetPeriod.parse(request.startPeriod());
        UUID id = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO fixed_assets
                    (id, code, name, department_id, original_value, salvage_rate, useful_months,
                     start_period, status, remark, category_id, lifecycle_status,
                     source_type, source_id, source_ref, source_line_ref, source_document_date,
                     asset_tag, serial_number, custodian_employee_id, location_text, cost_center_code,
                     acquired_on, accepted_on, ready_for_use_on, operating_status,
                     created_by, updated_by)
                VALUES
                    (:id, :code, :name, :department, :amount, :salvage, :months,
                     :startPeriod, '停用', :remark, :category, 'DRAFT',
                     :sourceType, :sourceId, :sourceRef, :sourceLine, :sourceDate,
                     :assetTag, :serial, :custodian, :location, :costCenter,
                     :acquired, :accepted, :ready, 'PENDING_ACCEPTANCE',
                     :actor, :actor)
                """)
                .setParameter("id", id).setParameter("code", docNumbers.nextNumber(DocNumberPrefix.FIXED_ASSET))
                .setParameter("name", request.name().trim()).setParameter("department", request.departmentId())
                .setParameter("amount", request.originalValue()).setParameter("salvage", salvage)
                .setParameter("months", request.usefulMonths()).setParameter("startPeriod", request.startPeriod())
                .setParameter("remark", request.remark()).setParameter("category", request.categoryId())
                .setParameter("sourceType", normalizeType(request.sourceType())).setParameter("sourceId", request.sourceId())
                .setParameter("sourceRef", normalizeRef(request.sourceRef())).setParameter("sourceLine", normalizeRef(request.sourceLineRef()))
                .setParameter("sourceDate", request.sourceDocumentDate()).setParameter("assetTag", normalizeType(request.assetTag()))
                .setParameter("serial", request.serialNumber()).setParameter("custodian", request.custodianId())
                .setParameter("location", request.location()).setParameter("costCenter", request.costCenterCode())
                .setParameter("acquired", request.acquisitionDate()).setParameter("accepted", request.acceptanceDate())
                .setParameter("ready", request.readyForUseDate()).setParameter("actor", actor).executeUpdate();
        event("FIXED_ASSET", id, "CREATED", "Fixed asset draft created", null, null, Map.of(), actor);
        return result("fixed_assets", id, false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult createDeferred(AssetWorkbenchRequests.DeferredExpenseDraft request) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.EDIT);
        AssetPeriod.parse(request.startPeriod());
        UUID id = UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO deferred_expenses
                    (id, code, name, department_id, expense_style_id, total_amount, useful_months,
                     start_period, status, remark, category_id, lifecycle_status,
                     source_type, source_id, source_ref, source_line_ref, source_document_date,
                     responsible_employee_id, location_text, cost_center_code,
                     incurred_on, service_start_on, benefit_end_on, created_by, updated_by)
                VALUES
                    (:id, :code, :name, :department, NULL, :amount, :months,
                     :startPeriod, '停用', :remark, :category, 'DRAFT',
                     :sourceType, :sourceId, :sourceRef, :sourceLine, :sourceDate,
                     :responsible, :location, :costCenter,
                     :incurred, :benefitStart, :benefitEnd, :actor, :actor)
                """)
                .setParameter("id", id).setParameter("code", docNumbers.nextNumber(DocNumberPrefix.DEFERRED_EXPENSE))
                .setParameter("name", request.name().trim()).setParameter("department", request.departmentId())
                .setParameter("amount", request.totalAmount()).setParameter("months", request.usefulMonths())
                .setParameter("startPeriod", request.startPeriod()).setParameter("remark", request.remark())
                .setParameter("category", request.categoryId()).setParameter("sourceType", normalizeType(request.sourceType()))
                .setParameter("sourceId", request.sourceId()).setParameter("sourceRef", normalizeRef(request.sourceRef()))
                .setParameter("sourceLine", normalizeRef(request.sourceLineRef())).setParameter("sourceDate", request.sourceDocumentDate())
                .setParameter("responsible", request.responsibleEmployeeId()).setParameter("location", request.location())
                .setParameter("costCenter", request.costCenterCode()).setParameter("incurred", request.sourceDocumentDate())
                .setParameter("benefitStart", request.benefitStartDate()).setParameter("benefitEnd", request.benefitEndDate())
                .setParameter("actor", actor).executeUpdate();
        event("DEFERRED_EXPENSE", id, "CREATED", "Deferred-expense draft created", null, null, Map.of(), actor);
        return result("deferred_expenses", id, true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult updateFixed(UUID id, AssetWorkbenchRequests.FixedAssetDraft request) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.EDIT);
        Locked locked = lock("fixed_assets", id);
        FinanceAssetStateMachine.requireDraft(locked.status());
        version(locked.version(), request.expectedVersion());
        BigDecimal salvage = residual(request.categoryId(), request.salvageRate());
        AssetPeriod.parse(request.startPeriod());
        int changed = em.createNativeQuery("""
                UPDATE fixed_assets SET name=:name, department_id=:department, category_id=:category,
                    original_value=:amount, salvage_rate=:salvage, useful_months=:months,
                    start_period=:startPeriod, remark=:remark, source_type=:sourceType, source_id=:sourceId,
                    source_ref=:sourceRef, source_line_ref=:sourceLine, source_document_date=:sourceDate,
                    asset_tag=:assetTag, serial_number=:serial, custodian_employee_id=:custodian,
                    location_text=:location, cost_center_code=:costCenter,
                    acquired_on=:acquired, accepted_on=:accepted, ready_for_use_on=:ready,
                    row_version=row_version+1, updated_at=now(), updated_by=:actor
                WHERE id=:id AND lifecycle_status='DRAFT' AND row_version=:version AND is_deleted=false
                """)
                .setParameter("name", request.name().trim()).setParameter("department", request.departmentId())
                .setParameter("category", request.categoryId()).setParameter("amount", request.originalValue())
                .setParameter("salvage", salvage).setParameter("months", request.usefulMonths())
                .setParameter("startPeriod", request.startPeriod()).setParameter("remark", request.remark())
                .setParameter("sourceType", normalizeType(request.sourceType())).setParameter("sourceId", request.sourceId())
                .setParameter("sourceRef", normalizeRef(request.sourceRef())).setParameter("sourceLine", normalizeRef(request.sourceLineRef()))
                .setParameter("sourceDate", request.sourceDocumentDate()).setParameter("assetTag", normalizeType(request.assetTag()))
                .setParameter("serial", request.serialNumber()).setParameter("custodian", request.custodianId())
                .setParameter("location", request.location()).setParameter("costCenter", request.costCenterCode())
                .setParameter("acquired", request.acquisitionDate()).setParameter("accepted", request.acceptanceDate())
                .setParameter("ready", request.readyForUseDate()).setParameter("actor", actor)
                .setParameter("id", id).setParameter("version", locked.version()).executeUpdate();
        changed(changed); event("FIXED_ASSET", id, "UPDATED", "Fixed asset draft updated", null, null, Map.of(), actor);
        return result("fixed_assets", id, false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult updateDeferred(UUID id, AssetWorkbenchRequests.DeferredExpenseDraft request) {
        tx.bind();
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.EDIT);
        Locked locked = lock("deferred_expenses", id);
        FinanceAssetStateMachine.requireDraft(locked.status());
        version(locked.version(), request.expectedVersion());
        AssetPeriod.parse(request.startPeriod());
        int changed = em.createNativeQuery("""
                UPDATE deferred_expenses SET name=:name, department_id=:department, category_id=:category,
                    total_amount=:amount, useful_months=:months, start_period=:startPeriod, remark=:remark,
                    source_type=:sourceType, source_id=:sourceId, source_ref=:sourceRef,
                    source_line_ref=:sourceLine, source_document_date=:sourceDate,
                    responsible_employee_id=:responsible, location_text=:location, cost_center_code=:costCenter,
                    incurred_on=:incurred, service_start_on=:benefitStart, benefit_end_on=:benefitEnd,
                    row_version=row_version+1, updated_at=now(), updated_by=:actor
                WHERE id=:id AND lifecycle_status='DRAFT' AND row_version=:version AND is_deleted=false
                """)
                .setParameter("name", request.name().trim()).setParameter("department", request.departmentId())
                .setParameter("category", request.categoryId()).setParameter("amount", request.totalAmount())
                .setParameter("months", request.usefulMonths()).setParameter("startPeriod", request.startPeriod())
                .setParameter("remark", request.remark()).setParameter("sourceType", normalizeType(request.sourceType()))
                .setParameter("sourceId", request.sourceId()).setParameter("sourceRef", normalizeRef(request.sourceRef()))
                .setParameter("sourceLine", normalizeRef(request.sourceLineRef())).setParameter("sourceDate", request.sourceDocumentDate())
                .setParameter("responsible", request.responsibleEmployeeId()).setParameter("location", request.location())
                .setParameter("costCenter", request.costCenterCode()).setParameter("incurred", request.sourceDocumentDate())
                .setParameter("benefitStart", request.benefitStartDate()).setParameter("benefitEnd", request.benefitEndDate())
                .setParameter("actor", actor).setParameter("id", id).setParameter("version", locked.version())
                .executeUpdate();
        changed(changed); event("DEFERRED_EXPENSE", id, "UPDATED", "Deferred-expense draft updated", null, null, Map.of(), actor);
        return result("deferred_expenses", id, true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public void deleteDraft(UUID id, boolean deferred, long expectedVersion) {
        tx.bind(); authorization.require(FinanceAssetAuthorization.EDIT);
        String table = deferred ? "deferred_expenses" : "fixed_assets";
        Locked locked = lock(table, id); FinanceAssetStateMachine.requireDraft(locked.status());
        version(locked.version(), expectedVersion);
        changed(em.createNativeQuery("UPDATE " + table + " SET is_deleted=true, deleted_at=now() WHERE id=:id AND lifecycle_status='DRAFT' AND row_version=:version AND is_deleted=false")
                .setParameter("id", id).setParameter("version",locked.version()).executeUpdate());
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult submit(UUID id, long expectedVersion, boolean deferred) {
        tx.bind(); UUID actor = authorization.requireActorId(FinanceAssetAuthorization.EDIT);
        String table = deferred ? "deferred_expenses" : "fixed_assets";
        Locked locked = lock(table, id); FinanceAssetStateMachine.requireObjectTransition(locked.status(), "PENDING_APPROVAL");
        version(locked.version(), expectedVersion);
        validateSubmission(id, deferred);
        changed(em.createNativeQuery("UPDATE " + table + " SET lifecycle_status='PENDING_APPROVAL', submitted_at=now(), submitted_by=:actor, row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='DRAFT' AND row_version=:version AND is_deleted=false")
                .setParameter("actor", actor).setParameter("id", id).setParameter("version", locked.version()).executeUpdate());
        approval(deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET", id, "RECOGNITION", "SUBMIT", null, actor);
        event(deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET", id, "SUBMITTED", "Submitted for accounting approval", null, null, Map.of(), actor);
        return result(table, id, deferred);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult approve(UUID id, long expectedVersion, String comment, boolean deferred) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.APPROVE);
        String table = deferred ? "deferred_expenses" : "fixed_assets";
        lockPostingStream(deferred ? "AMORTIZATION" : "DEPRECIATION");
        Locked locked = lock(table, id); FinanceAssetStateMachine.requireObjectTransition(locked.status(), "APPROVED");
        version(locked.version(), expectedVersion); AssetPostingPolicy.requireDifferentActor(actor, locked.submittedBy(), "approve");
        validateSubmission(id, deferred);
        Category category = categoryFor(id, deferred);
        if (deferred) createDeferredSchedule(id, category, actor); else createCorporateBook(id, category, actor);
        String accumulated = deferred ? "NULL" : ":accumulated";
        QueryBuilder update = new QueryBuilder("UPDATE " + table + " SET lifecycle_status='APPROVED', cost_style_snapshot_id=:cost, accumulated_style_snapshot_id=" + accumulated + ", expense_style_snapshot_id=:expense, clearing_style_snapshot_id=:clearing, account_snapshot=CAST(:snapshot AS jsonb), required_document_codes_snapshot=CAST(:documents AS jsonb), category_version_snapshot=:categoryVersion, approved_at=now(), approved_by=:actor, row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='PENDING_APPROVAL' AND row_version=:version AND is_deleted=false");
        var query = em.createNativeQuery(update.sql()).setParameter("cost", category.cost()).setParameter("expense", category.expense())
                .setParameter("clearing", category.clearing()).setParameter("snapshot", accountSnapshot(category))
                .setParameter("documents", category.documents()).setParameter("categoryVersion", category.version())
                .setParameter("actor", actor).setParameter("id", id).setParameter("version", locked.version());
        if (!deferred) query.setParameter("accumulated", category.accumulated());
        changed(query.executeUpdate());
        approval(deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET", id, "RECOGNITION", "APPROVE", comment, actor);
        event(deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET", id, "APPROVED", "Accounting policy approved", null, comment, Map.of(), actor);
        return result(table, id, deferred);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult reject(UUID id, long expectedVersion, String reason, boolean deferred) {
        tx.bind(); UUID actor = authorization.requireActorId(FinanceAssetAuthorization.APPROVE);
        if (reason == null || reason.isBlank()) throw validation("Reject reason is required");
        String table = deferred ? "deferred_expenses" : "fixed_assets";
        Locked locked = lock(table, id); FinanceAssetStateMachine.requireObjectTransition(locked.status(), "DRAFT");
        version(locked.version(), expectedVersion); AssetPostingPolicy.requireDifferentActor(actor, locked.submittedBy(), "reject");
        changed(em.createNativeQuery("UPDATE " + table + " SET lifecycle_status='DRAFT', last_rejected_at=now(), last_rejected_by=:actor, last_rejection_reason=:reason, row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='PENDING_APPROVAL' AND row_version=:version AND is_deleted=false")
                .setParameter("actor", actor).setParameter("reason", reason.trim()).setParameter("id", id)
                .setParameter("version", locked.version()).executeUpdate());
        approval(deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET", id, "RECOGNITION", "REJECT", reason, actor);
        event(deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET", id, "REJECTED", "Accounting approval rejected", null, reason, Map.of(), actor);
        return result(table, id, deferred);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.WorkflowResult activate(UUID id, long expectedVersion, boolean deferred) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        UUID actor = authorization.requireActorId(FinanceAssetAuthorization.POST);
        featureGate.requirePostedWorkflowsEnabled("Initial recognition activation");
        String table = deferred ? "deferred_expenses" : "fixed_assets";
        LocalDate date = LocalDate.now(SHANGHAI); String period = YearMonth.from(date).toString();
        periods.ensureOpen(period, FinanceAssetAuthorization.POST);
        lockPostingStream(deferred ? "AMORTIZATION" : "DEPRECIATION");
        Locked locked = lock(table, id); FinanceAssetStateMachine.requireObjectTransition(locked.status(), "ACTIVE");
        version(locked.version(), expectedVersion); AssetPostingPolicy.requireDifferentActor(actor, locked.submittedBy(), "post");
        requireStartAfterLatestRun(id,deferred);
        Object[] row = (Object[]) em.createNativeQuery("SELECT code, " + (deferred ? "total_amount" : "original_value") + ", cost_style_snapshot_id, accumulated_style_snapshot_id, expense_style_snapshot_id, clearing_style_snapshot_id FROM " + table + " WHERE id=:id FOR UPDATE")
                .setParameter("id", id).getSingleResult();
        BigDecimal amount = (BigDecimal) row[1];
        requireSnapshotAccounts(deferred,uuid(row[2]),uuid(row[3]),uuid(row[4]),uuid(row[5]));
        UUID voucher = ledger.post(text(row[0]) + (deferred ? "-REC" : "-CAP"), period, date,
                deferred ? "DA_RECOGNITION" : "FA_CAP", id,
                deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET", "Initial recognition",
                List.of(new FinanceAssetLedgerPostingService.Entry(uuid(row[2]), 1, amount, "Initial recognition"),
                        new FinanceAssetLedgerPostingService.Entry(uuid(row[5]), -1, amount, "Clearing source")));
        if (deferred) {
            changed(em.createNativeQuery("UPDATE deferred_expenses SET lifecycle_status='ACTIVE', status='摊销中', recognized_on=:date, expense_style_id=expense_style_snapshot_id, row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='APPROVED' AND row_version=:version")
                    .setParameter("date", date).setParameter("actor", actor).setParameter("id", id).setParameter("version", locked.version()).executeUpdate());
        } else {
            changed(em.createNativeQuery("UPDATE fixed_assets SET lifecycle_status='ACTIVE', status='在用', operating_status='IN_USE', capitalized_on=:date, expense_style_id=expense_style_snapshot_id, row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='APPROVED' AND row_version=:version")
                    .setParameter("date", date).setParameter("actor", actor).setParameter("id", id).setParameter("version", locked.version()).executeUpdate());
            em.createNativeQuery("UPDATE finance_asset_books SET status='ACTIVE', posting_enabled=true, activated_at=now(), activated_by=:actor, row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE asset_id=:id AND book_type='CORPORATE' AND status='DRAFT' AND is_deleted=false")
                    .setParameter("actor", actor).setParameter("id", id).executeUpdate();
        }
        event(deferred ? "DEFERRED_EXPENSE" : "FIXED_ASSET", id, "ACTIVATED", "Initial recognition posted", date, null, Map.of("voucherId", voucher.toString()), actor);
        return result(table, id, deferred);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult transfer(UUID id, AssetWorkbenchRequests.TransferCommand command) {
        tx.bind(); UUID actor = authorization.requireActorId(FinanceAssetAuthorization.EDIT);
        lockPostingStream("DEPRECIATION");
        Locked locked = lock("fixed_assets", id); if (!"ACTIVE".equals(locked.status())) throw conflict("Only ACTIVE assets can transfer");
        version(locked.version(), command.expectedVersion());
        requireFixedAssetChangeDate(id,command.effectiveDate());
        requireResponsibility(command.targetDepartmentId(),command.custodianId(),command.location(),"custodian");
        changed(em.createNativeQuery("UPDATE fixed_assets SET department_id=:department, custodian_employee_id=:custodian, location_text=:location, row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='ACTIVE' AND row_version=:version")
                .setParameter("department", command.targetDepartmentId()).setParameter("custodian", command.custodianId())
                .setParameter("location", command.location()).setParameter("actor", actor).setParameter("id", id)
                .setParameter("version", locked.version()).executeUpdate());
        event("FIXED_ASSET", id, "TRANSFERRED", "Asset responsibility transferred", command.effectiveDate(), command.reason(), Map.of("departmentId", command.targetDepartmentId().toString()), actor);
        return result("fixed_assets", id, false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult operatingStatus(UUID id, AssetWorkbenchRequests.OperatingStatusCommand command) {
        tx.bind(); UUID actor = authorization.requireActorId(FinanceAssetAuthorization.EDIT);
        Locked locked = lock("fixed_assets", id); if (!"ACTIVE".equals(locked.status())) throw conflict("Only ACTIVE assets can change operating status");
        version(locked.version(), command.expectedVersion());
        requireFixedAssetChangeDate(id,command.effectiveDate());
        changed(em.createNativeQuery("UPDATE fixed_assets SET operating_status=:status, row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='ACTIVE' AND row_version=:version")
                .setParameter("status", command.operatingStatus()).setParameter("actor", actor).setParameter("id", id)
                .setParameter("version", locked.version()).executeUpdate());
        event("FIXED_ASSET", id, "OPERATING_STATUS_CHANGED", "Operating status changed", command.effectiveDate(), command.reason(), Map.of("operatingStatus", command.operatingStatus()), actor);
        return result("fixed_assets", id, false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult requestDisposal(UUID id, AssetWorkbenchRequests.DisposalCommand command) {
        tx.bind(); UUID actor = authorization.requireActorId(FinanceAssetAuthorization.DISPOSE);
        featureGate.requirePostedWorkflowsEnabled("Fixed-asset disposal");
        Locked locked = lock("fixed_assets", id); if (!"ACTIVE".equals(locked.status())) throw conflict("Only ACTIVE assets can request disposal");
        version(locked.version(), command.expectedVersion());
        requireWorkflowEffectiveDate(id, false, command.effectiveDate());
        changed(em.createNativeQuery("UPDATE fixed_assets SET lifecycle_status='DISPOSAL_PENDING', row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='ACTIVE' AND row_version=:version")
                .setParameter("actor", actor).setParameter("id", id).setParameter("version", locked.version()).executeUpdate());
        approval("FIXED_ASSET", id, "DISPOSAL", "SUBMIT", command.reason(), actor);
        event("FIXED_ASSET", id, "DISPOSAL_REQUESTED", "Asset disposal requested", command.effectiveDate(), command.reason(),
                Map.of("proceedsAmount", command.proceedsAmount().toPlainString(), "evidenceReference", nullToEmpty(command.evidenceReference())), actor);
        return result("fixed_assets", id, false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult requestTermination(UUID id, AssetWorkbenchRequests.TerminationCommand command) {
        tx.bind(); UUID actor = authorization.requireActorId(FinanceAssetAuthorization.DISPOSE);
        featureGate.requirePostedWorkflowsEnabled("Deferred-expense termination");
        Locked locked = lock("deferred_expenses", id); if (!"ACTIVE".equals(locked.status())) throw conflict("Only ACTIVE deferrals can request termination");
        version(locked.version(), command.expectedVersion());
        requireWorkflowEffectiveDate(id, true, command.effectiveDate());
        changed(em.createNativeQuery("UPDATE deferred_expenses SET lifecycle_status='TERMINATION_PENDING', row_version=row_version+1, updated_at=now(), updated_by=:actor WHERE id=:id AND lifecycle_status='ACTIVE' AND row_version=:version")
                .setParameter("actor", actor).setParameter("id", id).setParameter("version", locked.version()).executeUpdate());
        approval("DEFERRED_EXPENSE", id, "TERMINATION", "SUBMIT", command.reason(), actor);
        event("DEFERRED_EXPENSE", id, "TERMINATION_REQUESTED", "Deferred-expense termination requested", command.effectiveDate(), command.reason(),
                Map.of("evidenceReference", nullToEmpty(command.evidenceReference())), actor);
        return result("deferred_expenses", id, true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:dispose') and hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.WorkflowResult approveDisposal(UUID id, AssetWorkbenchRequests.ReasonCommand command) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        UUID actor=authorization.requireActorId(FinanceAssetAuthorization.DISPOSE);
        featureGate.requirePostedWorkflowsEnabled("Fixed-asset disposal posting");
        authorization.require(FinanceAssetAuthorization.POST);
        RequestEvidence request=latestRequest("FIXED_ASSET",id,"DISPOSAL_REQUESTED");
        AssetPostingPolicy.requireDifferentActor(actor,request.maker(),"approve disposal");
        String period=YearMonth.from(request.effectiveDate()).toString();
        periods.ensureOpen(period,FinanceAssetAuthorization.POST);
        lockPostingStream("DEPRECIATION");
        Locked locked=lock("fixed_assets",id);
        FinanceAssetStateMachine.requireObjectTransition(locked.status(),"DISPOSED");
        version(locked.version(),command.expectedVersion());
        requireWorkflowEffectiveDate(id,false,request.effectiveDate());
        requireEffectiveRun("DEPRECIATION",period);
        requireNoLaterRun("DEPRECIATION",period);
        Object[] book=(Object[])em.createNativeQuery("SELECT id,original_value,accumulated_amount,net_book_value,cost_style_id,accumulated_style_id,clearing_style_id,status,start_period,depreciable_amount,expense_style_id FROM finance_asset_books WHERE asset_id=:id AND book_type='CORPORATE' AND status IN ('ACTIVE','FULLY_DEPRECIATED') AND is_deleted=false FOR UPDATE").setParameter("id",id).getSingleResult();
        BigDecimal original=decimal(book[1]),accumulated=decimal(book[2]),net=decimal(book[3]);
        requireSnapshotAccounts(false,uuid(book[4]),uuid(book[5]),uuid(book[10]),uuid(book[6]));
        if(accumulated.add(net).compareTo(original)!=0)throw conflict("Asset book does not reconcile to original cost");
        boolean depreciationDue = text(book[8]).compareTo(period) <= 0
                && decimal(book[9]).subtract(accumulated).signum() > 0;
        if("ACTIVE".equals(text(book[7])) && depreciationDue){
            Number fact=(Number)em.createNativeQuery("SELECT COUNT(*) FROM fa_depreciation_log WHERE asset_id=:asset AND asset_book_id=:book AND period=:period AND entry_kind='NORMAL' AND status='ACTIVE' AND is_deleted=false")
                    .setParameter("asset",id).setParameter("book",uuid(book[0])).setParameter("period",period).getSingleResult();
            if(fact.longValue()!=1)throw conflict("This asset must be depreciated in the disposal month first");
        }
        List<FinanceAssetLedgerPostingService.Entry> entries=new ArrayList<>();
        if(accumulated.signum()>0)entries.add(new FinanceAssetLedgerPostingService.Entry(uuid(book[5]),1,accumulated,"Remove accumulated depreciation"));
        if(net.signum()>0)entries.add(new FinanceAssetLedgerPostingService.Entry(uuid(book[6]),1,net,"Transfer net book value to disposal clearing"));
        entries.add(new FinanceAssetLedgerPostingService.Entry(uuid(book[4]),-1,original,"Derecognize fixed-asset cost"));
        UUID voucher=ledger.post("FA-DISP-"+period+"-"+id.toString().substring(0,8),period,request.effectiveDate(),
                "FA_DISPOSAL",id,"FIXED_ASSET",command.reason(),entries);
        changed(em.createNativeQuery("UPDATE fixed_assets SET lifecycle_status='DISPOSED',operating_status='DISPOSED',disposed_on=:date,status='清理',row_version=row_version+1,updated_at=now(),updated_by=:actor WHERE id=:id AND lifecycle_status='DISPOSAL_PENDING' AND row_version=:version")
                .setParameter("date",request.effectiveDate()).setParameter("actor",actor).setParameter("id",id).setParameter("version",locked.version()).executeUpdate());
        em.createNativeQuery("UPDATE finance_asset_books SET status='CLOSED',posting_enabled=false,closed_at=now(),row_version=row_version+1,updated_at=now(),updated_by=:actor WHERE id=:book AND is_deleted=false")
                .setParameter("actor",actor).setParameter("book",uuid(book[0])).executeUpdate();
        approval("FIXED_ASSET",id,"DISPOSAL","APPROVE",command.reason(),actor);
        event("FIXED_ASSET",id,"DISPOSED","Fixed asset disposed",request.effectiveDate(),command.reason(),
                Map.of("voucherId",voucher.toString(),"proceedsAmount",request.proceeds()),actor);
        return result("fixed_assets",id,false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:dispose') and hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.WorkflowResult approveTermination(UUID id, AssetWorkbenchRequests.ReasonCommand command) {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        UUID actor=authorization.requireActorId(FinanceAssetAuthorization.DISPOSE);
        featureGate.requirePostedWorkflowsEnabled("Deferred-expense termination posting");
        authorization.require(FinanceAssetAuthorization.POST);
        RequestEvidence request=latestRequest("DEFERRED_EXPENSE",id,"TERMINATION_REQUESTED");
        AssetPostingPolicy.requireDifferentActor(actor,request.maker(),"approve termination");
        String period=YearMonth.from(request.effectiveDate()).toString();
        periods.ensureOpen(period,FinanceAssetAuthorization.POST);
        lockPostingStream("AMORTIZATION");
        Locked locked=lock("deferred_expenses",id);
        FinanceAssetStateMachine.requireObjectTransition(locked.status(),"TERMINATED");
        version(locked.version(),command.expectedVersion());
        requireWorkflowEffectiveDate(id,true,request.effectiveDate());
        requireEffectiveRun("AMORTIZATION",period);
        requireNoLaterRun("AMORTIZATION",period);
        Object[] row=(Object[])em.createNativeQuery("SELECT d.total_amount,d.cost_style_snapshot_id,d.expense_style_snapshot_id,COALESCE((SELECT SUM(l.amount) FROM da_amortization_log l WHERE l.deferred_id=d.id AND l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false),0),s.start_period,d.clearing_style_snapshot_id FROM deferred_expenses d JOIN finance_deferral_schedule_versions s ON s.deferred_id=d.id AND s.status='APPROVED' AND s.is_deleted=false WHERE d.id=:id FOR UPDATE").setParameter("id",id).getSingleResult();
        BigDecimal remaining=decimal(row[0]).subtract(decimal(row[3]));
        requireSnapshotAccounts(true,uuid(row[1]),null,uuid(row[2]),uuid(row[5]));
        if(remaining.signum()<0)throw conflict("Deferred-expense balance is negative");
        Number fact=(Number)em.createNativeQuery("SELECT COUNT(*) FROM da_amortization_log WHERE deferred_id=:id AND period=:period AND entry_kind='NORMAL' AND status='ACTIVE' AND is_deleted=false")
                .setParameter("id",id).setParameter("period",period).getSingleResult();
        boolean amortizationDue = text(row[4]).compareTo(period) <= 0 && remaining.signum() > 0;
        if(amortizationDue && fact.longValue()!=1)throw conflict("This deferred expense must be amortized in the termination month first");
        List<FinanceAssetLedgerPostingService.Entry> entries=new ArrayList<>();
        if(remaining.signum()>0){
            entries.add(new FinanceAssetLedgerPostingService.Entry(uuid(row[2]),1,remaining,"Terminate remaining deferred expense"));
            entries.add(new FinanceAssetLedgerPostingService.Entry(uuid(row[1]),-1,remaining,"Derecognize deferred cost"));
        }
        UUID voucher=ledger.post("DA-TERM-"+period+"-"+id.toString().substring(0,8),period,request.effectiveDate(),
                "DA_TERMINATION",id,"DEFERRED_EXPENSE",command.reason(),entries);
        changed(em.createNativeQuery("UPDATE deferred_expenses SET lifecycle_status='TERMINATED',terminated_on=:date,status='停用',row_version=row_version+1,updated_at=now(),updated_by=:actor WHERE id=:id AND lifecycle_status='TERMINATION_PENDING' AND row_version=:version")
                .setParameter("date",request.effectiveDate()).setParameter("actor",actor).setParameter("id",id).setParameter("version",locked.version()).executeUpdate());
        approval("DEFERRED_EXPENSE",id,"TERMINATION","APPROVE",command.reason(),actor);
        Map<String,Object> payload=new LinkedHashMap<>(); payload.put("remainingAmount",remaining); if(voucher!=null)payload.put("voucherId",voucher.toString());
        event("DEFERRED_EXPENSE",id,"TERMINATED","Deferred expense terminated",request.effectiveDate(),command.reason(),payload,actor);
        return result("deferred_expenses",id,true);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult rejectDisposal(UUID id, AssetWorkbenchRequests.ReasonCommand command) {
        tx.bind(); UUID actor=authorization.requireActorId(FinanceAssetAuthorization.DISPOSE);
        Locked locked=lock("fixed_assets",id); version(locked.version(),command.expectedVersion());
        FinanceAssetStateMachine.requireObjectTransition(locked.status(),"ACTIVE");
        RequestEvidence request=latestRequest("FIXED_ASSET",id,"DISPOSAL_REQUESTED");
        AssetPostingPolicy.requireDifferentActor(actor,request.maker(),"reject disposal");
        changed(em.createNativeQuery("UPDATE fixed_assets SET lifecycle_status='ACTIVE',row_version=row_version+1,updated_at=now(),updated_by=:actor WHERE id=:id AND lifecycle_status='DISPOSAL_PENDING' AND row_version=:version")
                .setParameter("actor",actor).setParameter("id",id).setParameter("version",locked.version()).executeUpdate());
        approval("FIXED_ASSET",id,"DISPOSAL","REJECT",command.reason(),actor);
        event("FIXED_ASSET",id,"REJECTED","Asset disposal rejected",request.effectiveDate(),command.reason(),Map.of("workflow","DISPOSAL"),actor);
        return result("fixed_assets",id,false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult rejectTermination(UUID id, AssetWorkbenchRequests.ReasonCommand command) {
        tx.bind(); UUID actor=authorization.requireActorId(FinanceAssetAuthorization.DISPOSE);
        Locked locked=lock("deferred_expenses",id); version(locked.version(),command.expectedVersion());
        RequestEvidence request=latestRequest("DEFERRED_EXPENSE",id,"TERMINATION_REQUESTED");
        AssetPostingPolicy.requireDifferentActor(actor,request.maker(),"reject termination");
        Object[] balance=(Object[])em.createNativeQuery("SELECT d.total_amount,COALESCE(SUM(l.amount),0) FROM deferred_expenses d LEFT JOIN da_amortization_log l ON l.deferred_id=d.id AND l.entry_kind='NORMAL' AND l.status='ACTIVE' AND l.is_deleted=false WHERE d.id=:id GROUP BY d.total_amount")
                .setParameter("id",id).getSingleResult();
        String target=decimal(balance[0]).subtract(decimal(balance[1])).signum()==0?"COMPLETED":"ACTIVE";
        FinanceAssetStateMachine.requireObjectTransition(locked.status(),target);
        changed(em.createNativeQuery("UPDATE deferred_expenses SET lifecycle_status=:target,completed_on=CASE WHEN :target='COMPLETED' THEN COALESCE(completed_on,CURRENT_DATE) ELSE NULL END,row_version=row_version+1,updated_at=now(),updated_by=:actor WHERE id=:id AND lifecycle_status='TERMINATION_PENDING' AND row_version=:version")
                .setParameter("target",target).setParameter("actor",actor).setParameter("id",id).setParameter("version",locked.version()).executeUpdate());
        approval("DEFERRED_EXPENSE",id,"TERMINATION","REJECT",command.reason(),actor);
        event("DEFERRED_EXPENSE",id,"REJECTED","Deferred-expense termination rejected",request.effectiveDate(),command.reason(),Map.of("workflow","TERMINATION"),actor);
        return result("deferred_expenses",id,true);
    }

    private void validateSubmission(UUID id, boolean deferred) {
        Category category = categoryFor(id, deferred);
        Object[] row = (Object[]) em.createNativeQuery(deferred ? """
                SELECT total_amount, useful_months, start_period, service_start_on, benefit_end_on,
                       source_type, source_id, source_ref, source_line_ref, source_document_date,
                       department_id, responsible_employee_id, location_text
                FROM deferred_expenses WHERE id=:id
                """ : """
                SELECT original_value, salvage_rate, useful_months, start_period,
                       acquired_on, accepted_on, ready_for_use_on, source_type, source_id, source_ref,
                       source_line_ref, source_document_date, department_id, custodian_employee_id, location_text
                FROM fixed_assets WHERE id=:id
                """).setParameter("id", id).getSingleResult();
        if (deferred) {
            AssetSubmissionPolicy.validateDeferredExpense(new AssetSubmissionPolicy.DeferredInput(
                    policy(category), decimal(row[0]), number(row[1]).intValue(), text(row[2]), date(row[3]), date(row[4])));
            requireSource(id,true,text(row[5]),uuid(row[6]),text(row[7]),text(row[8]),category.documents());
            requireNotFuture(date(row[3]),"benefitStartDate");
            requireNotFuture(date(row[9]),"sourceDocumentDate");
            requireResponsibility(uuid(row[10]),uuid(row[11]),text(row[12]),"responsible employee");
        } else {
            AssetSubmissionPolicy.validateFixedAsset(new AssetSubmissionPolicy.FixedAssetInput(
                    policy(category), decimal(row[0]), decimal(row[1]), number(row[2]).intValue(), text(row[3]),
                    date(row[4]), date(row[5]), date(row[6])));
            requireSource(id,false,text(row[7]),uuid(row[8]),text(row[9]),text(row[10]),category.documents());
            requireNotFuture(date(row[4]),"acquisitionDate");
            requireNotFuture(date(row[5]),"acceptanceDate");
            requireNotFuture(date(row[6]),"readyForUseDate");
            requireNotFuture(date(row[11]),"sourceDocumentDate");
            requireResponsibility(uuid(row[12]),uuid(row[13]),text(row[14]),"custodian");
        }
        requireStartAfterLatestRun(id,deferred);
    }

    private Category categoryFor(UUID id, boolean deferred) {
        String table = deferred ? "deferred_expenses" : "fixed_assets";
        String sql = """
                SELECT c.id,c.object_type,c.version,c.cost_style_id,c.accumulated_style_id,
                       c.expense_style_id,c.clearing_style_id,c.default_method,c.default_months,
                       c.default_salvage_rate,c.required_document_codes::text
                FROM %s a JOIN finance_asset_categories c ON c.id=a.category_id
                WHERE a.id=:id AND c.status='ACTIVE' AND c.is_deleted=false
                """.formatted(table);
        @SuppressWarnings("unchecked") List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("id", id).getResultList();
        if (rows.isEmpty()) throw validation("An ACTIVE category policy is required");
        Object[] r=rows.getFirst(); String expected=deferred?"DEFERRED_EXPENSE":"FIXED_ASSET";
        if(!expected.equals(text(r[1]))) throw validation("Category object type does not match");
        return new Category(uuid(r[0]),text(r[1]),number(r[2]).intValue(),uuid(r[3]),uuid(r[4]),uuid(r[5]),uuid(r[6]),text(r[7]),
                r[8]==null?null:number(r[8]).intValue(),(BigDecimal)r[9],text(r[10]));
    }

    private void createCorporateBook(UUID id, Category category, UUID actor) {
        Object[] r=(Object[])em.createNativeQuery("SELECT original_value,salvage_rate,useful_months,ready_for_use_on FROM fixed_assets WHERE id=:id")
                .setParameter("id",id).getSingleResult();
        BigDecimal original=decimal(r[0]).setScale(4,RoundingMode.HALF_UP);
        BigDecimal residual=original.multiply(decimal(r[1])).setScale(4,RoundingMode.HALF_UP);
        String start=CorporateAssetBookPolicy.deriveDepreciationStart(date(r[3])).toString();
        em.createNativeQuery("""
                INSERT INTO finance_asset_books
                    (asset_id,book_type,method,original_value,residual_rate,residual_amount,depreciable_amount,
                     useful_months,start_period,net_book_value,cost_style_id,accumulated_style_id,expense_style_id,
                     clearing_style_id,policy_snapshot,status,posting_enabled,created_by,updated_by)
                VALUES (:id,'CORPORATE',:method,:original,:rate,:residual,:depreciable,:months,:start,:original,
                        :cost,:accumulated,:expense,:clearing,CAST(:policy AS jsonb),'DRAFT',false,:actor,:actor)
                """).setParameter("id",id).setParameter("method",category.method()).setParameter("original",original)
                .setParameter("rate",decimal(r[1])).setParameter("residual",residual).setParameter("depreciable",original.subtract(residual))
                .setParameter("months",number(r[2]).intValue()).setParameter("start",start).setParameter("cost",category.cost())
                .setParameter("accumulated",category.accumulated()).setParameter("expense",category.expense())
                .setParameter("clearing",category.clearing()).setParameter("policy",accountSnapshot(category)).setParameter("actor",actor).executeUpdate();
    }

    private void createDeferredSchedule(UUID id, Category category, UUID actor) {
        Object[] r=(Object[])em.createNativeQuery("SELECT total_amount,useful_months,start_period,service_start_on,benefit_end_on FROM deferred_expenses WHERE id=:id")
                .setParameter("id",id).getSingleResult();
        BigDecimal amount=decimal(r[0]); int months=number(r[1]).intValue(); String start=text(r[2]); UUID versionId=UUID.randomUUID();
        em.createNativeQuery("""
                INSERT INTO finance_deferral_schedule_versions
                    (id,deferred_id,version,method,total_amount,useful_months,start_period,end_period,
                     benefit_start_on,benefit_end_on,expense_style_id,cost_style_id,clearing_style_id,
                     policy_snapshot,status,created_by,updated_by)
                VALUES (:id,:deferred,1,:method,:amount,:months,:start,:end,:benefitStart,:benefitEnd,
                        :expense,:cost,:clearing,CAST(:policy AS jsonb),'DRAFT',:actor,:actor)
                """).setParameter("id",versionId).setParameter("deferred",id).setParameter("method",category.method())
                .setParameter("amount",amount).setParameter("months",months).setParameter("start",start)
                .setParameter("end",AssetPeriod.parse(start).value().plusMonths(months-1L).toString())
                .setParameter("benefitStart",date(r[3])).setParameter("benefitEnd",date(r[4]))
                .setParameter("expense",category.expense()).setParameter("cost",category.cost()).setParameter("clearing",category.clearing())
                .setParameter("policy",accountSnapshot(category)).setParameter("actor",actor).executeUpdate();
        var schedule=StraightLineScheduleCalculator.calculateDeferred(amount,months,AssetPeriod.parse(start));
        for(var line:schedule.lines()) em.createNativeQuery("""
                INSERT INTO finance_deferral_schedule_lines
                    (schedule_version_id,sequence,period,opening_balance,amount,accumulated_amount,closing_balance,created_by,updated_by)
                VALUES (:version,:sequence,:period,:opening,:amount,:accumulated,:closing,:actor,:actor)
                """).setParameter("version",versionId).setParameter("sequence",line.sequence()).setParameter("period",line.period())
                .setParameter("opening",schedule.originalAmount().subtract(line.openingAccumulated())).setParameter("amount",line.amount())
                .setParameter("accumulated",line.closingAccumulated()).setParameter("closing",line.closingNetAmount())
                .setParameter("actor",actor).executeUpdate();
        em.createNativeQuery("UPDATE finance_deferral_schedule_versions SET status='APPROVED',approved_at=now(),approved_by=:actor,updated_at=now(),updated_by=:actor WHERE id=:id")
                .setParameter("actor",actor).setParameter("id",versionId).executeUpdate();
    }

    private void requireSource(UUID objectId,boolean deferred,String type,UUID sourceId,String ref,String line,String documents){
        String normalizedType=normalizeType(type),normalizedRef=normalizeRef(ref),normalizedLine=normalizeRef(line);
        if(normalizedType==null||normalizedRef==null||normalizedLine==null){
            throw validation("sourceType, sourceRef and a stable sourceLineRef are required before submit; use explicit HEADER for a header-level source");
        }
        if(!"[]".equals(documents)&&normalizedRef.isBlank())throw validation("Required document evidence is missing");
        String identity=sourceId==null?normalizedRef.toLowerCase(java.util.Locale.ROOT):sourceId.toString();
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key","FINANCE_ASSET_SOURCE|"+normalizedType+"|"+identity+"|"+normalizedLine.toLowerCase(java.util.Locale.ROOT))
                .getSingleResult();
        long duplicates=sourceDuplicates("fixed_assets",objectId,!deferred,normalizedType,sourceId,normalizedRef,normalizedLine)
                +sourceDuplicates("deferred_expenses",objectId,deferred,normalizedType,sourceId,normalizedRef,normalizedLine);
        if(duplicates>0)throw conflict("The source document line is already linked to another asset or deferred expense");
    }
    private long sourceDuplicates(String table,UUID objectId,boolean currentTable,String type,UUID sourceId,String ref,String line){
        String exclude=currentTable?" AND id<>:objectId":"";
        String sql="SELECT COUNT(*) FROM "+table+" WHERE is_deleted=false"+exclude
                +" AND upper(btrim(source_type))=:type AND lower(btrim(source_line_ref))=:line"
                +(sourceId==null
                    ?" AND source_id IS NULL AND lower(btrim(source_ref))=:ref"
                    :" AND source_id=:sourceId");
        var query=em.createNativeQuery(sql).setParameter("type",type)
                .setParameter("line",line.toLowerCase(java.util.Locale.ROOT));
        if(currentTable)query.setParameter("objectId",objectId);
        if(sourceId==null)query.setParameter("ref",ref.toLowerCase(java.util.Locale.ROOT));
        else query.setParameter("sourceId",sourceId);
        return ((Number)query.getSingleResult()).longValue();
    }
    private void requireResponsibility(UUID departmentId,UUID employeeId,String location,String role){
        if(departmentId==null||employeeId==null||location==null||location.isBlank()){
            throw validation("department, location and "+role+" are required before submit or transfer");
        }
        Number department=(Number)em.createNativeQuery("SELECT COUNT(*) FROM departments WHERE id=:id AND is_deleted=false")
                .setParameter("id",departmentId).getSingleResult();
        Number employee=(Number)em.createNativeQuery("SELECT COUNT(*) FROM employees WHERE id=:id AND department_id=:department AND status='active' AND is_deleted=false")
                .setParameter("id",employeeId).setParameter("department",departmentId).getSingleResult();
        if(department.longValue()!=1||employee.longValue()!=1){
            throw validation(role+" must be an active employee in the selected active department");
        }
    }
    private static void requireNotFuture(LocalDate value,String field){
        if(value!=null&&value.isAfter(LocalDate.now(SHANGHAI)))throw validation(field+" cannot be in the future when submitted");
    }
    private void lockPostingStream(String runType){
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key","FINANCE_ASSET_RUN|"+runType+"|CORPORATE").getSingleResult();
    }
    private void requireStartAfterLatestRun(UUID id,boolean deferred){
        String table=deferred?"deferred_expenses":"fixed_assets";
        String start=text(em.createNativeQuery("SELECT start_period FROM "+table+" WHERE id=:id AND is_deleted=false").setParameter("id",id).getSingleResult());
        requireStartNotBeforeCurrentPeriod(start);
        String type=deferred?"AMORTIZATION":"DEPRECIATION";
        @SuppressWarnings("unchecked") List<Object> rows=em.createNativeQuery("SELECT period FROM finance_asset_posting_runs WHERE run_type=:type AND book_type='CORPORATE' AND run_kind='NORMAL' AND status='POSTED' AND is_deleted=false ORDER BY period DESC LIMIT 1")
                .setParameter("type",type).getResultList();
        if(!rows.isEmpty()&&start.compareTo(AssetPeriod.parse(text(rows.getFirst())).next().toString())<0){
            throw validation("startPeriod must be at least "+AssetPeriod.parse(text(rows.getFirst())).next()+" because earlier periods are already posted");
        }
    }
    private static void requireStartNotBeforeCurrentPeriod(String startPeriod){
        String current=YearMonth.from(LocalDate.now(SHANGHAI)).toString();
        AssetPostingPolicy.requireStartNotBeforeActivationPeriod(startPeriod,current);
    }
    private void requireWorkflowEffectiveDate(UUID id,boolean deferred,LocalDate effectiveDate){
        if(effectiveDate==null)throw validation("effectiveDate is required");
        requireNotFuture(effectiveDate,"effectiveDate");
        if(deferred){
            Object[] dates=(Object[])em.createNativeQuery("SELECT recognized_on,service_start_on FROM deferred_expenses WHERE id=:id AND is_deleted=false")
                    .setParameter("id",id).getSingleResult();
            LocalDate recognized=date(dates[0]),benefitStart=date(dates[1]);
            if(recognized==null||benefitStart==null)throw conflict("Deferred expense has no recognition/benefit-start evidence");
            if(effectiveDate.isBefore(recognized)||effectiveDate.isBefore(benefitStart)){
                throw validation("effectiveDate cannot precede recognition or benefit start");
            }
        }else{
            LocalDate capitalized=date(em.createNativeQuery("SELECT capitalized_on FROM fixed_assets WHERE id=:id AND is_deleted=false")
                    .setParameter("id",id).getSingleResult());
            if(capitalized==null)throw conflict("Fixed asset has no capitalization evidence");
            if(effectiveDate.isBefore(capitalized)){
                throw validation("effectiveDate cannot precede capitalization");
            }
        }
    }
    private void requireFixedAssetChangeDate(UUID id,LocalDate effectiveDate){
        if(effectiveDate==null)throw validation("effectiveDate is required");
        requireNotFuture(effectiveDate,"effectiveDate");
        LocalDate capitalized=date(em.createNativeQuery("SELECT capitalized_on FROM fixed_assets WHERE id=:id AND is_deleted=false")
                .setParameter("id",id).getSingleResult());
        if(capitalized==null)throw conflict("Fixed asset has no capitalization evidence");
        if(effectiveDate.isBefore(capitalized)){
            throw validation("effectiveDate cannot precede capitalization");
        }
    }
    private void requireSnapshotAccounts(boolean deferred,UUID cost,UUID accumulated,UUID expense,UUID clearing){
        List<UUID> accounts=new ArrayList<>();
        accounts.add(cost);
        if(!deferred)accounts.add(accumulated);
        accounts.add(expense);
        accounts.add(clearing);
        if(accounts.stream().anyMatch(java.util.Objects::isNull)){
            throw validation("Approved account snapshot is incomplete");
        }
        if(accounts.stream().distinct().count()!=accounts.size()){
            throw validation("Approved cost, accumulated depreciation, expense and clearing accounts must be distinct");
        }
        requirePostableStyle(cost,"ACCOUNT","cost");
        if(!deferred)requirePostableStyle(accumulated,"ACCOUNT","accumulated depreciation");
        requirePostableStyle(expense,"EXPENSE","expense");
        requirePostableStyle(clearing,"ACCOUNT","clearing");
    }
    private void requirePostableStyle(UUID styleId,String expectedCategory,String role){
        Number count=(Number)em.createNativeQuery("""
                SELECT COUNT(*) FROM payment_styles s
                WHERE s.id=:id AND s.is_deleted=false AND s.status='使用' AND s.category=:category
                  AND NOT EXISTS (
                      SELECT 1 FROM payment_styles child
                      WHERE child.parent_id=s.id AND child.is_deleted=false)
                """).setParameter("id",styleId).setParameter("category",expectedCategory).getSingleResult();
        if(count.longValue()!=1){
            throw validation("Approved "+role+" account is not an active postable "+expectedCategory+" leaf");
        }
    }
    private RequestEvidence latestRequest(String objectType,UUID id,String eventType){
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("SELECT effective_date,actor_user_id,COALESCE(payload->>'proceedsAmount','0') FROM finance_asset_events WHERE object_type=:type AND object_id=:id AND event_type=:event ORDER BY occurred_at DESC,id DESC LIMIT 1")
                .setParameter("type",objectType).setParameter("id",id).setParameter("event",eventType).getResultList();
        if(rows.isEmpty())throw conflict("Workflow request evidence is missing");
        Object[]r=rows.getFirst(); if(date(r[0])==null)throw conflict("Workflow effective date is missing");
        return new RequestEvidence(date(r[0]),uuid(r[1]),text(r[2]));
    }
    private void requireEffectiveRun(String runType,String period){
        Number count=(Number)em.createNativeQuery("SELECT COUNT(*) FROM finance_asset_posting_runs WHERE run_type=:type AND book_type='CORPORATE' AND period=:period AND run_kind='NORMAL' AND status='POSTED' AND is_deleted=false")
                .setParameter("type",runType).setParameter("period",period).getSingleResult();
        if(count.longValue()!=1)throw conflict("The effective-month "+runType.toLowerCase()+" run must be posted first");
    }
    private void requireNoLaterRun(String runType,String period){
        Number count=(Number)em.createNativeQuery("SELECT COUNT(*) FROM finance_asset_posting_runs WHERE run_type=:type AND book_type='CORPORATE' AND period>:period AND run_kind='NORMAL' AND status='POSTED' AND is_deleted=false")
                .setParameter("type",runType).setParameter("period",period).getSingleResult();
        if(count.longValue()>0)throw conflict("Later effective posting runs must be reversed before this workflow");
    }
    private AssetSubmissionPolicy.PolicyInput policy(Category c){return new AssetSubmissionPolicy.PolicyInput(c.id(),c.cost(),c.accumulated(),c.expense(),c.clearing());}
    private BigDecimal residual(UUID category,BigDecimal value){if(value!=null)return value;if(category!=null){Object v=em.createNativeQuery("SELECT default_salvage_rate FROM finance_asset_categories WHERE id=:id AND is_deleted=false").setParameter("id",category).getSingleResult();if(v!=null)return (BigDecimal)v;}throw validation("salvageRate or an active category residual policy is required");}
    private Locked lock(String table,UUID id){@SuppressWarnings("unchecked")List<Object[]> rows=em.createNativeQuery("SELECT lifecycle_status,row_version,submitted_by FROM "+table+" WHERE id=:id AND is_deleted=false FOR UPDATE").setParameter("id",id).getResultList();if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"Asset record not found");Object[]r=rows.getFirst();return new Locked(text(r[0]),number(r[1]).longValue(),uuid(r[2]));}
    private AssetWorkbenchResponses.WorkflowResult result(String table,UUID id,boolean deferred){
        Object[]r=(Object[])em.createNativeQuery("SELECT lifecycle_status,row_version,COALESCE(submitted_by,created_by) FROM "+table+" WHERE id=:id AND is_deleted=false").setParameter("id",id).getSingleResult();
        String s=text(r[0]); UUID maker=uuid(r[2]);
        if("DISPOSAL_PENDING".equals(s)||"TERMINATION_PENDING".equals(s)){
            String workflow=deferred?"TERMINATION":"DISPOSAL";
            @SuppressWarnings("unchecked") List<Object> actors=em.createNativeQuery("SELECT actor_user_id FROM finance_asset_approval_steps WHERE object_type=:type AND object_id=:id AND workflow_type=:workflow AND action='SUBMIT' ORDER BY step_no DESC LIMIT 1")
                    .setParameter("type",deferred?"DEFERRED_EXPENSE":"FIXED_ASSET").setParameter("id",id).setParameter("workflow",workflow).getResultList();
            if(!actors.isEmpty())maker=uuid(actors.getFirst());
        }
        return new AssetWorkbenchResponses.WorkflowResult(id,s,null,number(r[1]).longValue(),authorization.allowedActions(s,maker,deferred));
    }
    private void approval(String type,UUID id,String workflow,String action,String comment,UUID actor){Number next=(Number)em.createNativeQuery("SELECT COALESCE(MAX(step_no),0)+1 FROM finance_asset_approval_steps WHERE object_type=:type AND object_id=:id AND workflow_type=:workflow").setParameter("type",type).setParameter("id",id).setParameter("workflow",workflow).getSingleResult();em.createNativeQuery("INSERT INTO finance_asset_approval_steps(object_type,object_id,workflow_type,step_no,action,status,actor_user_id,comment,created_by,updated_by) VALUES(:type,:id,:workflow,:step,:action,'RECORDED',:actor,:comment,:actor,:actor)").setParameter("type",type).setParameter("id",id).setParameter("workflow",workflow).setParameter("step",next.intValue()).setParameter("action",action).setParameter("actor",actor).setParameter("comment",comment).executeUpdate();}
    private void event(String type,UUID id,String event,String title,LocalDate date,String description,Map<String,Object> payload,UUID actor){em.createNativeQuery("INSERT INTO finance_asset_events(object_type,object_id,event_type,title,description,effective_date,payload,actor_user_id,created_by,updated_by) VALUES(:type,:id,:event,:title,:description,:date,CAST(:payload AS jsonb),:actor,:actor,:actor)").setParameter("type",type).setParameter("id",id).setParameter("event",event).setParameter("title",title).setParameter("description",description).setParameter("date",date).setParameter("payload",json(payload)).setParameter("actor",actor).executeUpdate();}
    private String accountSnapshot(Category c){return json(Map.of("categoryId",c.id().toString(),"categoryVersion",c.version(),"method",c.method(),"costStyleId",c.cost().toString(),"expenseStyleId",c.expense().toString(),"clearingStyleId",c.clearing().toString(),"accumulatedStyleId",c.accumulated()==null?"":c.accumulated().toString()));}
    private String json(Object value){try{return objectMapper.writeValueAsString(value);}catch(JsonProcessingException e){throw new ApiException(ErrorCode.INTERNAL,"Unable to serialize accounting snapshot");}}
    private static void requireNonBlank(String value,String message){if(value==null||value.isBlank())throw validation(message);}
    private static void version(long actual,Long expected){if(expected==null||actual!=expected)throw conflict("expectedVersion is required and must match; refresh and retry");}
    private static void changed(int count){if(count!=1)throw conflict("Concurrent workflow change; refresh and retry");}
    private static ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static UUID uuid(Object v){return v==null?null:v instanceof UUID id?id:UUID.fromString(v.toString());}
    private static String text(Object v){return v==null?null:v.toString();}
    private static Number number(Object v){return (Number)v;}
    private static BigDecimal decimal(Object v){return (BigDecimal)v;}
    private static LocalDate date(Object v){return v==null?null:v instanceof LocalDate d?d:((java.sql.Date)v).toLocalDate();}
    private static String nullToEmpty(String v){return v==null?"":v;}
    static String normalizeType(String value){return value==null||value.isBlank()?null:value.trim().toUpperCase(java.util.Locale.ROOT);}
    static String normalizeRef(String value){return value==null||value.isBlank()?null:value.trim();}
    private record Locked(String status,long version,UUID submittedBy){}
    private record RequestEvidence(LocalDate effectiveDate,UUID maker,String proceeds){}
    private record Category(UUID id,String objectType,int version,UUID cost,UUID accumulated,UUID expense,UUID clearing,String method,Integer months,BigDecimal residual,String documents){}
    private record QueryBuilder(String sql){}
}
