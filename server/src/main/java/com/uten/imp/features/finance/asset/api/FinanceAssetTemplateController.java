package com.uten.imp.features.finance.asset.api;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.finance.asset.application.FinanceAssetTemplateService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.format.annotation.DateTimeFormat;
import java.time.LocalDate;
import java.util.*;

@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/asset-template-inputs")
public class FinanceAssetTemplateController {
    private final FinanceAssetTemplateService service;
    private final AuditDetailViewRecorder detailViewAudit;
    @GetMapping @PreAuthorize("hasAuthority('finance_asset:view')")
    public Map<String,Object> get(@RequestParam String objectType,@RequestParam UUID objectId,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate asOf){return service.get(objectType,objectId,asOf);}
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/operations/{id}") @PreAuthorize("hasAuthority('finance_asset:view')")
    public Map<String,Object> operation(@PathVariable UUID id){var result=service.operation(id);
        detailViewAudit.record("view_finance_asset_template_operation_detail","finance_asset_template_operations",id,null,null,"资产模板保存结果");return result;}
    @PostMapping @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetTemplateContracts.Saved save(@Valid @RequestBody AssetTemplateContracts.Save input){return service.save(input);}
}
