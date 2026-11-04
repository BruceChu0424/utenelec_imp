package com.uten.imp.features.finance.statement;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceAuxiliaryContracts.*;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/finance/auxiliary-items")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceAuxiliaryController {
    private final FinanceAuxiliaryService service;
    @GetMapping public Map<String,Object> list(@RequestParam(required=false)String accountCode,@RequestParam(required=false)String role,
            @RequestParam(required=false)String keyword,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.list(accountCode,role,keyword,page,size);}
    @PostMapping @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Item save(@RequestBody Save input){return service.save(input);}
    @PostMapping("/parties") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Party party(@RequestBody PartyInput input){return service.createParty(input);}
    @GetMapping("/rules/{accountCode}") public Rule rule(@PathVariable String accountCode){return service.readRule(accountCode);}
    @PutMapping("/rules/{accountCode}") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Rule rule(@PathVariable String accountCode,@RequestBody RuleInput input){return service.saveRule(accountCode,input);}
}
