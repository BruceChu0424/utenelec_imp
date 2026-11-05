package com.uten.imp.features.finance.gl;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.files.document.BoundedBodyReader;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;
import java.io.IOException;
import java.util.*;
import static com.uten.imp.features.finance.gl.FinanceAccountingContracts.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/accounting-imports")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('finance_post:execute')")
public class FinanceAccountingImportController {
    private final FinanceAccountingImportService service;
    private final AuditDetailViewRecorder detailViewAudit;
    @GetMapping public Map<String,Object> recent(){return Map.of("items",service.recent());}
    @GetMapping("/options") public Map<String,Object> options(){return service.options();}
    // 2026-11-04 对账: 0aaffa3aa 财务复刻端点补 DirectView 审计登记(参照 FinanceApplicationController 范式)。
    @GetMapping("/{id}") public Preview get(@PathVariable UUID id){var result=service.get(id);
        detailViewAudit.record("view_finance_accounting_import_detail","finance_accounting_import_batches",id,result.sourceName(),null,"凭证导入批次");return result;}
    @GetMapping("/{id}/compare") public Map<String,Object> compare(@PathVariable UUID id,@RequestParam UUID balanceImportId){return Map.of("issues",service.compare(id,balanceImportId));}
    @PostMapping(value="/preview",consumes="multipart/form-data")
    public Preview preview(@RequestParam String kind,@RequestParam String sourceSystem,@RequestParam("file")MultipartFile file)throws IOException {
        byte[] bytes;try(var input=file.getInputStream()){bytes=BoundedBodyReader.read(input,file.getSize(),15L*1024*1024);}
        return service.preview(kind,sourceSystem,file.getOriginalFilename(),bytes);
    }
    @PostMapping("/{id}/submit") public Preview submit(@PathVariable UUID id,@RequestBody Submit request){return service.submit(id,request);}
    @PostMapping("/{id}/approve") public Result approve(@PathVariable UUID id,@RequestBody Review request){return service.approve(id,request);}
    @PostMapping("/{id}/reject") public Preview reject(@PathVariable UUID id,@RequestBody Review request){return service.reject(id,request);}
    @PostMapping("/{id}/withdraw") public Preview withdraw(@PathVariable UUID id,@RequestBody Review request){return service.withdraw(id,request);}
}
