package com.uten.imp.features.production.report;

import com.uten.imp.application.port.MaterialTraceabilityReadPort;
import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.time.LocalDate;
import java.util.UUID;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/production/reports/where-used")
@PreAuthorize("hasAuthority('production_where_used:view')")
public class MaterialTraceabilityController {
    private final MaterialTraceabilityReadPort traceability;

    @GetMapping("/subjects")
    public PageResponse<MaterialTraceabilityReadPort.Subject> subjects(
            @RequestParam(defaultValue="goods") String kind,
            @RequestParam(defaultValue="") String keyword,
            @RequestParam(defaultValue="false") boolean exact,
            @RequestParam(defaultValue="1") int page,
            @RequestParam(defaultValue="30") int size) {
        return traceability.subjects(kind,keyword,exact,page,size);
    }

    @GetMapping("/trace")
    public MaterialTraceabilityReadPort.Result trace(
            @RequestParam String subjectType,@RequestParam UUID subjectId,
            @RequestParam(defaultValue="usage") String direction,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required=false) @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="50") int size) {
        var request=com.uten.imp.common.util.ColumnKeywordSearch.currentRequest();
        var columns=com.uten.imp.common.util.ColumnKeywordSearch.requestValues(request);
        String sort=request==null?null:request.getParameter("sort"),order=request==null?null:request.getParameter("order");
        if(columns.isEmpty()&&sort==null)return traceability.trace(subjectType,subjectId,direction,dateFrom,dateTo,page,size);
        return traceability.trace(subjectType,subjectId,direction,dateFrom,dateTo,page,size,columns,sort,order);
    }
}
