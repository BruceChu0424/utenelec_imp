package com.uten.imp.features.subcontract.draw;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 委外任务中心「领料」的计数来源(ADR-108 / ADR-143 §4.1): 事实 {@code subcontractDraw.drawable}
 * = 调用者可见、可以动手的可领委外任务数; 没有委外领料权限恒为 0。读取函数直接调用计数端点的
 * 控制器方法, 资格判定与数字都沿用端点本身。
 */
@Component
@RequiredArgsConstructor
class SubcontractDrawWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final SubcontractDrawController controller;

    @Override
    public List<Source> sources() {
        return List.of(new Source("subcontractDraw", () -> WorkbenchBadgeSources.numbers(controller.count())));
    }
}
