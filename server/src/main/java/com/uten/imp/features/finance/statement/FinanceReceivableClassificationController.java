package com.uten.imp.features.finance.statement;

import com.uten.imp.audit.AuditDetailViewRecorder;
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
    private final AuditDetailViewRecorder detailViewAudit;
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/receipts/{id}")public Map<String,Object> receipt(@PathVariable UUID id){var result=service.receipt(id);
        detailViewAudit.record("view_finance_receipt_line_detail","finance_receipt_lines",id,Objects.toString(result.get("billNo"),null),null,"收款单明细行");return result;}
    @PostMapping("/receipts/{id}")public Result receipt(@PathVariable UUID id,@RequestBody ReceiptInput input){return service.classifyReceipt(id,input);}
    @GetMapping("/customer-offsets/{id}")public Map<String,Object> offset(@PathVariable UUID id){var result=service.offset(id);
        detailViewAudit.record("view_customer_open_item_offset_detail","customer_open_item_offsets",id,null,null,"客户往来抵销");return result;}
    @PostMapping("/customer-offsets/{id}")public Result offset(@PathVariable UUID id,@RequestBody CustomerOffsetInput input){return service.classifyOffset(id,input);}
}
