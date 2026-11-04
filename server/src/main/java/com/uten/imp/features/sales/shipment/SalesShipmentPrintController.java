package com.uten.imp.features.sales.shipment;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;
@RestController @RequiredArgsConstructor
@RequestMapping("/api/sales/shipments")
@PreAuthorize("hasAnyAuthority('sales_shipment:view','sales_other_shipment:view','sales_shipment_finance:view','warehouse_sales_outbound:view')")
public class SalesShipmentPrintController {
    private final SalesShipmentPrintService service;
    public record Proof(String contentDigest) { }
    @GetMapping("/{id}/print-data") @com.uten.imp.audit.AuditedRead("读取已审发货打印快照")
    public SalesShipmentPrintService.Paper read(@PathVariable UUID id){return service.read(id);}
    @PostMapping("/{id}/print-authorization")
    @com.uten.imp.security.StepUpExempt("只读核对已审发货打印快照，沿原单据范围和内容摘要")
    @com.uten.imp.audit.AuditedRead("核对已审发货打印快照，授权不代表已打印")
    public org.springframework.http.ResponseEntity<Void> authorize(@PathVariable UUID id,@RequestBody Proof input,jakarta.servlet.http.HttpServletRequest request){com.uten.imp.audit.AuditRequestContext.markControlledRead(request);service.authorize(id,input==null?null:input.contentDigest());return org.springframework.http.ResponseEntity.noContent().build();}
}
