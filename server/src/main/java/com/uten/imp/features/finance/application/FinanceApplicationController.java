package com.uten.imp.features.finance.application;
import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;
import static com.uten.imp.features.finance.application.FinanceApplicationContracts.*;

@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/applications")
@PreAuthorize("hasAnyAuthority('finance_application:view','finance_application:apply','expense:apply','payroll:generate','expense:settings')")
public class FinanceApplicationController {
    private final FinanceApplicationService service;
    private final FinanceApplicationReferences references;
    private final FinanceApplicationContinuationService continuation;
    private final AuditDetailViewRecorder detailViewAudit;
    @PostMapping("/continuation/review") public Map<String,Object> reviewContinuation(@RequestBody FinanceApplicationContinuationContracts.Review input){return continuation.review(input);}
    @PostMapping("/continuation/confirm") public Map<String,Object> confirmContinuation(@RequestBody FinanceApplicationContinuationContracts.Confirm input){return continuation.confirm(input);}
    @GetMapping("/continuation/{origin}/receipt") public Map<String,Object> continuationReceipt(@PathVariable UUID origin){return continuation.receipt(origin);}
    @GetMapping("/intake") @PreAuthorize("hasAnyAuthority('finance_expense:create','finance_payment:create','expense:apply','payroll:generate','finance_application:apply')")
    public Map<String,Object> intake(){return service.intake();}
    @GetMapping("/references") public Map<String,Object> references(){return references.references();}
    @GetMapping("/sources") public Map<String,Object> sources(@RequestParam String kind,@RequestParam(required=false)String search,@RequestParam(required=false)UUID supplierId,@RequestParam(required=false)UUID currencyId){return references.sources(kind,search,supplierId,currencyId);}
    @GetMapping("/catalog") public Map<String,Object> catalog(){return service.catalog();}
    @GetMapping("/counts") public Map<String,Long> counts(){return service.counts();}
    @GetMapping public Map<String,Object> list(@RequestParam(defaultValue="mine")String queue,@RequestParam(required=false)String search,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="20")int size){return service.list(queue,search,page,size);}
    @GetMapping("/{id}") public Map<String,Object> detail(@PathVariable UUID id){var result=service.detail(id);
        detailViewAudit.record("view_finance_application_detail","finance_applications",id,Objects.toString(result.get("application_no"),null),null,"财务申请单");return result;}
    @GetMapping("/{id}/operations/{requestId}") public Map<String,Object> receipt(@PathVariable UUID id,@PathVariable UUID requestId){return service.receipt(id,requestId);}
    @PostMapping public Map<String,Object> save(@RequestBody DraftInput input){return service.save(input);}
    @PostMapping("/{id}/submit") public Map<String,Object> submit(@PathVariable UUID id,@RequestBody Action input){return service.submit(id,input);}
    @PostMapping("/{id}/withdraw") public Map<String,Object> withdraw(@PathVariable UUID id,@RequestBody Action input){return service.withdraw(id,input);}
    @PostMapping("/{id}/approve") public Map<String,Object> approve(@PathVariable UUID id,@RequestBody Action input){return service.review(id,input,true);}
    @PostMapping("/{id}/reject") public Map<String,Object> reject(@PathVariable UUID id,@RequestBody Action input){return service.review(id,input,false);}
    @PostMapping("/{id}/assign") public Map<String,Object> assign(@PathVariable UUID id,@RequestBody Assign input){return service.assign(id,input);}
    @PostMapping("/{id}/payroll-preparation") public Map<String,Object> payroll(@PathVariable UUID id,@RequestBody PayrollPreparation input){return service.preparePayroll(id,input);}
    @PostMapping("/{id}/invoice-verification") public Map<String,Object> invoice(@PathVariable UUID id,@RequestBody InvoiceVerification input){return service.verifyExpenseInvoice(id,input);}
    @PostMapping("/{id}/execute") public Map<String,Object> execute(@PathVariable UUID id,@RequestBody Execute input){return service.execute(id,input);}
    @PostMapping("/{id}/confirm") public Map<String,Object> confirm(@PathVariable UUID id,@RequestBody Action input){return service.confirm(id,input);}
    @PostMapping("/{id}/unconfirm") public Map<String,Object> unconfirm(@PathVariable UUID id,@RequestBody Action input){return service.unconfirm(id,input);}
    @PostMapping("/{id}/reverse") public Map<String,Object> reverse(@PathVariable UUID id,@RequestBody Action input){return service.reverse(id,input);}
}
