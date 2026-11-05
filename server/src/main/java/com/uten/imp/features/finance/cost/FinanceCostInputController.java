package com.uten.imp.features.finance.cost;

import com.uten.imp.audit.AuditDetailViewRecorder;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;
import static com.uten.imp.features.finance.cost.FinanceCostInputContracts.*;

@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/cost-template-inputs")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceCostInputController {
    private final FinanceCostInputService service;
    private final AuditDetailViewRecorder detailViewAudit;
    @GetMapping("/sales") public Map<String,Object> sales(@RequestParam String period,@RequestParam UUID clientId){return service.sales(period,clientId);}
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/plastic/{id}") public Map<String,Object> plastic(@PathVariable UUID id){var result=service.plastic(id);
        detailViewAudit.record("view_finance_plastic_input_detail","finance_plastic_template_inputs",id,Objects.toString(result.get("sourceReference"),null),null,"塑胶成本录入");return result;}
    @GetMapping("/order/{id}") public Map<String,Object> order(@PathVariable UUID id){var result=service.order(id);
        detailViewAudit.record("view_finance_material_order_reference_detail","finance_material_order_references",id,Objects.toString(result.get("orderNo"),null),null,"订单成本参考");return result;}
    @GetMapping("/copper/{id}") public Map<String,Object> copper(@PathVariable UUID id){var result=service.copper(id);
        detailViewAudit.record("view_finance_copper_input_detail","finance_copper_template_inputs",id,Objects.toString(result.get("sourceReference"),null),null,"铜价成本录入");return result;}
    @GetMapping("/operations/{id}") public Map<String,Object> operation(@PathVariable UUID id){var result=service.operation(id);
        detailViewAudit.record("view_finance_cost_input_operation_detail","finance_cost_input_operations",id,null,null,"成本录入保存结果");return result;}
    @PostMapping("/sales") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Saved sales(@Valid @RequestBody Sales input){return service.saveSales(input);}
    @PostMapping("/plastic") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Saved plastic(@Valid @RequestBody Plastic input){return service.savePlastic(input);}
    @PostMapping("/order") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Saved order(@Valid @RequestBody Order input){return service.saveOrder(input);}
    @PostMapping("/copper") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Saved copper(@Valid @RequestBody Copper input){return service.saveCopper(input);}
}
