package com.uten.imp.features.finance.payables;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

import static com.uten.imp.features.finance.payables.SupplierOffsetContracts.*;

@RestController
@RequestMapping("/api/finance/payable-offsets")
@RequiredArgsConstructor
public class SupplierOffsetController {
    private final SupplierOffsetCommandService service;

    @PostMapping
    @PreAuthorize("hasAuthority('supplier_open_item_offset:apply') and hasAuthority('finance:view:all')")
    public ApplyResult apply(@RequestBody ApplyRequest request){return service.apply(request);}

    @PostMapping("/{batchId}/reverse")
    @PreAuthorize("hasAuthority('supplier_open_item_offset:reverse') and hasAuthority('finance:view:all')")
    public void reverse(@PathVariable UUID batchId,@RequestBody ReverseRequest request){
        service.reverse(batchId,request);
    }
}
