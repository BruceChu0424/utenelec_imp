package com.uten.imp.features.production.execution;

import com.uten.imp.features.production.mrp.ProductionExecutionBatchService;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/production/execution-batches")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('production_execution:view') and hasAuthority('production_execution:start')")
public class ProductionExecutionBatchController {
    private final ProductionExecutionBatchService service;
    @PostMapping("/preview")
    public ProductionExecutionBatch.Preview preview(@RequestBody ProductionExecutionBatch.PreviewRequest request) {
        return service.preview(request);
    }
    @PostMapping("/submit")
    public ProductionExecutionBatch.Result submit(@RequestBody ProductionExecutionBatch.SubmitRequest request) {
        return service.submit(request);
    }
}
