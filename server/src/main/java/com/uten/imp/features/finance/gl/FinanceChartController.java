package com.uten.imp.features.finance.gl;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.files.document.BoundedBodyReader;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;
import java.io.IOException;
import java.util.*;
import static com.uten.imp.features.finance.gl.FinanceChartContracts.*;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/finance/chart")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceChartController {
    private final FinanceChartService service;
    private final AuditDetailViewRecorder detailViewAudit;
    @GetMapping public Map<String,Object> list(){return Map.of("items",service.list());}
    @GetMapping("/options") public Map<String,Object> options(){return service.options();}
    @PostMapping
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public CreateAccountResult createAccount(@RequestBody CreateAccount request){return service.createAccount(request);}
    @PutMapping("/{code}/metadata")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public UpdateAccountResult updateAccount(@PathVariable String code,@RequestBody UpdateAccount request){return service.updateAccount(code,request);}
    @GetMapping("/{code}/metadata/operations/{requestId}")
    public Map<String,Object> metadataReceipt(@PathVariable String code,@PathVariable UUID requestId){return service.metadataReceipt(code,requestId);}
    @GetMapping("/{code}/metadata") public Map<String,Object> metadata(@PathVariable String code){return service.metadata(code);}
    @PostMapping("/{code}/metadata/operations/{requestId}/cancel")
    public Map<String,Object> cancelMetadata(@PathVariable String code,@PathVariable UUID requestId,@RequestBody com.uten.imp.features.finance.FinanceOperationJournal.Cancellation request){return service.cancelMetadata(code,requestId,request);}
    @GetMapping("/imports") public Map<String,Object> recent(){return Map.of("items",service.recent());}
    @PostMapping(value="/import-preview",consumes="multipart/form-data")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Preview preview(@RequestParam("file")MultipartFile file)throws IOException {
        byte[] bytes;try(var stream=file.getInputStream()){bytes=BoundedBodyReader.read(stream,file.getSize(),15L*1024*1024);}
        return service.preview(file.getOriginalFilename(),bytes);
    }
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/imports/{id}") public Preview imported(@PathVariable UUID id){var result=service.imported(id);
        detailViewAudit.record("view_finance_chart_import_detail","finance_chart_imports",id,result.sourceName(),null,"科目导入批次");return result;}
    @PostMapping("/import-apply")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Result apply(@RequestBody Apply request){return service.apply(request);}
    @PutMapping("/{code}")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> map(@PathVariable String code,@RequestBody FinanceChartContracts.Mapping request){return Map.of("items",service.map(code,request));}
    @PostMapping("/{code}/create-target")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit') and hasAuthority('payment_style:create')")
    public Map<String,Object> create(@PathVariable String code,@RequestBody CreateTarget request){return Map.of("items",service.createTarget(code,request));}
}
