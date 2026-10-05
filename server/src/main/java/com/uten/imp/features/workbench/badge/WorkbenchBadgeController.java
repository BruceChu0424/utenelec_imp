package com.uten.imp.features.workbench.badge;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.Arrays;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 工作台徽章汇总接口(ADR-108)。
 *
 * <p>只读、只返回数字; 每个入口是否出现由该入口原计数端点自己的 {@code @PreAuthorize} 判定,
 * 接口本身只要求「已登录的员工」。前端唯一的徽章数据源 badgeSummaryProvider 60s 拉一次。
 *
 * <p>ADR-149: 仓库类来源一律按本人仓库数据范围计数(与列表同一谓词)。仓库任务中心选了某个仓时带
 * {@code scopeWarehouseId}: 服务端先校验(只有主管或负责多个仓的人能选, 越界 403), 再只算仓库模块的
 * 入口, 各来源在这次汇总里都按所选仓计——任务中心的大类与小类数和列表同源, 不再用 list(size:1) 凑数。
 */
@RestController
@RequestMapping("/api/workbench")
@RequiredArgsConstructor
public class WorkbenchBadgeController {

    /** 仓库模块的徽章入口(按所选仓汇总时只算这些)。 */
    static final Set<String> WAREHOUSE_ENTRIES = Arrays.stream(WorkbenchBadgeCatalog.values())
            .filter(entry -> entry.module() == WorkbenchBadgeCatalog.Module.warehouse)
            .map(Enum::name)
            .collect(Collectors.toUnmodifiableSet());

    private final WorkbenchBadgeService service;
    private final WarehouseTaskScopePort warehouseScopes;

    @GetMapping("/badges")
    @PreAuthorize("isAuthenticated() and !principal.visitor")
    public WorkbenchBadgeSummary badges(@RequestParam(required = false) UUID scopeWarehouseId) {
        if (scopeWarehouseId == null) return service.summary();
        return warehouseScopes.withRequestedWarehouse(scopeWarehouseId, () -> service.summary(WAREHOUSE_ENTRIES));
    }
}
