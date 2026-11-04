package com.uten.imp.features.finance.gl;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/native-legacy-openings")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view')")
public class NativeLegacyOpeningController {
    private final NativeLegacyOpeningService service;
    public record Withdraw(String reason) { }
    @GetMapping("/targets/{ledgerId}") public Map<String,Object> preview(@PathVariable UUID ledgerId,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.preview(ledgerId,page,size);}
    @GetMapping("/operations/{request}") public Map<String,Object> operation(@PathVariable UUID request){return service.operation(request);}
    @GetMapping("/{id}/receipts/{action}") public Map<String,Object> actionReceipt(@PathVariable UUID id,@PathVariable String action){return service.actionReceipt(id,action);}
    @GetMapping("/{id}") public Map<String,Object> detail(@PathVariable UUID id){return service.response(id);}
    @PostMapping @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> submit(@RequestBody NativeLegacyOpeningService.Submit input){return service.submit(input);}
    @PostMapping("/{id}/approve") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> approve(@PathVariable UUID id){return service.approve(id);}
    @PostMapping("/{id}/withdraw") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> withdraw(@PathVariable UUID id,@RequestBody Withdraw input){return service.withdraw(id,input==null?null:input.reason());}
}
