package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.FinancePayableStatementAdjustmentPort.*;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/payable-statement-adjustments")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all')")
public class FinancePayableStatementAdjustmentController {
    private final FinancePayableStatementAdjustmentService service;
    public record Reason(String reason){ }
    @GetMapping public Map<String,Object> choices(@RequestParam UUID statementReviewId,@RequestParam String expectedSourceFingerprint,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size,@RequestParam(defaultValue="1")int adjustmentPage){return service.choices(new Context(statementReviewId,expectedSourceFingerprint),page,size,adjustmentPage);}
    @PostMapping("/preview")public Preview preview(@RequestBody FinancePayableStatementAdjustmentService.PreviewInput request){return service.preview(request.context(),request.lines());}
    @PostMapping public Map<String,UUID> submit(@RequestBody Submit request){return Map.of("id",service.submit(request));}
    @GetMapping("/{id}")public Map<String,Object> detail(@PathVariable UUID id){return service.detail(id);}
    @PostMapping("/{id}/approve")public List<Effect> approve(@PathVariable UUID id){return service.approve(id);}
    @PostMapping("/{id}/reverse")public List<Effect> reverse(@PathVariable UUID id,@RequestBody Reason request){return service.reverse(id,request.reason());}
}
