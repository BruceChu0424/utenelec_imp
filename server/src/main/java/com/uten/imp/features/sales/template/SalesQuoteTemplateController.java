package com.uten.imp.features.sales.template;

import com.uten.imp.common.web.DownloadContentDisposition;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/sales/quotes/{quoteId}/templates")
public class SalesQuoteTemplateController {
    private final SalesQuoteTemplateService service;
    public SalesQuoteTemplateController(SalesQuoteTemplateService service) { this.service=service; }
    @GetMapping
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public List<SalesQuoteTemplateStore.TemplateView> list(@PathVariable UUID quoteId) { return service.list(quoteId); }
    @PostMapping("/export")
    @PreAuthorize("hasAuthority('sales_quote:view') and hasAuthority('sales_quote:export') and hasAuthority('sales_order:price:view')")
    public ResponseEntity<byte[]> export(@PathVariable UUID quoteId,
            @RequestBody(required=false) SalesQuoteTemplateService.ExportRequest request) {
        SalesQuoteTemplateService.Download result=service.export(quoteId,request);
        return ResponseEntity.ok().header("Content-Type",result.contentType())
                .header("Content-Disposition",DownloadContentDisposition.attachment(result.fileName()))
                .header("Cache-Control","no-store").body(result.bytes());
    }
}
