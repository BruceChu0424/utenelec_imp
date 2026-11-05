package com.uten.imp.features.finance.receipt;

import com.uten.imp.features.finance.receivables.SalesOrderCollectionPreviewService;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.math.BigDecimal;
import java.util.UUID;

@RestController
@RequiredArgsConstructor
public class ReceiptOrderCollectionController {
    private final SalesOrderCollectionPreviewService service;
    private final com.uten.imp.features.finance.receivables.ReceiptOrderSourceAccess orderSources;
    private final com.uten.imp.features.finance.receivables.ReceiptLedgerSourceAccess ledgerSources;
    private static final String READ_AUTHORITY="hasAnyAuthority('finance_receipt:create','finance_receipt:edit') "
            +"and (hasAuthority('sales_order:view') or hasAuthority('finance:view:all'))";
    public record Request(@NotNull UUID salesOrderId,@NotNull @DecimalMin(value="0",inclusive=false) BigDecimal amountOriginal,UUID appliedLedgerId) { }
    @PostMapping("/api/finance/receipts/order-collection-preview")
    @PreAuthorize(READ_AUTHORITY)
    public SalesOrderCollectionPreviewService.Preview preview(@Valid @RequestBody Request request,jakarta.servlet.http.HttpServletRequest http) {
        com.uten.imp.audit.AuditRequestContext.markControlledRead(http);
        return service.preview(request.salesOrderId(),request.amountOriginal(),request.appliedLedgerId());
    }
    @GetMapping("/api/finance/receipts/order-sources")
    @PreAuthorize(READ_AUTHORITY)
    public com.uten.imp.common.web.PageResponse<com.uten.imp.features.finance.receivables.ReceiptOrderSourceAccess.Choice> choices(
            @RequestParam(required=false)String keyword,@RequestParam(name="search.billNo",required=false)String billNo,
            @RequestParam(required=false)UUID sellerId,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="20")int size,
            @RequestParam(required=false)String sort,@RequestParam(required=false)String order){
        return orderSources.choices(keyword,billNo,sellerId,page,size,sort,order);
    }
    @GetMapping("/api/finance/receipts/shipment-sources")
    @PreAuthorize("hasAnyAuthority('finance_receipt:create','finance_receipt:edit')")
    public com.uten.imp.common.web.PageResponse<java.util.Map<String,Object>> shipmentSources(
            @RequestParam(required=false) UUID clientId,@RequestParam(required=false)String keyword,
            @RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="50")int size){
        return ledgerSources.choices(clientId,keyword,page,size);
    }
}
