package com.uten.imp.features.production.execution;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/production/workshop-tasks/draw-request")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
public class ProductionDrawRequestController {
    private final ProductionDrawRequestService service;

    @PostMapping("/preview")
    public ProductionDrawRequest.Preview preview(@RequestBody ProductionDrawRequest.PreviewRequest request) {
        return service.preview(request);
    }

    @PostMapping("/submit")
    public ProductionDrawRequest.Result submit(@RequestBody ProductionDrawRequest.SubmitRequest request) {
        return service.submit(request);
    }
}
