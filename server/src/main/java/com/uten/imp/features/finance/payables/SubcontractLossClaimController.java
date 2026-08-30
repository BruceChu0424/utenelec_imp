package com.uten.imp.features.finance.payables;

import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

import static com.uten.imp.features.finance.payables.SubcontractLossClaimContracts.*;

/** Finance work queue for subcontract excess-loss responsibility and claims. */
@RestController
@RequestMapping("/api/finance/subcontract-loss-claims")
@RequiredArgsConstructor
public class SubcontractLossClaimController {
    private final SubcontractLossClaimService service;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping
    @PreAuthorize("hasAuthority('subcontract_loss_claim:view')")
    public CasePage list(
            @RequestParam(required = false) UUID supplierId,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "30") int size) {
        return service.list(supplierId, status, keyword, page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('subcontract_loss_claim:view')")
    public CaseDetail detail(@PathVariable UUID id) {
        CaseDetail result = service.detail(id);
        String wasteBillNo = result.summary() == null
                ? null
                : result.summary().wasteBillNo();
        detailViewAudit.record(
                "view_subcontract_loss_claim_detail",
                "subcontract_loss_claims",
                id,
                wasteBillNo,
                null,
                "委外损耗索赔");
        return result;
    }

    @PostMapping("/{id}/decision")
    @PreAuthorize("hasAuthority('subcontract_loss_claim:review')")
    public CaseDetail decide(@PathVariable UUID id, @RequestBody DecisionRequest request) {
        return service.decide(id, request);
    }

    @PostMapping("/{caseId}/resolutions/{resolutionId}/fulfill")
    @PreAuthorize("hasAuthority('subcontract_loss_claim:fulfill')")
    public CaseDetail fulfill(
            @PathVariable UUID caseId,
            @PathVariable UUID resolutionId,
            @RequestBody FulfillmentRequest request) {
        return service.fulfill(caseId, resolutionId, request);
    }
    @PostMapping("/{caseId}/resolutions/{resolutionId}/reverse-fulfillment")
    @PreAuthorize("hasAuthority('subcontract_loss_claim:fulfill') and hasAuthority('subcontract_loss_claim:reverse')")
    public CaseDetail reverseFulfillment(
            @PathVariable UUID caseId,
            @PathVariable UUID resolutionId,
            @RequestBody ReverseFulfillmentRequest request){
        return service.reverseFulfillment(caseId,resolutionId,request);
    }


    @PostMapping("/{id}/reverse")
    @PreAuthorize("hasAuthority('subcontract_loss_claim:reverse')")
    public CaseDetail reverse(@PathVariable UUID id, @RequestBody ReverseRequest request) {
        return service.reverse(id, request);
    }
}
