package com.uten.imp.features.finance.asset.api;

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
    @GetMapping @PreAuthorize("hasAuthority('finance_asset:view')")
    public Map<String,Object> get(@RequestParam String objectType,@RequestParam UUID objectId,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate asOf){return service.get(objectType,objectId,asOf);}
    @GetMapping("/operations/{id}") @PreAuthorize("hasAuthority('finance_asset:view')")
    public Map<String,Object> operation(@PathVariable UUID id){return service.operation(id);}
    @PostMapping @PreAuthorize("hasAuthority('finance_asset:edit')")
    public AssetTemplateContracts.Saved save(@Valid @RequestBody AssetTemplateContracts.Save input){return service.save(input);}
}
