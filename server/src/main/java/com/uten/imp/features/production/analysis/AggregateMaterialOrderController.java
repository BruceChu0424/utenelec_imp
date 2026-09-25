package com.uten.imp.features.production.analysis;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/production/material-analyses/{id}/aggregate-orders")
public class AggregateMaterialOrderController {
    private final AggregateMaterialOrderPreviewService previews;
    private final Writer writer;

    @PostMapping("/preview")
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public Preview preview(@PathVariable UUID id,@Valid @RequestBody PreviewRequest request) {
        return previews.preview(id,request);
    }

    @PostMapping("/submit")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and (hasAuthority('production_material_analysis:notify') or hasAuthority('production_material_analysis:generate'))")
    public SubmitResult submit(@PathVariable UUID id,@Valid @RequestBody SubmitRequest request) {
        return writer.submit(id,request);
    }

    @PostMapping("/actions/{actionId}/cancel")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and (hasAuthority('production_material_analysis:notify') or hasAuthority('production_material_analysis:generate'))")
    public MaterialAnalysisContracts.AnalysisView cancel(@PathVariable UUID id,@PathVariable UUID actionId,
            @Valid @RequestBody MaterialAnalysisContracts.CancelRequest request) {
        return writer.cancel(id,actionId,request);
    }
}
