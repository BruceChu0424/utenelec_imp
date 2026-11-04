package com.uten.imp.features.applications;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;
import org.springframework.security.access.prepost.PreAuthorize;
import java.util.*;

@RestController
@RequestMapping("/api/business-applications")
@RequiredArgsConstructor
@PreAuthorize("hasAnyAuthority('application:apply','application:apply:travel','application:apply:payment','application:apply:prepayment','application:apply:supplier_payment','application:view','application:approve:department','application:approve:procurement','application:approve:finance_initial','application:approve:finance_review','application:approve:vice_executive','application:approve:executive','application:receive','application:pay','application:prepayment:link_finance')")
public class BusinessApplicationController {
    private final BusinessApplicationService service;
    private final AuditDetailViewRecorder detailViewAudit;
    public record Input(UUID id,String kind,String title,String amount,Map<String,Object> fields,Long expectedVersion){}
    public record Action(Long expectedVersion,String reason,Map<String,Object> fields){}
    @GetMapping("/counts") public Map<String,Object> counts(){return service.counts();}
    @GetMapping({"/mine","/pending","/history","/prepayment-posting"})
    public PageResponse<Map<String,Object>> list(jakarta.servlet.http.HttpServletRequest request,
            @RequestParam(required=false)String kind,@RequestParam(required=false)String status,
            @RequestParam(required=false)String approvalStage,@RequestParam(required=false)String departmentCode,
            @RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="24")int size){
        String path=com.uten.imp.security.SecurityRequestPath.withinApplication(request);
        String queue=path.substring(path.lastIndexOf('/')+1);
        return service.list(queue,kind,status,approvalStage,departmentCode,page,size);
    }
    @GetMapping("/{id}") public Map<String,Object> detail(@PathVariable UUID id){
        var result=service.detail(id);
        detailViewAudit.record("view_business_application_detail","business_applications",id,
            Objects.toString(result.get("applicationNo"),""),null,"行政财务申请");
        return result;
    }
    @GetMapping("/{id}/original-source") public Map<String,Object> originalSource(@PathVariable UUID id){return service.originalSource(id);}
    @GetMapping("/{id}/prepayment-finance-candidates")
    @PreAuthorize("hasAuthority('application:prepayment:link_finance')")
    public PageResponse<Map<String,Object>> prepaymentFinanceCandidates(@PathVariable UUID id,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="24")int size,@RequestParam(required=false)String keyword){return service.prepaymentFinanceCandidates(id,page,size,keyword);}
    @PostMapping
    @PreAuthorize("hasAnyAuthority('application:apply','application:apply:travel','application:apply:payment','application:apply:prepayment','application:apply:supplier_payment')")
    public Map<String,Object> create(@RequestBody Input input){return service.create(input);}
    @PutMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('application:apply','application:apply:travel','application:apply:payment','application:apply:prepayment','application:apply:supplier_payment')")
    public Map<String,Object> update(@PathVariable UUID id,@RequestBody Input input){return service.update(id,input);}
    @PostMapping("/{id}/{action:submit|withdraw|approve|reject|receive|pay|cancel-payment|link-finance|cancel}")
    public Map<String,Object> action(@PathVariable UUID id,@PathVariable String action,@RequestBody Action input){return service.act(id,action,input);}
}
