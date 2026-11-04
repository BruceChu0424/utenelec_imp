package com.uten.imp.features.finance.payables;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

/** Actual supplier advance sources, distinct from legal AP open items. */
@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/supplier-prepayments")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all')")
public class SupplierPrepaymentController {
    private final SupplierPrepaymentService service;
    @GetMapping public Map<String,Object> list(@RequestParam(required=false) UUID supplierId,@RequestParam(required=false) UUID currencyId,
            @RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.list(supplierId,currencyId,page,size);}
    @GetMapping("/{id}")public Map<String,Object> detail(@PathVariable UUID id){return service.detail(id);}
    @GetMapping("/{id}/settlements")public Map<String,Object> settlements(@PathVariable UUID id,@RequestParam String kind,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.settlements(id,kind,page,size);}
    @PostMapping("/{id}/classification")public Map<String,Object> classify(@PathVariable UUID id,@RequestBody SupplierPrepaymentService.Classify input){return service.classify(id,input);}
    @PostMapping("/{id}/applications")public Map<String,Object> apply(@PathVariable UUID id,@RequestBody SupplierPrepaymentService.Apply input){return service.apply(id,input);}
    public record Reason(String reason) { }
    @PostMapping("/applications/{id}/reverse")public Map<String,Object> reverseApplication(@PathVariable UUID id,@RequestBody Reason input){return service.reverseApplication(id,input.reason());}
    @PostMapping("/{id}/refunds")public Map<String,Object> createRefund(@PathVariable UUID id,@RequestBody SupplierPrepaymentService.Refund input){return service.createRefund(id,input);}
    @GetMapping("/refunds/{id}")public Map<String,Object> refund(@PathVariable UUID id){return service.refund(id);}
    @PostMapping("/refunds/{id}/approve")public Map<String,Object> approveRefund(@PathVariable UUID id){return service.approveRefund(id);}
    @PostMapping("/refunds/{id}/reverse")public Map<String,Object> reverseRefund(@PathVariable UUID id,@RequestBody Reason input){return service.reverseRefund(id,input.reason());}
}
