package com.uten.imp.features.finance.cost;

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
    @GetMapping("/sales") public Map<String,Object> sales(@RequestParam String period,@RequestParam UUID clientId){return service.sales(period,clientId);}
    @GetMapping("/plastic/{id}") public Map<String,Object> plastic(@PathVariable UUID id){return service.plastic(id);}
    @GetMapping("/order/{id}") public Map<String,Object> order(@PathVariable UUID id){return service.order(id);}
    @GetMapping("/copper/{id}") public Map<String,Object> copper(@PathVariable UUID id){return service.copper(id);}
    @GetMapping("/operations/{id}") public Map<String,Object> operation(@PathVariable UUID id){return service.operation(id);}
    @PostMapping("/sales") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Saved sales(@Valid @RequestBody Sales input){return service.saveSales(input);}
    @PostMapping("/plastic") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Saved plastic(@Valid @RequestBody Plastic input){return service.savePlastic(input);}
    @PostMapping("/order") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Saved order(@Valid @RequestBody Order input){return service.saveOrder(input);}
    @PostMapping("/copper") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Saved copper(@Valid @RequestBody Copper input){return service.saveCopper(input);}
}
