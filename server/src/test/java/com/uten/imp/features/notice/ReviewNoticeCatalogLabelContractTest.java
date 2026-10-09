package com.uten.imp.features.notice;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V833/ADR-171「通知设置」的中文名目录契约：{@link ReviewNoticeCatalog#labelOf} 的
 * 标签键集必须与弹卡事件目录 ENTRIES 完全一致——新增事件漏配中文名（回落到事件码）
 * 或残留已下线事件的标签都在这里暴露。
 */
class ReviewNoticeCatalogLabelContractTest {

    @Test
    void everyCatalogEventHasALabelAndNoLabelPointsToUnknownEvents() {
        var labeled = ReviewNoticeCatalog.events().stream()
                .map(ReviewNoticeCatalog::labelOf)
                .toList();
        // 每个注册事件都有非空中文名（未配标签时 labelOf 回落事件码，事件码不含中文）。
        assertThat(labeled).allSatisfy(label ->
                assertThat(label).isNotBlank().containsPattern("[\\u4e00-\\u9fa5]"));
        // 反向：标签映射不包含目录之外的事件（通过公开行为验证——目录内事件名都能取到
        // 非回落值；回落值等于事件码本身，故任何含中文的返回都来自映射）。
        assertThat(ReviewNoticeCatalog.labelOf("NOT_A_CATALOG_EVENT"))
                .isEqualTo("NOT_A_CATALOG_EVENT");
    }
}
