package com.uten.imp.features.master.paymentstyle;

import com.uten.imp.features.master.history.MasterInlineEditController;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchRequests;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchResult;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleDetail;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/master")
@RequiredArgsConstructor
public class PaymentStyleWorkspaceController {
    private final PaymentStyleInlineEditService inline;
    private final PaymentStyleService styles;

    /** Literal mapping wins over the generic editor's entity variable. */
    @PatchMapping("/inline-edit/payment-styles/{id}")
    @PreAuthorize("hasAuthority('payment_style:view') and hasAnyAuthority('payment_style:edit','payment_style:reorder','payment_style:status')")
    public PaymentStyleDetail patch(@PathVariable UUID id,@Valid @RequestBody MasterInlineEditController.Patch request) {
        return inline.patch(id,request.expected(),request.changes());
    }

    @PostMapping("/payment-styles/batch-status")
    @PreAuthorize("hasAuthority('payment_style:view') and hasAuthority('payment_style:status')")
    public MasterBatchResult status(@Valid @RequestBody MasterBatchRequests.StatusRequest request) {
        return styles.batchStatus(request.status(),request.items());
    }
}
