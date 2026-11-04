package com.uten.imp.features.finance.gl;

import com.uten.imp.features.finance.report.*;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;
import java.io.IOException;
import org.springframework.web.multipart.MultipartFile;
import com.uten.imp.common.files.document.BoundedBodyReader;
import static com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.*;

@RestController
@RequestMapping("/api/finance/expense-analysis")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceExpenseAnalysisController {
    private final FinanceExpenseAnalysisService service;
    @GetMapping("/groups") public Map<String,Object> groups(@RequestParam String period){return Map.of("items",service.groups(period),"feeHeaders",java.util.stream.IntStream.range(0,17).mapToObj(i->FinanceTemplateContract.header("salesExpense",i)).toList());}
    @PostMapping("/groups") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> group(@RequestBody GroupInput input){return Map.of("items",service.saveGroup(input));}
    @PostMapping("/groups/seed-template") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> seed(@RequestParam String period){return Map.of("items",service.seedGroups(period));}
    @GetMapping("/entries") public ReportTableResponse entries(@RequestParam String period,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){return service.entries(period,page,size,FinanceReportColumnOptions.current());}
    @GetMapping("/entries/{id}") public Map<String,Object> entry(@PathVariable UUID id){return service.entry(id);}
    @PostMapping("/assignments") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> assign(@RequestBody AssignmentInput input){return service.assign(input);}
    @GetMapping("/policy") public Map<String,Object> policy(@RequestParam String period){return service.policy(period);}
    @PostMapping("/policy") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> policy(@RequestBody PolicyInput input){return service.savePolicy(input);}
    @GetMapping("/notes") public Map<String,Object> notes(@RequestParam String period){return Map.of("items",service.notes(period));}
    @PostMapping("/notes") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> note(@RequestBody NoteInput input){return Map.of("items",service.saveNote(input));}
    @GetMapping("/labor") public Map<String,Object> labor(@RequestParam String period){return service.labor(period);}
    @PostMapping("/labor") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> labor(@RequestBody LaborSplitInput input){return service.saveLabor(input);}
    @GetMapping("/note-imports") public Map<String,Object> recentImports(@RequestParam String period){return Map.of("items",service.recentNoteImports(period));}
    @GetMapping("/note-imports/{id}") public NoteImportPreview imported(@PathVariable UUID id){return service.importedNotes(id);}
    @PostMapping(value="/notes/import-preview",consumes="multipart/form-data")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public NoteImportPreview preview(@RequestParam String period,@RequestParam("file")MultipartFile file)throws IOException{
        byte[] bytes;try(var stream=file.getInputStream()){bytes=BoundedBodyReader.read(stream,file.getSize(),15L*1024*1024);}return service.previewNotes(period,file.getOriginalFilename(),bytes);
    }
    @PostMapping("/notes/import-apply") @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public Map<String,Object> apply(@RequestBody ImportApply input){return service.applyNotes(input);}
    @PostMapping(value="/notes/import-preview-bytes",consumes="application/octet-stream")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public NoteImportPreview previewBytes(@RequestParam String period,@RequestParam String filename,jakarta.servlet.http.HttpServletRequest request)throws IOException{
        byte[] bytes=BoundedBodyReader.read(request.getInputStream(),request.getContentLengthLong(),15L*1024*1024);return service.previewNotes(period,filename,bytes);
    }
}
