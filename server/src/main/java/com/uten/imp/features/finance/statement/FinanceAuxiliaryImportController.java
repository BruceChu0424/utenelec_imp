package com.uten.imp.features.finance.statement;

import com.uten.imp.common.files.document.BoundedBodyReader;
import com.uten.imp.common.web.*;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;
import java.io.IOException;
import org.springframework.http.*;
import java.time.LocalDate;
import java.util.*;
import static org.springframework.format.annotation.DateTimeFormat.ISO;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/auxiliary-imports")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceAuxiliaryImportController {
    private final FinanceAuxiliaryImportService service;
    public record Apply(UUID importId) { }
    @GetMapping public Map<String,Object> recent(){return Map.of("items",service.recent());}
    @GetMapping("/operations/{request}")public Map<String,Object> operation(@PathVariable UUID request){return service.operation(request);}
    @GetMapping("/{id}") public FinanceAuxiliaryImportService.Preview imported(@PathVariable UUID id){return service.imported(id);}
    @PostMapping("/{id}/recheck") @PreAuthorize("hasAuthority('payment_style:edit')") public FinanceAuxiliaryImportService.Preview recheck(@PathVariable UUID id,@RequestParam(required=false)UUID requestId){return service.recheck(id,requestId);}
    @PostMapping("/{id}/file")public ResponseEntity<byte[]> file(@PathVariable UUID id){return ResponseEntity.ok().contentType(MediaType.APPLICATION_OCTET_STREAM).header(HttpHeaders.CONTENT_DISPOSITION,ContentDisposition.attachment().filename(service.imported(id).sourceName(),java.nio.charset.StandardCharsets.UTF_8).build().toString()).body(service.sourceBytes(id));}
    @GetMapping("/{id}/comparison") public Map<String,Object> compare(@PathVariable UUID id){return Map.of("items",service.compare(id));}
    @PostMapping(value="/preview",consumes="multipart/form-data")
    @PreAuthorize("hasAuthority('payment_style:edit')")
    public FinanceAuxiliaryImportService.Preview preview(@RequestParam String side,@RequestParam String sourceSystem,
            @RequestParam UUID currencyId,@RequestParam @DateTimeFormat(iso=ISO.DATE)LocalDate dateFrom,
            @RequestParam @DateTimeFormat(iso=ISO.DATE)LocalDate dateTo,@RequestParam("file")MultipartFile file,@RequestParam(required=false)UUID requestId)throws IOException {
        if(!Set.of("receivable","payable").contains(side))throw new ApiException(ErrorCode.VALIDATION_FAILED,"辅助明细类别无效");
        byte[] bytes;try(var stream=file.getInputStream()){bytes=BoundedBodyReader.read(stream,file.getSize(),15L*1024*1024);}
        return service.preview(side.equals("receivable"),sourceSystem,currencyId,dateFrom,dateTo,file.getOriginalFilename(),bytes,requestId,file.getContentType());
    }
    @PostMapping("/directory-apply") @PreAuthorize("hasAuthority('payment_style:edit')") public FinanceAuxiliaryImportService.DirectoryResult apply(@RequestBody Apply request) {
        if(request==null||request.importId()==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择原导入批次");
        return service.applyDirectory(request.importId());
    }
}
