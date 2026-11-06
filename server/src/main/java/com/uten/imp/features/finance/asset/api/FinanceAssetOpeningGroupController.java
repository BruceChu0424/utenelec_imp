package com.uten.imp.features.finance.asset.api;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.finance.asset.application.FinanceAssetOpeningGroupService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/asset-opening-groups")
public class FinanceAssetOpeningGroupController {
    private final FinanceAssetOpeningGroupService service;
    private final AuditDetailViewRecorder detailViewAudit;
    @GetMapping @PreAuthorize("hasAuthority('finance_asset:view')") public Map<String,Object> list(){return service.list();}
    @GetMapping("/vouchers") @PreAuthorize("hasAuthority('finance_asset:edit')") public Map<String,Object> voucher(@RequestParam String voucherNo){return service.voucher(voucherNo);}
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/{id}") @PreAuthorize("hasAuthority('finance_asset:view')") public Map<String,Object> get(@PathVariable UUID id){var result=service.get(id);
        detailViewAudit.record("view_finance_asset_opening_group_detail","finance_asset_opening_groups",id,Objects.toString(result.get("as_of"),null),null,"资产期初接续组");return result;}
    @GetMapping("/{id}/source") @PreAuthorize("hasAuthority('finance_asset:view')") public com.uten.imp.features.finance.report.FinanceTemplateSourceReader.Preview source(@PathVariable UUID id){return service.source(id);}
    @PostMapping @PreAuthorize("hasAuthority('finance_asset:edit')") public Map<String,Object> create(@Valid @RequestBody AssetOpeningGroupContracts.Create input){return service.create(input);}
    @PostMapping("/{id}/approve") @PreAuthorize("hasAuthority('finance_asset:approve')") public Map<String,Object> approve(@PathVariable UUID id,@Valid @RequestBody AssetOpeningGroupContracts.Action input){return service.approve(id,input);}
    @PostMapping("/{id}/revoke") @PreAuthorize("hasAuthority('finance_asset:edit')") public Map<String,Object> revoke(@PathVariable UUID id,@Valid @RequestBody AssetOpeningGroupContracts.Action input){return service.requestRevoke(id,input);}
    @PostMapping("/{id}/approve-revoke") @PreAuthorize("hasAuthority('finance_asset:approve')") public Map<String,Object> approveRevoke(@PathVariable UUID id,@Valid @RequestBody AssetOpeningGroupContracts.Action input){return service.approveRevoke(id,input);}

    @GetMapping("/summaries") @PreAuthorize("hasAuthority('finance_asset:view')")
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<Map<String,Object>> summaries(
            @RequestParam(defaultValue="all") String scope,@RequestParam(defaultValue="1") int page,
            @RequestParam(defaultValue="100") int size,@RequestParam(required=false) String readSnapshotRevision) {
        return service.summaries(scope,page,size,readSnapshotRevision);
    }
}
