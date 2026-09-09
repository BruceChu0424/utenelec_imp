package com.uten.imp.features.notice;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionWorkshopMaterialNoticeContractTest {

    @Test
    void usesExactSegmentDrawAndSeparatesThreeMaterialStates() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/notice/ChainNoticeService.java"),
                StandardCharsets.UTF_8);
        assertThat(source)
                .contains("link.execution_segment_id=task.segment_id")
                .contains("link.document_type='DRAW'")
                .contains("draw.summary AS draw_summary")
                .contains("string_agg(draw_row.summary")
                .contains("parent.name")
                .contains("物料尚未齐套，任务已分配并持续跟踪")
                .contains("物料已齐套，领料单 ")
                .contains("请按仓库安排领料")
                .contains("物料已领齐，可以开工")
                .doesNotContain("可直接报工")
                .doesNotContain("plan_no=task.plan_no");
    }

    @Test
    void onlyDrawOrIssuedStateCreatesAggregateActionCard() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/notice/ChainNoticeService.java"),
                StandardCharsets.UTF_8);
        assertThat(source)
                .contains("boolean actionable = canStart || (!drawNo.isBlank() && !\"WAITING\".equals(status))")
                .contains("if (actionable)")
                .contains("WAITING/短料只是进度更新")
                .contains("\"normal\"");
    }
}
