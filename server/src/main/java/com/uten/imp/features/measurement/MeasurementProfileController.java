package com.uten.imp.features.measurement;

import com.uten.imp.features.measurement.MeasurementCaptureContracts.ClearOverrideRequest;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.OverrideRequest;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ProfileResolution;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ResolveBatchRequest;
import com.uten.imp.features.measurement.MeasurementCaptureContracts.ResolveBatchResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** Read and manual-governance API. Reviewed evidence has no public write endpoint. */
@RestController
@RequestMapping("/api/measurement/profiles")
@RequiredArgsConstructor
public class MeasurementProfileController {

    private final MeasurementProfileService service;

    @PostMapping("/resolve-batch")
    @PreAuthorize("hasAuthority('goods:view')")
    public ResolveBatchResponse resolveBatch(
            @Valid @RequestBody ResolveBatchRequest request) {
        return service.resolveBatch(request);
    }

    @PostMapping("/{goodsId}/{operationFamily}/override")
    @PreAuthorize("hasAuthority('goods:edit')")
    public ProfileResolution override(
            @PathVariable UUID goodsId,
            @PathVariable String operationFamily,
            @Valid @RequestBody OverrideRequest request) {
        return service.override(goodsId, operationFamily, request);
    }

    @PostMapping("/{goodsId}/{operationFamily}/clear-override")
    @PreAuthorize("hasAuthority('goods:edit')")
    public ProfileResolution clearOverride(
            @PathVariable UUID goodsId,
            @PathVariable String operationFamily,
            @Valid @RequestBody ClearOverrideRequest request) {
        return service.clearOverride(goodsId, operationFamily, request);
    }
}
