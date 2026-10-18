package com.uten.imp.features.admin.serverstatus;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 服务器状态卡的计数来源: 当前越过警告或危急阈值的告警条数。
 *
 * <p>工作台徽章汇总(ADR-108)经控制器代理读取, 资格判定沿用状态页端点本身
 * ({@code server_status:view} 且非访客)。「探测不到」(UNKNOWN)已在状态页以卡片示人,
 * 拿不到数的指标不算「有事要办」, 与原前端口径一致。
 */
@Component
@RequiredArgsConstructor
class ServerStatusWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private static final Set<String> ACTIONABLE = Set.of("WARNING", "CRITICAL");

    private final ServerStatusController controller;

    @Override
    public List<Source> sources() {
        return List.of(new Source("serverStatus", () -> Map.of(
                "alerts",
                controller.current().alerts().stream()
                        .filter(alert -> ACTIONABLE.contains(alert.status()))
                        .count())));
    }
}
