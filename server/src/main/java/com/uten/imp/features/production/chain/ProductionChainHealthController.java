package com.uten.imp.features.production.chain;

import com.uten.imp.features.production.chain.dto.ChainHealthCategory;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 全链路断链检查器（只读）。权限取「物料分析查看」——能看调度链路的人才能看断链；
 * 不新造权限点，避免检查器本身变成新的权限孤岛。
 */
@RestController
@RequestMapping("/api/production/chain-health")
@RequiredArgsConstructor
public class ProductionChainHealthController {

    private final ProductionChainHealthService service;

    @GetMapping
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public List<ChainHealthCategory> scan(
            @RequestParam(defaultValue = "50") int limit) {
        return service.scan(limit);
    }
}
