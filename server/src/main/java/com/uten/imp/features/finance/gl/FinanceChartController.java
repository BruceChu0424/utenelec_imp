package com.uten.imp.features.finance.gl;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.files.document.BoundedBodyReader;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;
import java.io.IOException;
import java.util.*;
import com.fasterxml.jackson.databind.JsonNode;
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
    public Map<String,Object> createAccount(@RequestBody JsonNode request){return service.createAccountCommand(request);}
    @GetMapping("/operations/{requestId}") public Map<String,Object> operation(@PathVariable UUID requestId){return service.operationReceipt(requestId);}
    @PostMapping("/operations/{requestId}/cancel") public Map<String,Object> cancelOperation(@PathVariable UUID requestId,@RequestBody com.uten.imp.features.finance.FinanceOperationJournal.Cancellation request){return service.cancelOperation(requestId,request);}
    @GetMapping("/{code}") public Account account(@PathVariable String code){return service.account(code);}
    @PutMapping("/{code}/metadata")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public UpdateAccountResult updateAccount(@PathVariable String code,@RequestBody JsonNode request){return service.updateAccountCommand(code,request);}
    @GetMapping("/{code}/metadata/operations/{requestId}")
    public Map<String,Object> metadataReceipt(@PathVariable String code,@PathVariable UUID requestId){return service.metadataReceipt(code,requestId);}
    @GetMapping("/{code}/metadata") public Map<String,Object> metadata(@PathVariable String code){return service.metadata(code);}
    @PostMapping("/{code}/metadata/operations/{requestId}/cancel")
    public Map<String,Object> cancelMetadata(@PathVariable String code,@PathVariable UUID requestId,@RequestBody com.uten.imp.features.finance.FinanceOperationJournal.Cancellation request){return service.cancelMetadata(code,requestId,request);}
    @GetMapping("/imports") public Map<String,Object> recent(){return Map.of("items",service.recent());}
    @GetMapping("/imports/by-sha/{sha}") public Map<String,Object> importBySha(@PathVariable String sha){return service.importBySha(sha);}
    @GetMapping("/imports/{id}/operations/apply") public Map<String,Object> importApplyOperation(@PathVariable UUID id){return service.importApplyOperation(id);}
    @PostMapping("/imports/{id}/operations/apply/cancel") public Map<String,Object> cancelImportApply(@PathVariable UUID id,@RequestBody com.uten.imp.features.finance.FinanceOperationJournal.Cancellation request){return service.cancelImportApply(id,request);}
    @PostMapping("/imports/{id}/repreview")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> repreview(@PathVariable UUID id,@RequestBody JsonNode request){return service.repreview(id,request);}
    @PostMapping(value="/import-preview",consumes="multipart/form-data")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> preview(@RequestParam("file")MultipartFile file)throws IOException {
        byte[] bytes;try(var stream=file.getInputStream()){bytes=BoundedBodyReader.read(stream,file.getSize(),15L*1024*1024);}
        var result=service.preview(file.getOriginalFilename(),bytes);return service.importView(result.importId());
    }
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/imports/{id}") public Map<String,Object> imported(@PathVariable UUID id){var result=service.importView(id);
        detailViewAudit.record("view_finance_chart_import_detail","finance_chart_imports",id,Objects.toString(result.get("sourceName"),""),null,"科目导入批次");return result;}
    @PostMapping("/import-apply")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> apply(@RequestBody JsonNode request){return service.applyCommand(request);}
    @PutMapping("/{code}")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> map(@PathVariable String code,@RequestBody JsonNode request){return service.mapCommand(code,request);}
    @PostMapping("/{code}/create-target")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit') and hasAuthority('payment_style:create')")
    public Map<String,Object> create(@PathVariable String code,@RequestBody JsonNode request){return service.createTargetCommand(code,request);}

    @GetMapping("/imports/summaries")
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<Map<String,Object>> summaries(
            @RequestParam(defaultValue="all") String scope,@RequestParam(defaultValue="1") int page,
            @RequestParam(defaultValue="100") int size,@RequestParam(required=false) String readSnapshotRevision) {
        return service.summaries(scope,page,size,readSnapshotRevision);
    }
}
