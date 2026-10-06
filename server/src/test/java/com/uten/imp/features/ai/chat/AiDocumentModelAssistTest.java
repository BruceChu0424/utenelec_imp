package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.SpreadsheetGridReader;
import com.uten.imp.features.ai.chat.AiDocumentIntent.Intent;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class AiDocumentModelAssistTest {
    private final AiJobHandler.AiJobContext ctx = mock(AiJobHandler.AiJobContext.class);

    @Test void outboundRequestDescribesOnlyStructureAndNoFabricatedPersonalValue() throws Exception {
        var profile = AiDocumentProfiler.profile(SpreadsheetGridReader.read(AiDocumentFixtures.roster(true, 86, true), DocumentKind.XLS));
        String message = "核对一下 身份证 " + AiDocumentFixtures.people(1).getFirst().idNumber() + " 电话 138-0000-0001";
        var request = AiDocumentModelAssist.request("XLS", profile, null, message, UUID.randomUUID());
        String serialized = new ObjectMapper().writeValueAsString(request);
        for (String value : AiDocumentFixtures.rosterValues(86)) assertThat(serialized).doesNotContain(value);
        assertThat(serialized).contains("姓名 [SHORT_TEXT]", "身份证号码 [ID18]", "手机号码 [PHONE11]", "data rows under the header: 86")
                .doesNotContain("13800000001", "138-0000");
        assertThat(request.purpose()).isEqualTo(AiDocumentModelAssist.PURPOSE);
        assertThat(request.userParts()).hasSize(1).allMatch(part -> part instanceof AiCompletionPort.AiText text && text.untrusted());
        assertThat(request.jsonSchema()).containsKey("properties");
    }

    @Test void onlyStrictEnumAnswersWithEnoughConfidenceCount() {
        assertThat(AiDocumentModelAssist.parse("{\"type\":\"EMPLOYEE_ROSTER\",\"intent\":\"RECONCILE\",\"confidence\":\"HIGH\"}"))
                .contains(new AiDocumentModelAssist.Guess("EMPLOYEE_ROSTER", Intent.RECONCILE));
        assertThat(AiDocumentModelAssist.parse("{\"type\":\"GOODS_LIST\",\"intent\":\"NONE\",\"confidence\":\"MEDIUM\"}")).isPresent();
        for (String invalid : List.of("{\"type\":\"EMPLOYEE_ROSTER\",\"intent\":\"RECONCILE\",\"confidence\":\"LOW\"}",
                "{\"type\":\"UNKNOWN\",\"intent\":\"NONE\",\"confidence\":\"HIGH\"}",
                "{\"type\":\"MIXED_DOCUMENT\",\"intent\":\"NONE\",\"confidence\":\"HIGH\"}",
                "{\"type\":\"EMPLOYEE_ROSTER\",\"intent\":\"FILL\",\"confidence\":\"HIGH\"}",
                "{\"type\":\"EMPLOYEE_ROSTER\",\"intent\":\"RECONCILE\",\"confidence\":\"HIGH\",\"route\":\"/admin\"}",
                "{\"type\":\"employee_roster\",\"intent\":\"RECONCILE\",\"confidence\":\"HIGH\"}",
                "[\"EMPLOYEE_ROSTER\"]", "not json", ""))
            assertThat(AiDocumentModelAssist.parse(invalid)).as(invalid).isEmpty();
    }

    @Test void namesAcrossAPivotHeaderOrAsSheetNamesNeverLeave() throws Exception {
        byte[] pivot = AiDocumentFixtures.table(false, "钱试一", List.of(
                List.of("日期", "产品名称", "孙试二", "欧阳试三", "李试四(组长)", "设备点检说明"),
                List.of("2026-10-01", "螺丝", "12", "15", "9", "正常")));
        var profile = AiDocumentProfiler.profile(SpreadsheetGridReader.read(pivot, DocumentKind.XLSX));
        String serialized = new ObjectMapper().writeValueAsString(AiDocumentModelAssist.request("XLSX", profile, null, "看看", UUID.randomUUID()));
        assertThat(serialized).doesNotContain("钱试一", "孙试二", "欧阳试三", "李试四")
                .contains("name \\\"#\\\"", "日期 [DATE]", "产品名称 [SHORT_TEXT]", "# [INTEGER]", "设备点检说明 [SHORT_TEXT]");
        assertThat(AiDocumentModelAssist.outbound("姓名")).isEqualTo("姓名");
        assertThat(AiDocumentModelAssist.outbound("部门")).isEqualTo("部门");
        assertThat(AiDocumentModelAssist.outbound("夏侯试三")).isEqualTo("#");
        for (String word : List.of("停车位", "车牌号", "登记", "周一", "民族", "工龄"))
            assertThat(AiDocumentModelAssist.outbound(word)).as("an ordinary word is kept").isEqualTo(word);
        assertThat(AiDocumentModelAssist.outbound("Sheet1")).isEqualTo("Sheet1");
        assertThat(AiDocumentModelAssist.outbound("2026年10月考勤")).isEqualTo("#年10月考勤");
    }

    @Test void titleLineIsSentOnlyWhenShortDigitFreeAndNotABareName() {
        assertThat(AiDocumentModelAssist.safeTitle("设备点检记录汇总")).isEqualTo("设备点检记录汇总");
        assertThat(AiDocumentModelAssist.safeTitle("钱试一二")).as("looks like a person name").isNull();
        assertThat(AiDocumentModelAssist.safeTitle("2026年设备点检记录")).isNull();
        assertThat(AiDocumentModelAssist.safeTitle("联系 a@example.test")).isNull();
        assertThat(AiDocumentModelAssist.safeTitle("这是一个超过二十个字符长度限制的文件标题行内容")).isNull();
        assertThat(AiDocumentModelAssist.safeTitle(null)).isNull();
    }

    @Test void noCallWithoutPermissionQuotaOrStructureAndAnyFailureStaysUnknown() throws Exception {
        var profile = AiDocumentProfiler.profile(SpreadsheetGridReader.read(AiDocumentFixtures.roster(false, 3, false), DocumentKind.XLSX));
        when(ctx.jobId()).thenReturn(UUID.randomUUID());
        when(ctx.aiAllowed()).thenReturn(false);
        assertThat(AiDocumentModelAssist.guess(ctx, "XLSX", profile, null, "")).isEmpty();
        when(ctx.aiAllowed()).thenReturn(true);
        when(ctx.remainingAiCalls()).thenReturn(0);
        assertThat(AiDocumentModelAssist.guess(ctx, "XLSX", profile, null, "")).isEmpty();
        when(ctx.remainingAiCalls()).thenReturn(3);
        assertThat(AiDocumentModelAssist.guess(ctx, "PNG", AiDocumentProfiler.Profile.empty(), null, "看看")).isEmpty();
        verify(ctx, never()).completeJson(any());
        when(ctx.completeJson(any())).thenThrow(new AiCompletionPort.AiCallException(AiCompletionPort.AiErrorCategory.TIMEOUT, "超时"));
        assertThat(AiDocumentModelAssist.guess(ctx, "XLSX", profile, null, "")).isEmpty();
    }
}
