package com.uten.imp.features.finance.statement;

import com.uten.imp.application.port.FinanceMaterialStatementSourcePort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.features.finance.report.*;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.format.annotation.DateTimeFormat;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementContracts.*;

@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/material-statements")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceMaterialStatementController {
    private final FinanceMaterialStatementService service;private final FinanceMaterialStatementReferences references;
    private final AuditDetailViewRecorder detailViewAudit;
    @GetMapping public Map<String,Object> list(@RequestParam(required=false)UUID auxiliaryId,@RequestParam(required=false)UUID accountingCurrencyId,@RequestParam(required=false)String q,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.contexts(auxiliaryId,accountingCurrencyId,q,page,size);}
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/{id}") public Map<String,Object> get(@PathVariable UUID id){var result=service.get(id);
        detailViewAudit.record("view_finance_material_context_detail","finance_material_contexts",id,Objects.toString(result.get("auxiliary_id"),null),null,"物料对账单");return result;}
    @PostMapping("/contexts") @PreAuthorize("hasAuthority('payment_style:edit')") public Map<String,Object> context(@RequestBody ContextInput input){return service.saveContext(input);}
    @PostMapping("/drafts") @PreAuthorize("hasAuthority('payment_style:edit')") public Map<String,Object> draft(@RequestBody Draft input){return service.saveDraft(input);}
    @GetMapping("/evidence") public Map<String,Object> history(@RequestParam UUID contextId,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="30")int size){return service.history(contextId,page,size);}
    @GetMapping("/evidence/{id}") public Map<String,Object> evidence(@PathVariable UUID id){var result=service.evidence(id);
        detailViewAudit.record("view_finance_material_evidence_detail","finance_material_evidence",id,Objects.toString(result.get("resource_key"),null),null,"物料对账证据");return result;}
    @PostMapping("/evidence/{id}/submit") @PreAuthorize("hasAuthority('payment_style:edit')") public Map<String,Object> submit(@PathVariable UUID id,@RequestBody Action input){return service.submit(id,input);}
    @PostMapping("/evidence/{id}/{action:approve|reject|withdraw}") public Map<String,Object> decide(@PathVariable UUID id,@PathVariable String action,@RequestBody Action input){return service.decide(id,action,input);}
    @GetMapping("/operations/{id}") public Map<String,Object> operation(@PathVariable UUID id){var result=service.operation(id);
        detailViewAudit.record("view_finance_material_operation_detail","finance_material_operations",id,null,null,"物料对账操作");return result;}
    @PostMapping("/operations/{id}/verify") public Map<String,Object> verify(@PathVariable UUID id,@RequestBody VerifyOperation command){return service.verifyOperation(id,command);}
    @PostMapping("/operations/{id}/cancel-unwritten") public Map<String,Object> cancelUnwritten(@PathVariable UUID id,@RequestBody VerifyOperation command){return service.cancelUnwrittenOperation(id,command);}
    @GetMapping("/options/{kind}") public Map<String,Object> options(@PathVariable String kind,@RequestParam(required=false)String q,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="30")int size){return references.options(kind,q,page,size);}
    @PostMapping("/reference-labels") public Map<String,Object> labels(@RequestBody Map<String,List<String>> input){return references.labels(input);}
    @GetMapping("/sources") public FinanceMaterialStatementSourcePort.Page sources(@RequestParam UUID contextId,@RequestParam FinanceMaterialStatementSourcePort.Kind kind,
        @RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateFrom,@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateTo,
        @RequestParam(required=false)UUID supplierId,@RequestParam(required=false)UUID customerId,@RequestParam(required=false)UUID sourceGoodsId,@RequestParam(required=false)UUID sourceColorId,@RequestParam(required=false)String q,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="30")int size){return references.sources(contextId,kind,dateFrom,dateTo,supplierId,customerId,q,page,size,sourceGoodsId,sourceColorId);}
    @GetMapping("/sources/{kind}/{id}") public FinanceMaterialStatementSourcePort.Fact source(@PathVariable FinanceMaterialStatementSourcePort.Kind kind,@PathVariable UUID id){var result=service.source(new FinanceMaterialStatementSourcePort.Key(kind,id));
        detailViewAudit.record("view_finance_material_source_detail","finance_material_sources",id,null,null,"物料对账来源行");return result;}
    @GetMapping("/gl-sources") public Map<String,Object> gl(@RequestParam UUID contextId,@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateFrom,@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateTo,@RequestParam(required=false)String q,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="30")int size){return references.gl(contextId,dateFrom,dateTo,q,page,size);}
    @GetMapping("/gl-sources/{entry}/{allocation}") public Map<String,Object> quote(@RequestParam UUID contextId,@PathVariable UUID entry,@PathVariable int allocation){return references.quote(contextId,entry,allocation);}
    @GetMapping("/sidebar-report") public Map<String,Object> sidebarReport(@RequestParam UUID contextId,@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateFrom,@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateTo){return service.sidebarReport(contextId,dateFrom,dateTo);}
    @GetMapping("/report") public ReportTableResponse report(@RequestParam UUID auxiliaryId,@RequestParam UUID accountingCurrencyId,@RequestParam(required=false)UUID contextId,
        @RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateFrom,@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateTo,@RequestParam(required=false)String q,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.report(auxiliaryId,accountingCurrencyId,contextId,q,dateFrom,dateTo,page,size,FinanceReportColumnOptions.current());}
    @GetMapping("/adjustment-sources") public Map<String,Object> adjustments(@RequestParam UUID contextId,@RequestParam UUID receivableEntry,@RequestParam int receivableAllocation,@RequestParam AdjustmentPurpose purpose,@RequestParam(required=false)String q,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="30")int size){return references.adjustments(contextId,receivableEntry,receivableAllocation,purpose,q,page,size);}
    @GetMapping("/adjustment-sources/{entry}/{allocation}") public Map<String,Object> adjustmentQuote(@RequestParam UUID contextId,@RequestParam UUID receivableEntry,@RequestParam int receivableAllocation,@RequestParam AdjustmentPurpose purpose,@PathVariable UUID entry,@PathVariable int allocation){return references.adjustmentQuote(contextId,receivableEntry,receivableAllocation,entry,allocation,purpose);}
    @GetMapping("/comparison-targets") public ReportTableResponse comparisonTargets(@RequestParam UUID contextId,@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateFrom,@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE)LocalDate dateTo){return service.snapshotFromAnchorCohort(contextId,dateFrom,dateTo);}
    @PostMapping("/compare") public Map<String,Object> compare(@RequestBody Compare input){return service.compare(input);}
}
