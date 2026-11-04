package com.uten.imp.features.finance.statement;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.springframework.http.*;
import org.springframework.web.multipart.MultipartFile;
import java.time.LocalDate;
import java.util.*;
import java.io.IOException;
import static com.uten.imp.application.port.FinanceSubcontractQuantityEvidenceReadPort.*;
import static com.uten.imp.features.finance.statement.FinanceSubcontractQuantityEvidenceContracts.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/subcontract-quantity-evidence")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceSubcontractQuantityEvidenceController {
    private final FinanceSubcontractQuantityEvidenceService service;
    @GetMapping public Map<String,Object> list(@RequestParam UUID supplierId,@RequestParam LocalDate dateFrom,@RequestParam LocalDate dateTo,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.list(new Scope(supplierId,dateFrom,dateTo),page,size);}
    @GetMapping("/{id}")public Map<String,Object> get(@PathVariable UUID id){return service.get(id);}
    @GetMapping("/operations/{request}")public Map<String,Object> operation(@PathVariable UUID request){return service.operation(request);}
    @GetMapping("/approved")public Snapshot approved(@RequestParam UUID supplierId,@RequestParam LocalDate dateFrom,@RequestParam LocalDate dateTo){return service.approved(new Scope(supplierId,dateFrom,dateTo));}
    @GetMapping("/pcs-units")public List<Map<String,Object>> pcsUnits(){return service.pcsUnits();}
    @GetMapping("/sources")public Map<String,Object> sources(@RequestParam UUID supplierId,@RequestParam LocalDate dateFrom,@RequestParam LocalDate dateTo,@RequestParam SourceKind kind,@RequestParam(required=false)String keyword,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size,@RequestParam(required=false)UUID orderItemId){return service.sourceChoices(new Scope(supplierId,dateFrom,dateTo),kind,keyword,page,size,orderItemId);}
    @GetMapping("/sources/{kind}/{id}")public Map<String,Object> source(@PathVariable SourceKind kind,@PathVariable UUID id,@RequestParam UUID supplierId){return service.sourceChoice(new SourceRef(kind,id),supplierId);}
    @PostMapping(consumes=MediaType.APPLICATION_JSON_VALUE)public Map<String,Object> save(@RequestBody Save input){return service.save(input,null,null,null);}
    @PostMapping(consumes=MediaType.MULTIPART_FORM_DATA_VALUE)public Map<String,Object> saveFile(@RequestPart("input")Save input,@RequestPart("file")MultipartFile file)throws IOException{return service.save(input,file.getOriginalFilename(),file.getContentType(),file.getBytes());}
    @PostMapping("/{id}/decision")public Map<String,Object> decide(@PathVariable UUID id,@RequestBody Decision input){return service.decide(id,input);}
    @PostMapping("/{id}/attachment")public ResponseEntity<byte[]> attachment(@PathVariable UUID id){return ResponseEntity.ok().contentType(MediaType.APPLICATION_OCTET_STREAM).header(HttpHeaders.CONTENT_DISPOSITION,ContentDisposition.attachment().filename(service.attachmentFilename(id),java.nio.charset.StandardCharsets.UTF_8).build().toString()).body(service.attachment(id));}
}
