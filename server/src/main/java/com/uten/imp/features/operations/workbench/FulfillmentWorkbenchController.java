package com.uten.imp.features.operations.workbench;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/operations/workbench")
@RequiredArgsConstructor
public class FulfillmentWorkbenchController {

    private final FulfillmentWorkbenchQueryService queryService;

    @GetMapping("/warehouse")
    @PreAuthorize("hasAnyAuthority('stock_doc:view')")
    public FulfillmentWorkbenchPage warehouse(
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "") String exception,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return queryService.query("WAREHOUSE", status, keyword, exception, page, size);
    }

    @GetMapping("/purchase")
    @PreAuthorize("hasAnyAuthority('purchase_request:view','purchase_order:view','purchase_receipt:view','purchase_return:view')")
    public FulfillmentWorkbenchPage purchase(
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "") String exception,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return queryService.query("PURCHASE", status, keyword, exception, page, size);
    }

    @GetMapping("/subcontract")
    @PreAuthorize("hasAnyAuthority('subcontract_inquiry:view','subcontract_application:view','subcontract_order:view','subcontract_receipt:view','subcontract_material_issue:view','subcontract_return:view','subcontract_material_return:view','subcontract_waste:view')")
    public FulfillmentWorkbenchPage subcontract(
            @RequestParam(defaultValue = "") String status,
            @RequestParam(defaultValue = "") String exception,
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "50") int size) {
        return queryService.query("SUBCONTRACT", status, keyword, exception, page, size);
    }
}
