package com.uten.imp.features.finance.statement;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/statement-documents/comparisons")
@PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('finance:view:all')")
public class FinanceStatementComparisonController {
    private final FinanceStatementComparisonService service;
    @PostMapping("/preview")public Map<String,Object> preview(@RequestBody FinanceStatementComparisonService.Input input){return service.preview(input);}
    @PostMapping public Map<String,Object> compare(@RequestBody FinanceStatementComparisonService.Input input){return service.compare(input);}
}
