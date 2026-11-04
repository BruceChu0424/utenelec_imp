package com.uten.imp.features.finance.report;

import com.uten.imp.common.files.document.*;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;
import org.springframework.security.access.prepost.PreAuthorize;
import java.io.IOException;
import java.util.UUID;

@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/template-imports")
public class FinanceTemplateSourceController {
    private final FinanceTemplateSourceService service;
    @PostMapping(value="/costs/preview",consumes="application/octet-stream")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all') and hasAuthority('payment_style:edit')")
    public FinanceTemplateSourceReader.Preview cost(@RequestParam String template,@RequestParam String period,@RequestParam String filename,@RequestParam(required=false)String sourceSheet,HttpServletRequest request)throws IOException {
        return read(template,period,filename,request,false,sourceSheet);
    }
    @PostMapping(value="/assets/preview",consumes="application/octet-stream")
    @PreAuthorize("hasAuthority('finance_asset:view') and hasAuthority('finance_asset:edit')")
    public FinanceTemplateSourceReader.Preview asset(@RequestParam String template,@RequestParam String period,@RequestParam String filename,@RequestParam(required=false)String sourceSheet,HttpServletRequest request)throws IOException {
        return read(template,period,filename,request,true,sourceSheet);
    }
    @GetMapping("/{id}") public FinanceTemplateSourceReader.Preview get(@PathVariable UUID id){return service.get(id);}
    private FinanceTemplateSourceReader.Preview read(String template,String period,String name,HttpServletRequest request,boolean asset,String sourceSheet)throws IOException {
        byte[] bytes;try(var stream=request.getInputStream()){bytes=BoundedBodyReader.read(stream,request.getContentLengthLong(),(asset?DocumentIntakeProfile.FINANCIAL_ASSET:DocumentIntakeProfile.FINANCIAL_TEMPLATE).maxBytes());}
        return service.preview(template,period,name,bytes,asset,sourceSheet);
    }
}
