package com.uten.imp.features.documents;

import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * 跨模块单据的计数来源: 21 类草稿与三类「财务已退回」。
 *
 * <p>工作台徽章汇总(ADR-108)的计数来源: 读取函数直接调用原计数端点的控制器方法,
 * 资格判定与数字都沿用端点本身, 不另写口径。
 */
@Component
@RequiredArgsConstructor
class DocumentWorkbenchBadgeSources implements WorkbenchBadgeSources {

    private final DocumentDraftCountController controller;

    @Override
    public List<Source> sources() {
        return List.of(
                new Source("drafts", () -> WorkbenchBadgeSources.numbers(controller.draftCounts())),
                new Source("financeRejected", () -> WorkbenchBadgeSources.numbers(controller.financeRejectedCounts())));
    }
}
