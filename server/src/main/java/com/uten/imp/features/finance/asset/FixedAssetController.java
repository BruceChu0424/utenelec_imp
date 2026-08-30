package com.uten.imp.features.finance.asset;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.asset.api.AssetCategoryContracts;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.features.finance.asset.application.FinanceAssetCategoryService;
import com.uten.imp.features.finance.asset.application.FinanceAssetPeriodService;
import com.uten.imp.features.finance.asset.application.FinanceAssetPostingService;
import com.uten.imp.features.finance.asset.application.FinanceAssetQueryService;
import com.uten.imp.features.finance.asset.application.FinanceAssetWorkflowService;
import com.uten.imp.features.finance.report.ReportTableResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** Typed professional asset/deferral workbench API. */
@RestController
@RequestMapping("/api/finance")
@RequiredArgsConstructor
public class FixedAssetController {

    private final FinanceAssetQueryService query;
    private final FinanceAssetWorkflowService workflow;
    private final FinanceAssetCategoryService categories;
    private final FinanceAssetPostingService posting;
    private final FinanceAssetPeriodService periods;
    private final FixedAssetService legacyReports;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping("/asset-workbench/overview")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public AssetWorkbenchResponses.Overview overview() { return query.overview(); }

    @GetMapping("/fixed-assets")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public PageResponse<AssetWorkbenchResponses.Summary> fixedAssets(
            @RequestParam(required = false) String q,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return query.listFixedAssets(q, status, categoryId, departmentId, page, size);
    }

    @GetMapping("/fixed-assets/{id}")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public AssetWorkbenchResponses.Detail fixedAsset(@PathVariable UUID id) {
        AssetWorkbenchResponses.Detail result = query.fixedAsset(id);
        String code = result.summary() == null ? null : result.summary().code();
        detailViewAudit.record(
                "view_fixed_asset_detail",
                "fixed_assets",
                id,
                code,
                null,
                "固定资产");
        return result;
    }

    @PostMapping("/fixed-assets")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult createFixed(
            @Valid @RequestBody AssetWorkbenchRequests.FixedAssetDraft body) {
        return workflow.createFixed(body);
    }

    @PutMapping("/fixed-assets/{id}")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult updateFixed(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.FixedAssetDraft body) {
        requireExpectedVersion(body.expectedVersion());
        return workflow.updateFixed(id, body);
    }

    @DeleteMapping("/fixed-assets/{id}")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public void deleteFixed(
            @PathVariable UUID id, @RequestParam long expectedVersion) {
        workflow.deleteDraft(id, false, expectedVersion);
    }

    @PostMapping("/fixed-assets/{id}/submit")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult submitFixed(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.VersionCommand body) {
        return workflow.submit(id, body.expectedVersion(), false);
    }

    @PostMapping("/fixed-assets/{id}/approve")
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult approveFixed(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.ApprovalCommand body) {
        return workflow.approve(id, body.expectedVersion(), body.comment(), false);
    }

    @PostMapping("/fixed-assets/{id}/reject")
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult rejectFixed(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.ReasonCommand body) {
        return workflow.reject(id, body.expectedVersion(), body.reason(), false);
    }

    @PostMapping("/fixed-assets/{id}/activate")
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.WorkflowResult activateFixed(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.VersionCommand body) {
        return workflow.activate(id, body.expectedVersion(), false);
    }

    @PostMapping("/fixed-assets/{id}/transfer")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult transfer(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.TransferCommand body) {
        return workflow.transfer(id, body);
    }

    @PostMapping("/fixed-assets/{id}/operating-status")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult operatingStatus(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.OperatingStatusCommand body) {
        return workflow.operatingStatus(id, body);
    }

    @PostMapping("/fixed-assets/{id}/dispose")
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult dispose(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.DisposalCommand body) {
        return workflow.requestDisposal(id, body);
    }

    @PostMapping("/fixed-assets/{id}/approve-disposal")
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult approveDisposal(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.ReasonCommand body) {
        return workflow.approveDisposal(id, body);
    }

    @PostMapping("/fixed-assets/{id}/reject-disposal")
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult rejectDisposal(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.ReasonCommand body) {
        return workflow.rejectDisposal(id, body);
    }

    @GetMapping("/deferred-expenses")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public PageResponse<AssetWorkbenchResponses.Summary> deferredExpenses(
            @RequestParam(required = false) String q,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) UUID categoryId,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return query.listDeferredExpenses(q, status, categoryId, departmentId, page, size);
    }

    @GetMapping("/deferred-expenses/{id}")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public AssetWorkbenchResponses.Detail deferredExpense(@PathVariable UUID id) {
        AssetWorkbenchResponses.Detail result = query.deferredExpense(id);
        String code = result.summary() == null ? null : result.summary().code();
        detailViewAudit.record(
                "view_deferred_expense_detail",
                "deferred_expenses",
                id,
                code,
                null,
                "递延费用");
        return result;
    }

    @PostMapping("/deferred-expenses")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult createDeferred(
            @Valid @RequestBody AssetWorkbenchRequests.DeferredExpenseDraft body) {
        return workflow.createDeferred(body);
    }

    @PutMapping("/deferred-expenses/{id}")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult updateDeferred(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.DeferredExpenseDraft body) {
        requireExpectedVersion(body.expectedVersion());
        return workflow.updateDeferred(id, body);
    }

    @DeleteMapping("/deferred-expenses/{id}")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public void deleteDeferred(
            @PathVariable UUID id, @RequestParam long expectedVersion) {
        workflow.deleteDraft(id, true, expectedVersion);
    }

    @PostMapping("/deferred-expenses/{id}/submit")
    @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetWorkbenchResponses.WorkflowResult submitDeferred(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.VersionCommand body) {
        return workflow.submit(id, body.expectedVersion(), true);
    }

    @PostMapping("/deferred-expenses/{id}/approve")
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult approveDeferred(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.ApprovalCommand body) {
        return workflow.approve(id, body.expectedVersion(), body.comment(), true);
    }

    @PostMapping("/deferred-expenses/{id}/reject")
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult rejectDeferred(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.ReasonCommand body) {
        return workflow.reject(id, body.expectedVersion(), body.reason(), true);
    }

    @PostMapping("/deferred-expenses/{id}/activate")
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.WorkflowResult activateDeferred(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.VersionCommand body) {
        return workflow.activate(id, body.expectedVersion(), true);
    }

    @PostMapping("/deferred-expenses/{id}/terminate")
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult terminate(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.TerminationCommand body) {
        return workflow.requestTermination(id, body);
    }

    @PostMapping("/deferred-expenses/{id}/approve-termination")
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult approveTermination(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.ReasonCommand body) {
        return workflow.approveTermination(id, body);
    }

    @PostMapping("/deferred-expenses/{id}/reject-termination")
    @PreAuthorize("hasAuthority('finance_asset:dispose')")
    public AssetWorkbenchResponses.WorkflowResult rejectTermination(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.ReasonCommand body) {
        return workflow.rejectTermination(id, body);
    }

    @GetMapping("/asset-categories")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public Items<AssetCategoryContracts.Category> assetCategories(@RequestParam String objectType) {
        return new Items<>(categories.list(objectType));
    }

    @PostMapping("/asset-categories")
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetCategoryContracts.Category createCategory(
            @Valid @RequestBody AssetCategoryContracts.SaveRequest body) { return categories.create(body); }

    @PutMapping("/asset-categories/{id}")
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetCategoryContracts.Category updateCategory(
            @PathVariable UUID id, @Valid @RequestBody AssetCategoryContracts.SaveRequest body) {
        requireExpectedVersion(body.expectedVersion());
        return categories.update(id, body);
    }

    @PostMapping("/asset-categories/{id}/activate")
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetCategoryContracts.Category activateCategory(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.VersionCommand body) {
        return categories.activate(id, body.expectedVersion());
    }

    @GetMapping("/asset-posting-runs")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public PageResponse<AssetWorkbenchResponses.PostingRun> postingRuns(
            @RequestParam(required = false) String period,
            @RequestParam(required = false) String runType,
            @RequestParam(required = false) String status,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return posting.list(period, runType, status, page, size);
    }

    @GetMapping("/asset-posting-runs/{id}")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public AssetWorkbenchResponses.PostingRun postingRun(@PathVariable UUID id) {
        AssetWorkbenchResponses.PostingRun result = posting.get(id);
        String displayName = result.voucherNo() == null || result.voucherNo().isBlank()
                ? result.period()
                : result.voucherNo();
        detailViewAudit.record(
                "view_asset_posting_run_detail",
                "finance_asset_posting_runs",
                id,
                displayName,
                null,
                "资产过账批次");
        return result;
    }

    @PostMapping("/asset-posting-runs/preview")
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.PostingRun preview(
            @Valid @RequestBody AssetWorkbenchRequests.PostingPreviewCommand body) { return posting.preview(body); }

    @PostMapping("/asset-posting-runs/{id}/submit")
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.PostingRun submitRun(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.PostingActionCommand body) {
        return posting.submit(id, body);
    }

    @PostMapping("/asset-posting-runs/{id}/approve")
    @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.PostingRun approveRun(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.PostingActionCommand body) {
        return posting.approve(id, new AssetWorkbenchRequests.ApprovalCommand(body.expectedVersion(), null));
    }

    @PostMapping("/asset-posting-runs/{id}/post")
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.PostingRun postRun(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.PostingActionCommand body) {
        return posting.post(id, body);
    }

    @PostMapping("/asset-posting-runs/{id}/reverse")
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public AssetWorkbenchResponses.PostingRun reverseRun(
            @PathVariable UUID id, @Valid @RequestBody AssetWorkbenchRequests.PostingReasonCommand body) {
        return posting.reverse(id, body);
    }

    @GetMapping("/asset-periods")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public Items<AssetWorkbenchResponses.Period> accountingPeriods() { return new Items<>(periods.list()); }

    @PostMapping("/asset-periods/{period}/close")
    @PreAuthorize("hasAuthority('finance_asset_period:manage')")
    public AssetWorkbenchResponses.Period closePeriod(
            @PathVariable String period, @Valid @RequestBody AssetWorkbenchRequests.PeriodCloseCommand body) {
        return periods.close(period, body.reason(), body.expectedVersion());
    }

    @PostMapping("/asset-periods/{period}/reopen")
    @PreAuthorize("hasAuthority('finance_asset_period:manage')")
    public AssetWorkbenchResponses.Period reopenPeriod(
            @PathVariable String period, @Valid @RequestBody AssetWorkbenchRequests.PeriodReopenCommand body) {
        return periods.reopen(period, body.reason(), body.expectedVersion());
    }

    @PostMapping("/fa/depreciate")
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public void legacyDepreciate(@RequestParam String period) { throw legacyPostingDisabled(); }

    @PostMapping("/fa/amortize")
    @PreAuthorize("hasAuthority('finance_asset:post')")
    public void legacyAmortize(@RequestParam String period) { throw legacyPostingDisabled(); }

    private static ApiException legacyPostingDisabled() {
        return new ApiException(ErrorCode.CONFLICT,
                "Legacy delete-and-rebuild posting is disabled; use /api/finance/asset-posting-runs");
    }

    private static void requireExpectedVersion(Long expectedVersion) {
        if (expectedVersion == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "expectedVersion is required for updates");
        }
    }

    @GetMapping("/reports/fa/depreciation-schedule")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public ReportTableResponse depreciationSchedule() { return legacyReports.depreciationSchedule(); }

    @GetMapping("/reports/fa/amortization-schedule")
    @PreAuthorize("hasAuthority('finance_asset:view')")
    public ReportTableResponse amortizationSchedule() { return legacyReports.amortizationSchedule(); }

    public record Items<T>(List<T> items) {}
}
