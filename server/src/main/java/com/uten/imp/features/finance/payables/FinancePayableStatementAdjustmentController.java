package com.uten.imp.features.finance.payables;

import com.uten.imp.application.port.FinancePayableStatementAdjustmentPort.*;
import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/payable-statement-adjustments")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all')")
public class FinancePayableStatementAdjustmentController {
    private final FinancePayableStatementAdjustmentService service;
    private final AuditDetailViewRecorder detailViewAudit;
    public record Reason(String reason){ }
    @GetMapping public Map<String,Object> choices(@RequestParam UUID statementReviewId,@RequestParam String expectedSourceFingerprint,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size,@RequestParam(defaultValue="1")int adjustmentPage,@RequestParam(required=false)String part,@RequestParam(required=false)String readSnapshotRevision){var context=new Context(statementReviewId,expectedSourceFingerprint);return part==null?service.choices(context,page,size,adjustmentPage):service.versionedChoices(context,page,size,adjustmentPage,part,readSnapshotRevision);}
    @PostMapping("/preview")public Preview preview(@RequestBody FinancePayableStatementAdjustmentService.PreviewInput request){return service.preview(request.context(),request.lines());}
    @PostMapping public Map<String,UUID> submit(@RequestBody Submit request){return Map.of("id",service.submit(request));}
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/{id}")public Map<String,Object> detail(@PathVariable UUID id){var result=service.detail(id);
        detailViewAudit.record("view_finance_payable_adjustment_detail","finance_payable_statement_adjustments",id,Objects.toString(result.get("sourceReference"),null),null,"应付费用调整");return result;}
    @PostMapping("/{id}/approve")public List<Effect> approve(@PathVariable UUID id){return service.approve(id);}
    @PostMapping("/{id}/reverse")public List<Effect> reverse(@PathVariable UUID id,@RequestBody Reason request){return service.reverse(id,request.reason());}
}
