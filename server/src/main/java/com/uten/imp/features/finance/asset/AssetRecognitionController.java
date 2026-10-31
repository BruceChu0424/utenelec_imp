package com.uten.imp.features.finance.asset;

import com.uten.imp.features.finance.asset.api.*;
import com.uten.imp.features.finance.asset.application.FinanceAssetRecognitionReversalService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;
import org.springframework.security.access.prepost.PreAuthorize;
import java.util.UUID;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/{ledger:fixed-assets|deferred-expenses}/{id}")
public class AssetRecognitionController {
    private final FinanceAssetRecognitionReversalService reversals;
    @PostMapping("/reverse-recognition") @PreAuthorize("hasAuthority('finance_asset:reverse')")
    public AssetWorkbenchResponses.WorkflowResult request(@PathVariable String ledger,@PathVariable UUID id,
            @Valid @RequestBody AssetWorkbenchRequests.ReasonCommand command){return reversals.request(id,deferred(ledger),command);}
    @PostMapping("/approve-recognition-reversal") @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult approve(@PathVariable String ledger,@PathVariable UUID id,
            @Valid @RequestBody AssetWorkbenchRequests.VersionCommand command){return reversals.approve(id,deferred(ledger),command);}
    @PostMapping("/reject-recognition-reversal") @PreAuthorize("hasAuthority('finance_asset:approve')")
    public AssetWorkbenchResponses.WorkflowResult reject(@PathVariable String ledger,@PathVariable UUID id,
            @Valid @RequestBody AssetWorkbenchRequests.ReasonCommand command){return reversals.reject(id,deferred(ledger),command);}
    @PostMapping("/post-recognition-reversal") @PreAuthorize("hasAuthority('finance_asset:reverse')")
    public AssetWorkbenchResponses.WorkflowResult post(@PathVariable String ledger,@PathVariable UUID id,
            @Valid @RequestBody AssetWorkbenchRequests.VersionCommand command){return reversals.post(id,deferred(ledger),command);}
    private static boolean deferred(String ledger){return ledger.equals("deferred-expenses");}
}
