package com.uten.imp.features.dashboard;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** 生产看板聚合接口（/api/dashboard/overview）。 */
@RestController
@RequestMapping("/api/dashboard")
@RequiredArgsConstructor
public class DashboardOverviewController {

    private final DashboardOverviewService service;

    @GetMapping("/overview")
    @PreAuthorize("isAuthenticated()")
    public DashboardOverviewDto overview() {
        return service.overview();
    }
}
