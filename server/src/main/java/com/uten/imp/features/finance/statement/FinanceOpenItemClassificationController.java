package com.uten.imp.features.finance.statement;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationContracts.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/open-item-classifications")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all')")
public class FinanceOpenItemClassificationController {
    private final FinanceOpenItemClassificationService service;
    private final FinanceClassificationCorrectionService corrections;
    @GetMapping("/corrections/graph") public Map<String,Object> graph(@RequestParam List<UUID> ledgerIds){return corrections.graph(ledgerIds);}
    @PostMapping("/corrections") public Map<String,Object> correct(@RequestBody FinanceClassificationCorrectionService.Command command){return corrections.submit(command);}
    @PostMapping("/corrections/preview") public Map<String,Object> previewCorrection(@RequestBody FinanceClassificationCorrectionService.Command command){return corrections.preview(command);}
    @PostMapping("/corrections/requests/{requestId}/resolve") public Map<String,Object> resolveCorrection(@PathVariable UUID requestId,@RequestBody FinanceClassificationCorrectionService.Resolve input){return corrections.resolve(requestId,input);}
    @GetMapping("/corrections/requests/{requestId}") public Map<String,Object> correctionReceipt(@PathVariable UUID requestId){return corrections.receipt(requestId);}
    @GetMapping public Map<String,Object> list(@RequestParam(defaultValue="AP")String direction,@RequestParam(required=false)UUID partyId,
            @RequestParam(required=false)UUID currencyId,@RequestParam(defaultValue="false")boolean pendingOnly,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.sources(direction,partyId,currencyId,pendingOnly,page,size);}
    @GetMapping("/sources/{id}") public Map<String,Object> source(@PathVariable UUID id){return service.source(id);}
    @GetMapping("/sources/{id}/references") public Map<String,Object> references(@PathVariable UUID id,@RequestParam String kind,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.references(id,kind,page,size);}
    @PostMapping("/sources/{id}") public Result source(@PathVariable UUID id,@RequestBody SourceInput input){return service.classifySource(id,input);}
    @GetMapping("/payments/{id}") public Map<String,Object> payment(@PathVariable UUID id){return service.payment(id);}
    @PostMapping("/payments/{id}") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all') and hasAuthority('finance_payment:approve')")
    public Result payment(@PathVariable UUID id,@RequestBody PaymentInput input){return service.classifyPayment(id,input);}
    @GetMapping("/offsets/{id}") public Map<String,Object> offset(@PathVariable UUID id){return service.offset(id);}
    @PostMapping("/offsets/{id}") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all') and hasAuthority('supplier_settlement:confirm')")
    public Result offset(@PathVariable UUID id,@RequestBody OffsetInput input){return service.classifyOffset(id,input);}
}
