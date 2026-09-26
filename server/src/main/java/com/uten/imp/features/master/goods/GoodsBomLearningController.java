package com.uten.imp.features.master.goods;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequiredArgsConstructor
public class GoodsBomLearningController {
    private final GoodsBomLearningQueryService service;

    @GetMapping("/api/master/goods/{id}/bom-learning")
    @PreAuthorize("hasAuthority('goods:view')")
    public GoodsBomLearningQueryService.Summary summary(@PathVariable UUID id) {
        return service.summary(id);
    }
}
