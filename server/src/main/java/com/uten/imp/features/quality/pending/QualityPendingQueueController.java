package com.uten.imp.features.quality.pending;

import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.security.access.prepost.PreAuthorize;

@RestController @RequestMapping("/api/quality/pending-disposals") @RequiredArgsConstructor
public class QualityPendingQueueController {
    private final QualityPendingQueueService service;
    @PostMapping("/query")
    @PreAuthorize("hasAnyAuthority('procurement_inspection:view','production_quality_inspection:view')")
    public QualityPendingQueueService.Page query(@RequestBody QualityPendingQueueService.Request request){return service.query(request);}
}
