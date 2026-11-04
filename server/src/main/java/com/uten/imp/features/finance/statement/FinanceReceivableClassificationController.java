package com.uten.imp.features.finance.statement;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceOpenItemClassificationContracts.*;
import static com.uten.imp.features.finance.statement.FinanceReceivableClassificationContracts.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/open-item-classifications")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all')")
public class FinanceReceivableClassificationController {
    private final FinanceReceivableClassificationService service;
    @GetMapping("/receipts/{id}")public Map<String,Object> receipt(@PathVariable UUID id){return service.receipt(id);}
    @PostMapping("/receipts/{id}")public Result receipt(@PathVariable UUID id,@RequestBody ReceiptInput input){return service.classifyReceipt(id,input);}
    @GetMapping("/customer-offsets/{id}")public Map<String,Object> offset(@PathVariable UUID id){return service.offset(id);}
    @PostMapping("/customer-offsets/{id}")public Result offset(@PathVariable UUID id,@RequestBody CustomerOffsetInput input){return service.classifyOffset(id,input);}
}
