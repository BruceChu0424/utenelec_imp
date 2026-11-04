package com.uten.imp.features.finance.statement;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.http.ResponseEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.web.multipart.MultipartFile;
import java.io.IOException;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceStatementDocumentContracts.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/statement-documents")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceStatementDocumentController {
    private final FinanceStatementDocumentService service;
    @GetMapping("/profiles") public Map<String,Object> profiles(@RequestParam String kind,@RequestParam String templateKey,
            @RequestParam(required=false)String partyRole,@RequestParam(required=false)UUID partyId,@RequestParam UUID currencyId,
            @RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.profiles(kind,templateKey,partyRole,partyId,currencyId,page,size);}
    @GetMapping("/profiles/{id}") public Map<String,Object> profile(@PathVariable UUID id){return service.profile(id);}
    @PostMapping("/profiles") public Map<String,Object> save(@RequestBody ProfileSave input){return service.saveProfile(input);}
    @PostMapping("/profiles/{id}/review") public Map<String,Object> review(@PathVariable UUID id,@RequestBody Decision input){return service.decideProfile(id,input);}
    /** Context only: period totals are supplied internally by the exact original report, never editable HTTP money. */
    @PostMapping("/metadata") public Map<String,Object> metadata(@RequestBody Context context){return service.metadata(context,null);}
    @PostMapping("/preview") public Map<String,Object> preview(@RequestBody Context context){return service.preview(context);}
    @PostMapping("/reviews") public Map<String,Object> submit(@RequestBody ReviewSave input){return service.submitReview(input);}
    @PostMapping("/settlement-preview") public Map<String,Object> settlementPreview(@RequestBody SettlementPreview input){return service.previewSettlement(input);}
    @PostMapping("/settlement-reviews") public Map<String,Object> settlementSubmit(@RequestBody SettlementSave input){return service.submitSettlement(input);}
    @PostMapping("/reviews/query") public Map<String,Object> reviews(@RequestBody Context context,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.reviews(context,page,size);}
    @GetMapping("/reviews/{id}") public Map<String,Object> review(@PathVariable UUID id){return service.review(id);}
    @GetMapping("/reviews/{id}/original-table")public com.uten.imp.features.finance.report.ReportTableResponse originalTable(@PathVariable UUID id,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.originalTable(id,page,size);}
    @PostMapping("/reviews/{id}/decision")public Map<String,Object> decision(@PathVariable UUID id,@RequestBody Decision input){return service.decideReview(id,input);}
    @PostMapping(value="/reviews/{id}/counterpart",consumes=MediaType.MULTIPART_FORM_DATA_VALUE)
    public Map<String,Object> counterpart(@PathVariable UUID id,@RequestPart("input")CounterpartConfirmation input,@RequestPart("file")MultipartFile file)throws IOException{
        return service.confirmCounterpart(id,input,file.getOriginalFilename(),file.getContentType(),file.getBytes());
    }
    @GetMapping("/reviews/{id}/counterpart-file")public ResponseEntity<byte[]> counterpartFile(@PathVariable UUID id){return ResponseEntity.ok().contentType(MediaType.APPLICATION_OCTET_STREAM).header(HttpHeaders.CONTENT_DISPOSITION,org.springframework.http.ContentDisposition.attachment().filename(service.counterpartFilename(id),java.nio.charset.StandardCharsets.UTF_8).build().toString()).body(service.counterpartFile(id));}
}
