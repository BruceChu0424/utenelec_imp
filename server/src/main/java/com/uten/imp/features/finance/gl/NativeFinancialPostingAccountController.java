package com.uten.imp.features.finance.gl;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/native-posting-accounts")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class NativeFinancialPostingAccountController {
    private final NativeFinancialPostingAccountService service;
    @GetMapping public Map<String,Object> list(@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.configurations(page,size);}
    @GetMapping("/choices") public Map<String,Object> choices(){return service.choices();}
    @GetMapping("/accounts") public List<Map<String,Object>> accounts(@RequestParam String role){return service.accountChoices(role);}
    @PostMapping @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> submit(@RequestBody NativeFinancialPostingAccountService.Configuration input){return service.submit(input);}
    @PostMapping("/{id}/approve") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> approve(@PathVariable UUID id){return service.approve(id);}
    @GetMapping("/debts/{ledgerId}") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view')")
    public Map<String,Object> debt(@PathVariable UUID ledgerId){return service.debtCorrespondencePreview(ledgerId);}
    @PostMapping("/debt-reviews") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> submitDebt(@RequestBody NativeFinancialPostingAccountService.DebtCorrespondence input){return service.submitDebtCorrespondence(input);}
    @PostMapping("/debt-reviews/{id}/approve") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('ar_ap_ledger:view') and hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public Map<String,Object> approveDebt(@PathVariable UUID id){return service.approveDebtCorrespondence(id);}
}
