package com.uten.imp.features.finance.gl;

import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/native-legacy-openings")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view')")
public class NativeLegacyOpeningController {
    private final NativeLegacyOpeningService service;
    private final AuditDetailViewRecorder detailViewAudit;
    public record Withdraw(String reason) { }
    @GetMapping("/targets/{ledgerId}") public Map<String,Object> preview(@PathVariable UUID ledgerId,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.preview(ledgerId,page,size);}
    @GetMapping("/operations/{request}") public Map<String,Object> operation(@PathVariable UUID request){return service.operation(request);}
    @GetMapping("/{id}/receipts/{action}") public Map<String,Object> actionReceipt(@PathVariable UUID id,@PathVariable String action){return service.actionReceipt(id,action);}
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/{id}") public Map<String,Object> detail(@PathVariable UUID id){var result=service.response(id);
        detailViewAudit.record("view_finance_legacy_opening_review_detail","finance_native_legacy_opening_reviews",id,Objects.toString(result.get("source_fingerprint"),null),null,"旧期初对应复核");return result;}
    @PostMapping @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> submit(@RequestBody NativeLegacyOpeningService.Submit input){return service.submit(input);}
    @PostMapping("/{id}/approve") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> approve(@PathVariable UUID id){return service.approve(id);}
    @PostMapping("/{id}/withdraw") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> withdraw(@PathVariable UUID id,@RequestBody Withdraw input){return service.withdraw(id,input==null?null:input.reason());}
}
