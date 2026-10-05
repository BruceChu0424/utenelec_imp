package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 车间内料仓的工作台徽章来源 (ADR-108): 来源键 {@code workshopMaterial}, 事实数
 * {@code pendingIssue} / {@code pendingReturn} / {@code counting}。读取函数直接调计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身。
 */
@Component
class WorkshopMaterialWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final WorkshopMaterialBadgeController badges;

    WorkshopMaterialWorkbenchBadgeSources(WorkshopMaterialBadgeController badges) {
        this.badges = badges;
    }

    @Override
    public List<Source> sources() {
        return List.of(new Source("workshopMaterial", () -> WorkbenchBadgeSources.numbers(badges.badgeCounts(null))));
    }
}
