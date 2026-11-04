package com.uten.imp.features.finance.payables;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.http.*;
import java.io.IOException;
import java.util.*;

/** Financial reconciliation actions belong to the existing supplier statement/payables workflow. */
@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/procurement-payable-recognitions")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('ar_ap_ledger:view') and hasAuthority('finance:view:all')")
public class ProcurementPayableRecognitionController {
    private final ProcurementPayableRecognitionService service;
    @GetMapping public Map<String,Object> list(@RequestParam(required=false)UUID supplierId,@RequestParam(required=false)UUID currencyId,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.recognitions(supplierId,currencyId,page,size);}
    @GetMapping("/policy")public Map<String,Object> policy(){return service.policy();}
    @PutMapping("/policy")public Map<String,Object> configure(@RequestBody ProcurementPayableRecognitionService.PolicyInput input){return service.configure(input);}
    @GetMapping("/candidates")public Map<String,Object> candidates(@RequestParam(required=false)UUID supplierId,@RequestParam(required=false)UUID currencyId,@RequestParam(required=false)String status,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.candidates(supplierId,currencyId,status,page,size);}
    @PostMapping(consumes=MediaType.MULTIPART_FORM_DATA_VALUE)public Map<String,Object> submit(@RequestPart("command")ProcurementPayableRecognitionService.Submission input,@RequestPart("file")MultipartFile file)throws IOException{
        try(var stream=file.getInputStream()){
            return service.submit(input,file.getOriginalFilename(),file.getContentType(),com.uten.imp.common.files.document.BoundedBodyReader.read(stream,file.getSize(),com.uten.imp.common.files.document.DocumentIntakeProfile.DEFAULT.maxBytes()));
        }
    }
    @GetMapping("/operations/{request}")public Map<String,Object> operation(@PathVariable UUID request){return service.operation(request);}
    @GetMapping("/{id}")public Map<String,Object> detail(@PathVariable UUID id){return service.recognition(id);}
    @PostMapping("/{id}/approve")public Map<String,Object> approve(@PathVariable UUID id){return service.approve(id);}
    public record Reason(String reason) { }
    @PostMapping("/{id}/reverse")public Map<String,Object> reverse(@PathVariable UUID id,@RequestBody Reason input){return service.reverse(id,input.reason());}
    @PostMapping("/{id}/file")public ResponseEntity<byte[]> file(@PathVariable UUID id){var row=service.recognition(id);return ResponseEntity.ok().contentType(MediaType.APPLICATION_OCTET_STREAM).header(HttpHeaders.CONTENT_DISPOSITION,ContentDisposition.attachment().filename(Objects.toString(row.get("file_name"),"confirmation.bin"),java.nio.charset.StandardCharsets.UTF_8).build().toString()).body(service.confirmationFile(id));}
}
