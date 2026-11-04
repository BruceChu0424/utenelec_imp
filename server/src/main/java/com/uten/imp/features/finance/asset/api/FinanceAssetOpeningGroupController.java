package com.uten.imp.features.finance.asset.api;

import com.uten.imp.features.finance.asset.application.FinanceAssetOpeningGroupService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/asset-opening-groups")
public class FinanceAssetOpeningGroupController {
    private final FinanceAssetOpeningGroupService service;
    @GetMapping @PreAuthorize("hasAuthority('finance_asset:view')") public Map<String,Object> list(){return service.list();}
    @GetMapping("/vouchers") @PreAuthorize("hasAuthority('finance_asset:edit')") public Map<String,Object> voucher(@RequestParam String voucherNo){return service.voucher(voucherNo);}
    @GetMapping("/{id}") @PreAuthorize("hasAuthority('finance_asset:view')") public Map<String,Object> get(@PathVariable UUID id){return service.get(id);}
    @GetMapping("/{id}/source") @PreAuthorize("hasAuthority('finance_asset:view')") public com.uten.imp.features.finance.report.FinanceTemplateSourceReader.Preview source(@PathVariable UUID id){return service.source(id);}
    @PostMapping @PreAuthorize("hasAuthority('finance_asset:edit')") public Map<String,Object> create(@Valid @RequestBody AssetOpeningGroupContracts.Create input){return service.create(input);}
    @PostMapping("/{id}/approve") @PreAuthorize("hasAuthority('finance_asset:approve')") public Map<String,Object> approve(@PathVariable UUID id,@Valid @RequestBody AssetOpeningGroupContracts.Action input){return service.approve(id,input);}
    @PostMapping("/{id}/revoke") @PreAuthorize("hasAuthority('finance_asset:edit')") public Map<String,Object> revoke(@PathVariable UUID id,@Valid @RequestBody AssetOpeningGroupContracts.Action input){return service.requestRevoke(id,input);}
    @PostMapping("/{id}/approve-revoke") @PreAuthorize("hasAuthority('finance_asset:approve')") public Map<String,Object> approveRevoke(@PathVariable UUID id,@Valid @RequestBody AssetOpeningGroupContracts.Action input){return service.approveRevoke(id,input);}
}
