package com.uten.imp.features.finance.statement;

import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceSubcontractLossPolicyService.*;

@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/subcontract-loss-policies")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceSubcontractLossPolicyController {
    private final FinanceSubcontractLossPolicyService service;
    private final AuditDetailViewRecorder detailViewAudit;
    @GetMapping public Map<String,Object> list(@RequestParam(required=false)UUID supplierId,@RequestParam(required=false)String keyword,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.list(supplierId,keyword,page,size);}
    @GetMapping("/source-choices")public Map<String,Object> sourceChoices(@RequestParam UUID supplierId,@RequestParam(required=false)String keyword,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.sourceChoices(supplierId,keyword,page,size);}
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/{id}")public Map<String,Object> get(@PathVariable UUID id){var result=service.get(id);
        detailViewAudit.record("view_finance_subcontract_loss_policy_detail","finance_subcontract_loss_policies",id,null,null,"委外损耗政策");return result;}
    @GetMapping("/operations/{request}")public Map<String,Object> operation(@PathVariable UUID request){return service.operation(request);}
    @PostMapping public Map<String,Object> save(@RequestBody Save input){return service.save(input);}
    @PostMapping("/{id}/decision")public Map<String,Object> decide(@PathVariable UUID id,@RequestBody Decision input){return service.decide(id,input);}
}
