package com.uten.imp.common.columns;

import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;
import java.util.List;

@RestController
@RequestMapping("/api/business-columns")
@RequiredArgsConstructor
public class BusinessColumnController {
    private final BusinessColumnService service;
    @GetMapping
    public List<BusinessColumnService.Definition> search(@RequestParam String scope, @RequestParam(required=false) String q) {
        return service.search(scope, q);
    }
    @GetMapping("/capabilities")
    public BusinessColumnService.Capabilities capabilities(@RequestParam String scope) { return service.capabilities(scope); }
    @PostMapping
    public BusinessColumnService.Definition create(@RequestBody BusinessColumnService.Create request) { return service.create(request); }
}
