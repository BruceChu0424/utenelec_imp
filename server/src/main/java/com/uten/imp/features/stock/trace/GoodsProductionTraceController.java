package com.uten.imp.features.stock.trace;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.UUID;
import static com.uten.imp.features.stock.trace.GoodsProductionTraceContracts.*;

@RestController
@RequestMapping("/api/stock/goods")
@RequiredArgsConstructor
public class GoodsProductionTraceController {
    private final GoodsProductionTraceQueryService service;

    @GetMapping("/{id}/production-trace")
    @PreAuthorize("hasAuthority('stock:view')")
    public PageResponse<TraceRow> trace(@PathVariable UUID id,
            @RequestParam(defaultValue="usage") String direction,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="20") int size) {
        return service.query(id,direction,page,size);
    }
}
