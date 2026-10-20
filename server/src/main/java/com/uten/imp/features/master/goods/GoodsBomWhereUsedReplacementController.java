package com.uten.imp.features.master.goods;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/production/reports/where-used/replacement")
@RequiredArgsConstructor
public class GoodsBomWhereUsedReplacementController {
    private final GoodsBomWhereUsedReplacementService service;

    @PostMapping("/preview")
    @PreAuthorize("hasAuthority('production_where_used:view') and hasAuthority('goods:bom:edit')")
    public GoodsBomWhereUsedReplacementService.Preview preview(
            @Valid @RequestBody GoodsBomWhereUsedReplacementService.Request request) {
        return service.preview(request);
    }

    @PostMapping("/commit")
    @PreAuthorize("hasAuthority('production_where_used:view') and hasAuthority('goods:bom:edit')")
    public GoodsBomWhereUsedReplacementService.Result commit(
            @Valid @RequestBody GoodsBomWhereUsedReplacementService.Commit request) {
        return service.commit(request);
    }
}
