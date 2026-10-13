package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.audit.AuditDetailViewRecorder;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/master/goods")
@PreAuthorize("hasAuthority('goods:view') and hasAuthority('goods:price_analysis:view')")
public class GoodsSubcontractSupplierController {
    private final GoodsSubcontractSupplierService service;
    private final AuditDetailViewRecorder audit;
    @GetMapping("/{goodsId}/price-analysis/subcontract-capability")
    public GoodsSubcontractSupplierContracts.Capability capability(@PathVariable UUID goodsId) {
        return service.capability(goodsId);
    }
    @GetMapping("/{goodsId}/price-analysis/subcontract-suppliers")
    public GoodsSubcontractSupplierContracts.Result suppliers(@PathVariable UUID goodsId,
            @RequestParam(required=false) Integer days,@RequestParam(required=false) UUID supplierId) {
        var result=service.read(goodsId,days,supplierId);
        audit.record("view_goods_subcontract_supplier_loss","goods",goodsId,null,null,"货品委外商损耗依据");
        return result;
    }
}
