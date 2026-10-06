package com.uten.imp.features.ai.chat;

import com.uten.imp.features.ai.chat.AiDocumentIntent.Intent;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static org.assertj.core.api.Assertions.assertThat;

class AiDocumentIntentTest {
    @Test void theRosterRequestFromTheIncidentIsAReconcileRequest() {
        assertThat(AiDocumentIntent.parse("这是最新的人事统计出来的人员信息 你看看信息 对照系统里的 不对的补充 缺少的添加"))
                .as("统计 alone would be ANALYZE; reconciling outranks it").isEqualTo(Intent.RECONCILE);
    }

    @ParameterizedTest
    @CsvSource(delimiter = '|', value = {
            "只分析一下这是什么文件，不要生成/新建任何单据|ANALYZE",
            "不要生成订货单，帮我核对一下|ANALYZE",
            "帮我根据这个文件新建报价单并核对|FILL",
            "帮我填写报销单|FILL",
            "生成订货单|FILL",
            "和系统里的员工资料比对一下，缺的补上|RECONCILE",
            "按名单更新员工档案|RECONCILE",
            "把这些员工批量导入系统|IMPORT",
            "批量添加这些员工|IMPORT",
            "统计一下各部门人数|ANALYZE",
            "这是什么文件|QUESTION",
            "这个怎么处理|QUESTION",
            "你好|NONE"})
    void precedenceIsRefusalThenFillThenReconcileThenImportThenAnalyzeThenQuestion(String message, Intent expected) {
        assertThat(AiDocumentIntent.parse(message)).as(message).isEqualTo(expected);
    }

    @Test void emptyOrMissingMessageHasNoIntentAndFullWidthTextIsNormalized() {
        assertThat(AiDocumentIntent.parse("")).isEqualTo(Intent.NONE);
        assertThat(AiDocumentIntent.parse(null)).isEqualTo(Intent.NONE);
        assertThat(AiDocumentIntent.parse("ＩＭＰＯＲＴ these goods")).isEqualTo(Intent.IMPORT);
        assertThat(AiDocumentIntent.requestedWorkflow("Create a sales order from this")).isEqualTo("SALES_ORDER");
        assertThat(AiDocumentIntent.requestedWorkflow("核对员工")).isEqualTo("NONE");
        assertThat(AiDocumentIntent.analysisOnly("Analyze only; do not create a sales order")).isTrue();
    }
}
