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
        var request=com.uten.imp.common.util.ColumnKeywordSearch.currentRequest();
        var columns=com.uten.imp.common.util.ColumnKeywordSearch.requestValues(request);
        String sort=request==null?null:request.getParameter("sort"),order=request==null?null:request.getParameter("order");
        if(columns.isEmpty()&&sort==null)return service.query(id,direction,page,size);
        return service.query(id,direction,page,size,columns,sort,order);
    }
}
