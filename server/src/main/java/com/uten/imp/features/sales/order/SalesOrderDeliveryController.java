package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.uten.imp.common.delivery.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Price-free entry points for the sales editor; no order authorization is gained by a goods UUID. */
@RestController
@RequestMapping("/api/sales/orders")
@RequiredArgsConstructor
public class SalesOrderDeliveryController {
    private final BomDeliveryService service;
    private final SalesOrderDeliveryReadService frozenReads;
    public record PreviewRequest(@NotNull UUID goodsId, @JsonAlias("quantity") @NotNull
            @jakarta.validation.constraints.DecimalMin(value="0",inclusive=false)
            @jakarta.validation.constraints.Digits(integer=14,fraction=4) BigDecimal qty,
            UUID unitId, BigDecimal unitRate, @Valid DeliveryPlan deliveryPlan) {}
    public record RuleRequest(@NotNull Boolean mandatoryAssembly,
            @NotNull DeliveryBom.MaterialRole materialRole, List<DeliveryPlan.Operation> requiredOperations,
            @jakarta.validation.constraints.NotBlank String bomFingerprint, UUID rootGoodsId) {}

    @GetMapping("/delivery-bom")
    @PreAuthorize("hasAuthority('sales_order:create') or hasAuthority('sales_order:edit')"
            + " or hasAuthority('goods:bom:view') or hasAuthority('goods:bom:edit')")
    public DeliveryBom.Snapshot bom(@RequestParam UUID goodsId) { return service.snapshot(goodsId); }

    @GetMapping("/{orderId}/items/{itemId}/delivery-bom")
    @PreAuthorize("hasAuthority('sales_order:view') or hasAuthority('sales_order_manager:view') or hasAuthority('sales_order_finance:view')")
    public SalesOrderDeliveryReadService.Frozen frozen(@PathVariable UUID orderId,@PathVariable UUID itemId,
            @RequestParam(defaultValue="SALES") SalesOrderDeliveryReadService.Context context) {
        return frozenReads.read(orderId,itemId,context);
    }

    @PostMapping("/delivery-preview")
    @PreAuthorize("hasAuthority('sales_order:create') or hasAuthority('sales_order:edit')")
    public DeliveryBom.Preview preview(@Valid @RequestBody PreviewRequest request) {
        return service.resolve(request.goodsId(), request.unitId(), request.unitRate(), request.qty(), request.deliveryPlan());
    }

    /** Explicit master classification; hard_gate is deliberately not reused as an assembly prohibition. */
    @PutMapping("/delivery-bom/rules/{edgeId}")
    @PreAuthorize("hasAuthority('goods:bom:edit')")
    public DeliveryBom.Snapshot rule(@PathVariable UUID edgeId, @Valid @RequestBody RuleRequest request) {
        return service.updateRule(edgeId,request.mandatoryAssembly(),request.materialRole(),
                request.requiredOperations(),request.bomFingerprint(),request.rootGoodsId());
    }
}
