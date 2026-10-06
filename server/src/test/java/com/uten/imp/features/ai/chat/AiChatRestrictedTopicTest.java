package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * ADR-159 (live N2, N3) with a fake model over the repository's real design documents: a sales reader asking how goods
 * cost is worked out or how payslips are made gets a plain 「this is finance's / personnel's rules」 answer, with no model
 * call and so no hidden or tangential passage sent anywhere; the finance or personnel reader asking the same question is
 * answered from those documents as before.
 */
class AiChatRestrictedTopicTest {
    private static final String CONVERSATION = "4f0f6c1e-8a59-4d2a-9d41-6a0f2b7f3c22";
    private static final String FINANCE_REPLY = "这个问题属于财务方面的规则，你目前没有这部分的查看权限，所以我不能凭别的资料猜。"
            + "需要的话请联系财务同事或管理员。";
    private static final String HR_REPLY = "这个问题属于人事方面的规则，你目前没有这部分的查看权限，所以我不能凭别的资料猜。"
            + "需要的话请联系人事同事或管理员。";
    private static final Set<String> SALES = Set.of("SELF", "SALES", "SUBCONTRACT");
    private static AiDocKnowledge docs;

    private final ObjectMapper json = new ObjectMapper();
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final AiChatEvidence evidence = mock(AiChatEvidence.class);
    private final AiChatToolRegistry tools = mock(AiChatToolRegistry.class);
    private final AiChatPageGuideCatalog pages = mock(AiChatPageGuideCatalog.class);
    private final AiChatActionProposalService proposals = mock(AiChatActionProposalService.class);
    private final AiJobHandler.AiJobContext ctx = mock(AiJobHandler.AiJobContext.class);
    private AuthUser actor;
    private AiChatJobHandler handler;

    @BeforeAll static void documents() {
        docs = AiDocKnowledge.fromDirectory(Path.of("..", "docs"));
    }

    @BeforeEach void before() {
        handler = new AiChatJobHandler(access, evidence, tools, pages, proposals, docs, json, AiChatUserScopeTest.directory());
        reader(SALES, "ai:use", "sales_order:view", "subcontract_order:view");
        when(access.requireChat()).thenAnswer(call -> actor);
        when(ctx.params()).thenReturn(Map.of());
        when(ctx.aiAllowed()).thenReturn(true);
        when(ctx.remainingAiCalls()).thenReturn(3);
        when(ctx.jobId()).thenReturn(UUID.randomUUID());
        // The read tools every chat user has: they answer "where" and "why can't I open", not rule questions.
        List<AiChatToolPort> available = List.of(tool(AiChatDialogueSupport.FEATURE_DIRECTORY), tool(AiChatDialogueSupport.MY_ACCESS));
        when(tools.available()).thenReturn(available);
        when(pages.resolve(anyString(), any())).thenReturn(Optional.empty());
        when(proposals.refreshCards(any())).thenReturn(List.of());
        when(evidence.stampMatches(any())).thenReturn(true);
        when(evidence.conversation(any(), anyInt())).thenReturn(List.of());
    }

    private void reader(Set<String> domains, String... permissions) {
        actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reader", Set.of(permissions), false, true, false);
        when(access.domains()).thenReturn(domains);
    }

    private AiChatToolPort tool(String name) {
        AiChatToolPort tool = mock(AiChatToolPort.class);
        when(tool.name()).thenReturn(name);
        when(tool.title()).thenReturn(name);
        when(tool.description()).thenReturn("read tool");
        when(tool.domain()).thenReturn("SELF");
        when(tool.available()).thenReturn(true);
        when(tool.requestedBy(anyString())).thenReturn(true);
        when(tool.parameters()).thenReturn(Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("keyword", Map.of("type", "string")), "required", List.of("keyword")));
        when(tool.execute(anyMap())).thenReturn(Map.of("reply", name + " 的结果"));
        when(tools.available(name)).thenReturn(Optional.of(tool));
        return tool;
    }

    private void ask(String message, String locale) throws Exception {
        var body = new LinkedHashMap<String, Object>();
        body.put("message", message);
        body.put("conversationId", CONVERSATION);
        if (locale != null) body.put("locale", locale);
        byte[] bytes = json.writeValueAsBytes(Map.of("request", body, "access", Map.of("actor", "test")));
        when(ctx.input()).thenReturn(new AiJobHandler.AiJobInput("conversation.json", "application/json", "JSON", bytes.length,
                bytes, "hash"));
    }

    private void model(String intent, String reply, List<String> sources) throws Exception {
        when(ctx.completeJson(any())).thenReturn(new AiCompletionPort.AiCompletionResult(json.writeValueAsString(Map.of(
                "focus", "", "intent", intent, "reply", reply, "usedSources", sources, "tool", "", "arguments", Map.of(),
                "action", Map.of("name", "", "args", Map.of()))), "provider", "model", 1, 1, 1));
    }

    private AiCompletionPort.AiCompletionRequest sent() {
        var captor = ArgumentCaptor.forClass(AiCompletionPort.AiCompletionRequest.class);
        verify(ctx, atLeastOnce()).completeJson(captor.capture());
        return captor.getValue();
    }

    /** Live N3: the cost rules are finance's; the workshop's cost allocation is not sent in their place. */
    @Test void aSalesReaderAskingHowGoodsCostIsWorkedOutIsToldItIsFinancesRules() throws Exception {
        ask("货品成本是怎么算出来的", null);
        model("KNOWLEDGE", "成本按成本对象归集。", List.of());
        var result = handler.process(ctx);
        assertThat(result).containsEntry("reply", FINANCE_REPLY).containsEntry("intent", "UNSUPPORTED")
                .containsEntry("_scope", "RESTRICTED_TOPIC").doesNotContainKey("sources").doesNotContainKey("fallback");
        verify(ctx, never()).completeJson(any());
        // Nothing of a hidden document is named: neither a title nor a passage.
        assertThat(result.get("reply").toString()).doesNotContain("货品成本工作台", "成本对象", "《");
    }

    /** Live N2, both the short and the full question: payroll is personnel's. */
    @Test void aSalesReaderAskingHowPayslipsAreMadeIsToldItIsPersonnelsRules() throws Exception {
        for (String question : List.of("工资条怎么生成", "工资条怎么生成 生成完要谁审核")) {
            ask(question, null);
            var result = handler.process(ctx);
            assertThat(result).as(question).containsEntry("reply", HR_REPLY).containsEntry("_scope", "RESTRICTED_TOPIC");
            assertThat(result.get("reply").toString()).doesNotContain("PUBLISHED", "待发布", "工资条生成页");
        }
        verify(ctx, never()).completeJson(any());
        // The interface language is followed.
        ask("工资条怎么生成", "en");
        assertThat(handler.process(ctx).get("reply").toString()).startsWith("This question is about the rules of personnel")
                .contains("a colleague in personnel or an administrator");
    }

    /** The finance reader is answered from the cost documents, through the model as before. */
    @Test void aFinanceReaderStillGetsTheGroundedAnswer() throws Exception {
        reader(Set.of("SELF", "FINANCE"), "ai:use", "goods:view", "goods:cost:view", "finance:view");
        var found = docs.search("货品成本是怎么算出来的", Set.of("SELF", "FINANCE"));
        assertThat(found).anySatisfy(chunk -> assertThat(chunk.domains()).contains("FINANCE"));
        var cost = found.stream().filter(chunk -> chunk.domains().contains("FINANCE")).findFirst().orElseThrow();
        assertThat(AiDocKnowledge.visible(cost, SALES)).as("the same passage is hidden from the sales reader").isFalse();
        ask("货品成本是怎么算出来的", null);
        model("KNOWLEDGE", "货品成本按平台说明里的成本口径计算，具体见所引用的成本说明。", List.of("knowledge." + cost.id()));
        var result = handler.process(ctx);
        assertThat(sent().systemPrompt()).contains("knowledge." + cost.id());
        assertThat(result).containsEntry("intent", "KNOWLEDGE").doesNotContainKey("_scope");
        assertThat(result.get("reply").toString()).isNotEqualTo(FINANCE_REPLY);
    }

    /** The personnel reader asking the full live question gets the payroll pages. */
    @Test void aPersonnelReaderStillGetsThePayrollPages() throws Exception {
        reader(Set.of("SELF", "HR"), "ai:use", "employee:view", "payroll:view");
        ask("工资条怎么生成 生成完要谁审核", null);
        model("KNOWLEDGE", "工资条先生成再审核。", List.of());
        handler.process(ctx);
        assertThat(sent().systemPrompt()).contains("工资条");
    }

    /** "Where is it" and "why can't I open it" stay with the read tools, which name the missing permission. */
    @Test void aWhereOrAccessQuestionStaysWithTheReadTools() throws Exception {
        ask("工资条在哪看", null);
        when(ctx.completeJson(any())).thenReturn(new AiCompletionPort.AiCompletionResult(json.writeValueAsString(Map.of(
                "intent", "TOOL", "tool", AiChatDialogueSupport.FEATURE_DIRECTORY, "arguments", Map.of("keyword", "工资条"))),
                "provider", "model", 1, 1, 1));
        var result = handler.process(ctx);
        assertThat(result).containsEntry("intent", "TOOL").doesNotContainKey("_scope");
        verify(ctx, atLeastOnce()).completeJson(any());
    }

    /** The sales reader's own rules are answered as before (no restricted answer for them). */
    @Test void theReadersOwnRulesAreAnsweredAsBefore() throws Exception {
        ask("报价单怎么转成订货单", null);
        model("CLARIFY", "你想问报价的哪一步？", List.of());
        var result = handler.process(ctx);
        assertThat(result).doesNotContainKey("_scope");
        verify(ctx, atLeastOnce()).completeJson(any());
    }

    @Test void theRestrictedAnswerNamesOnlyTheDepartment() {
        assertThat(AiChatJobHandler.restrictedReply(Set.of("FINANCE"), "zh")).isEqualTo(FINANCE_REPLY);
        assertThat(AiChatJobHandler.restrictedReply(Set.of("HR"), "zh")).isEqualTo(HR_REPLY);
        assertThat(AiChatJobHandler.restrictedReply(Set.of("ADMIN"), "zh")).contains("系统管理方面的规则", "请联系系统管理员。");
        assertThat(AiChatJobHandler.restrictedReply(Set.of("HR", "FINANCE"), "zh")).contains("财务、人事方面的规则", "相关部门的同事或管理员");
        assertThat(AiChatJobHandler.restrictedReply(Set.of("FINANCE"), "ko")).contains("재무", "관리자");
        // A decision both sales and finance read is named after both: either department opens it.
        assertThat(AiChatJobHandler.restrictedReply(Set.of("FINANCE", "SALES"), "zh")).startsWith("这个问题属于销售、财务方面的规则");
    }
}
