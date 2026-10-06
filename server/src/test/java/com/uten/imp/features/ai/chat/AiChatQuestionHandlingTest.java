package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.job.AiJobService;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anySet;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Question handling through the chat job handler with a fake model: topic switches and follow-ups (P0-3), the
 * off-topic check (P0-2), data words and tool eligibility (P0-7), honest "not found" answers (P0-8), pages outside
 * the user's departments (P0-10), document search on pages (P0-11), the navigation guard (P1-6), the user's access
 * line (P1-9) and fallback hygiene.
 */
class AiChatQuestionHandlingTest {
    private static final String CONVERSATION = "0b5c43f4-5ad4-4e5b-9e4f-2f6f3b0f7a11";
    private static final String SURPLUS_DOC = "99-决策记录-ADR/ADR-901-采购允许超收.md";
    private static final String DIRECT_DOC = "99-决策记录-ADR/ADR-902-车间直送.md";
    private static final AiDocKnowledge REAL = AiDocKnowledge.of(Map.of(
            SURPLUS_DOC, "# 采购允许超收\n\n## 二、决策\n\n采购到货登记时允许超收：超收比例默认 5%，比例以内照收入库；超出比例的部分由财务审核组"
                    + "批准后才入库，批准前这部分既不入库也不立应付。委外回厂超收也按这个比例判断，超出的部分同样交财务审核组处理。"
                    + "到货登记页会在数量旁边写明本次超收了多少、是否在比例以内，仓库照实登记即可，不需要先找采购改订货数量。\n",
            DIRECT_DOC, "# 车间直送\n\n## 二、决策\n\n车间直送是指上一道工序报工后，合格品直接送到下一道工序的车间内料仓，不经过仓库入库；"
                    + "直送资格由货品档案的来源决定，来源是自制的才能直送，改成委外的货品只能送仓库。报工时在去向里选直送，"
                    + "下一道工序在车间内料仓里就能看到这批合格品，不需要再做领料。\n"));
    private static final AiDocChunker.Chunk SURPLUS = chunk(SURPLUS_DOC);
    private static final AiDocChunker.Chunk DIRECT = chunk(DIRECT_DOC);

    private final ObjectMapper json = new ObjectMapper();
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final AiChatEvidence evidence = mock(AiChatEvidence.class);
    private final AiChatToolRegistry tools = mock(AiChatToolRegistry.class);
    private final AiChatPageGuideCatalog pages = mock(AiChatPageGuideCatalog.class);
    private final AiChatActionProposalService proposals = mock(AiChatActionProposalService.class);
    private final AiDocKnowledge docs = mock(AiDocKnowledge.class);
    private final AiJobHandler.AiJobContext ctx = mock(AiJobHandler.AiJobContext.class);
    private AuthUser actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "worker-zhang",
            Set.of("ai:use", "production_execution:view"), false, true, false);
    private AiChatJobHandler handler;

    private static AiDocChunker.Chunk chunk(String path) {
        return REAL.chunks().stream().filter(chunk -> chunk.path().equals(path)).findFirst().orElseThrow();
    }

    @BeforeEach void before() {
        handler = new AiChatJobHandler(access, evidence, tools, pages, proposals, docs, json, AiChatUserScopeTest.directory());
        when(access.requireChat()).thenAnswer(call -> actor);
        when(access.domains()).thenReturn(Set.of("SELF", "PRODUCTION"));
        when(ctx.params()).thenReturn(Map.of());
        when(ctx.aiAllowed()).thenReturn(true);
        when(ctx.jobId()).thenReturn(UUID.randomUUID());
        when(tools.available()).thenReturn(List.of());
        when(tools.available(anyString())).thenReturn(Optional.empty());
        when(pages.resolve(anyString(), any())).thenReturn(Optional.empty());
        when(proposals.refreshCards(any())).thenReturn(List.of());
        when(evidence.stampMatches(any())).thenReturn(true);
        when(evidence.conversation(any(), anyInt())).thenReturn(List.of());
        when(docs.search(anyString(), anyString(), anySet())).thenReturn(List.of());
        for (var chunk : List.of(SURPLUS, DIRECT)) when(docs.chunk(chunk.id())).thenReturn(Optional.of(chunk));
    }

    private void ask(Map<String, Object> request) throws Exception {
        var body = new LinkedHashMap<String, Object>(request);
        body.putIfAbsent("conversationId", CONVERSATION);
        byte[] bytes = json.writeValueAsBytes(Map.of("request", body, "access", Map.of("actor", "test")));
        when(ctx.input()).thenReturn(new AiJobHandler.AiJobInput("conversation.json", "application/json", "JSON", bytes.length,
                bytes, "hash"));
    }

    private void ask(String message) throws Exception {
        ask(Map.of("message", message));
    }

    private void model(String intent, String reply, List<String> sources) throws Exception {
        modelRaw(json.writeValueAsString(Map.of("focus", "", "intent", intent, "reply", reply, "usedSources", sources, "tool", "",
                "arguments", Map.of(), "action", Map.of("name", "", "args", Map.of()))));
    }

    private void modelRaw(String output) {
        when(ctx.completeJson(any())).thenReturn(new AiCompletionPort.AiCompletionResult(output, "provider", "model", 1, 1, 1));
    }

    private AiCompletionPort.AiCompletionRequest sent() {
        var captor = ArgumentCaptor.forClass(AiCompletionPort.AiCompletionRequest.class);
        verify(ctx, atLeastOnce()).completeJson(captor.capture());
        return captor.getValue();
    }

    private static String parts(AiCompletionPort.AiCompletionRequest request) {
        return request.userParts().stream().map(part -> part instanceof AiCompletionPort.AiText text ? text.text() : "")
                .reduce("", (a, b) -> a + "\n" + b);
    }

    /** An earlier knowledge turn about surplus receipts, answered from the surplus document. */
    private void earlierSurplusTurn() {
        var turn = new LinkedHashMap<String, Object>();
        turn.put("_access", Map.of("actor", "test"));
        turn.put("_domain", "SELF");
        turn.put("conversationId", CONVERSATION);
        turn.put("question", "采购超收比例是多少");
        turn.put("reply", "默认 5%。");
        turn.put("intent", "KNOWLEDGE");
        turn.put("replyShareable", true);
        turn.put("sources", List.of(Map.of("id", "knowledge." + SURPLUS.id(), "label", "平台说明: " + SURPLUS.label())));
        when(evidence.conversation(any(), anyInt())).thenReturn(List.of(
                new AiJobService.OwnedResult(UUID.randomUUID(), java.time.OffsetDateTime.now(), turn)));
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

    // ------------------------------------------------------------------ P0-3 topic switch and follow-up

    @Test void aNewShortQuestionIsSearchedOnItsOwnAndDoesNotCarryTheEarlierTopic() throws Exception {
        earlierSurplusTurn();
        when(docs.search(eq("车间直送是什么意思"), eq(""), anySet())).thenReturn(List.of(DIRECT));
        ask("车间直送是什么意思");
        model("KNOWLEDGE", "车间直送是上一道工序报工后，合格品直接送到下一道工序的车间内料仓，不经过仓库入库。",
                List.of("knowledge." + DIRECT.id()));
        var result = handler.process(ctx);
        String prompt = sent().systemPrompt();
        assertThat(prompt).contains("knowledge." + DIRECT.id()).doesNotContain("knowledge." + SURPLUS.id());
        verify(docs, never()).search(eq("车间直送是什么意思"), argThat(context -> !context.isEmpty()), anySet());
        assertThat(result).containsEntry("intent", "KNOWLEDGE").doesNotContainKey("fallback");
        assertThat(AiChatJobHandler.explicitFollowUp("车间直送是什么意思")).isFalse();
        assertThat(AiChatJobHandler.explicitFollowUp("怎么报工")).isFalse();
    }

    @Test void aRealFollowUpIsSearchedWithTheEarlierQuestionAndKeepsItsRules() throws Exception {
        earlierSurplusTurn();
        when(docs.search(eq("那委外呢？"), argThat(context -> context.contains("采购超收比例是多少")), anySet()))
                .thenReturn(List.of(SURPLUS));
        ask("那委外呢？");
        model("KNOWLEDGE", "委外回厂超收也按这个比例判断。", List.of("knowledge." + SURPLUS.id()));
        var result = handler.process(ctx);
        assertThat(sent().systemPrompt()).contains("knowledge." + SURPLUS.id());
        assertThat(result).containsEntry("intent", "KNOWLEDGE").doesNotContainKey("fallback");
        // The current question was searched on its own first.
        verify(docs).search(eq("那委外呢？"), eq(""), anySet());
    }

    @Test void onlyAFollowUpBringsTheEarlierQuestionsCatalogEntry() {
        var turn = new AiChatConversation.Turn("采购超收比例是多少", "默认 5%。", true, "", "", "", "KNOWLEDGE", "", Map.of(), Map.of(),
                List.of());
        var history = AiChatConversation.assemble(List.of(turn), 0);
        assertThat(AiChatJobHandler.relevantKnowledge(AiChatKnowledge.ALL, "车间直送是什么意思", history))
                .extracting(AiChatKnowledge.Entry::id).doesNotContain("PURCHASE_FLOW");
        assertThat(AiChatJobHandler.relevantKnowledge(AiChatKnowledge.ALL, "那委外呢？", history))
                .extracting(AiChatKnowledge.Entry::id).contains("PURCHASE_FLOW", "SUBCONTRACT_FLOW");
        // Eval #10: "报工" finds the production catalog entry.
        assertThat(AiChatJobHandler.relevantKnowledge(AiChatKnowledge.ALL, "怎么报工", AiChatConversation.History.NONE))
                .extracting(AiChatKnowledge.Entry::id).contains("PRODUCTION_FLOW");
    }

    // ------------------------------------------------------------------ P0-2 off topic

    @Test void aColloquialQuestionAnsweredFromItsCitedDocumentIsNotOffTopic() throws Exception {
        String question = "如果供应商送来的比我们订的多了能不能直接全部收下";
        String reply = "可以收。超收比例默认 5%，比例以内照收入库；超出比例的部分由财务审核组批准后才入库。";
        String source = SURPLUS.label() + "\n" + SURPLUS.text();
        assertThat(AiChatJobHandler.offTopic(question, reply, source, List.of(source))).isFalse();
        // End to end: the grounded answer is shown, not replaced by a pasted passage.
        when(docs.search(eq(question), eq(""), anySet())).thenReturn(List.of(SURPLUS));
        ask(question);
        model("KNOWLEDGE", reply, List.of("knowledge." + SURPLUS.id()));
        var result = handler.process(ctx);
        assertThat(result).containsEntry("reply", reply).doesNotContainKey("fallback");
    }

    /**
     * The four hand-written correct answers to colloquial questions that the old check (every two-character piece of the
     * question, overlap below 0.15) threw away, each citing the real design document it comes from.
     */
    @Test void theFourMeasuredColloquialAnswersAreKept() throws Exception {
        String[][] pairs = {
                {"东西到了以后仓库那边要怎么收进去", "到货后，仓库在「仓库到货登记页」登记实收数量和实称重量；实物先上架，品质检验合格后自动转为可用库存。",
                        "03-页面/仓库到货登记页.md"},
                {"客户那边说货少了几箱我们这边要怎么弄", "如果客户反馈少货，先在销售订单进度里核对已出货数量，再由销售登记客户退货或补发。",
                        "07-业务链路/06-销售退货质检冻结与处置.md"},
                {"车间那边做出来的东西比计划多了一些该怎么处理才对", "超出计划的部分叫超产，按公共超产入库，超产比例超过设定值需要申请。",
                        "03-页面/生产超产与追加处理说明.md"},
                {"如果供应商送来的比我们订的多了能不能直接全部收下", "可以在允许超收比例内直接收货；超出比例的部分要财务审批后才能入库。",
                        "99-决策记录-ADR/ADR-144-采购允许超收比例与超出部分财务审批.md"}};
        for (String[] pair : pairs) {
            String document = AiChatInternalContent.strip(java.nio.file.Files.readString(java.nio.file.Path.of("..", "docs", pair[2])));
            assertThat(AiChatJobHandler.offTopic(pair[0], pair[1], document, List.of(document))).as(pair[0]).isFalse();
        }
    }

    @Test void anAnswerAboutSomethingElseIsStillOffTopic() {
        String question = "采购到货超收比例默认是多少，超出部分谁来批准";
        String unrelated = "车间直送的合格品直接送到下一道工序。";
        String source = SURPLUS.label() + "\n" + SURPLUS.text();
        assertThat(AiChatJobHandler.offTopic(question, unrelated, source, List.of())).isTrue();
        assertThat(AiChatJobHandler.offTopic(question, unrelated, source, List.of(source))).isTrue();
    }

    // ------------------------------------------------------------------ P0-7 data words and tool eligibility

    @Test void theOrderStatusDirectoryAndAccessToolsRunOnTheQuestionsTheyAnswer() throws Exception {
        Map<String, String> asked = Map.of(
                "sales_order_progress", "XD20261006000003这个订单发货了没",
                AiChatDialogueSupport.FEATURE_DIRECTORY, "采购订货单在哪里",
                AiChatDialogueSupport.MY_ACCESS, "为什么我打不开财务报表");
        for (var entry : asked.entrySet()) {
            AiChatToolPort tool = tool(entry.getKey());
            when(tools.available()).thenReturn(List.of(tool));
            ask(entry.getValue());
            modelRaw(json.writeValueAsString(Map.of("intent", "TOOL", "tool", entry.getKey(), "arguments", Map.of("keyword", "x"))));
            assertThat(handler.process(ctx)).as(entry.getValue()).containsEntry("intent", "TOOL")
                    .containsEntry("reply", entry.getKey() + " 的结果");
            verify(tool).execute(Map.of("keyword", "x"));
        }
    }

    @Test void aToolIsNotRunForAQuestionItDoesNotAnswer() throws Exception {
        AiChatToolPort access = tool(AiChatDialogueSupport.MY_ACCESS);
        when(tools.available()).thenReturn(List.of(access));
        ask("报价单怎么转成订货单");
        modelRaw(json.writeValueAsString(Map.of("intent", "TOOL", "tool", AiChatDialogueSupport.MY_ACCESS,
                "arguments", Map.of("keyword", "报价单"))));
        var result = handler.process(ctx);
        verify(access, never()).execute(anyMap());
        assertThat(result).containsEntry("intent", "UNSUPPORTED");
        assertThat(result.get("reply").toString()).contains("没在平台说明里找到");
    }

    // ------------------------------------------------------------------ P0-8 honest "not found"

    @Test void anUngroundedWhereToClickReplyIsReplacedByAnHonestNotFound() throws Exception {
        ask("让料是什么意思");
        model("UNSUPPORTED", "进入生产物料分析页面，点击让料按钮即可。", List.of());
        var result = handler.process(ctx);
        String reply = result.get("reply").toString();
        assertThat(reply).contains("没在平台说明里找到关于「让料」", "没找到", "「让料在哪个页面办理？」")
                .doesNotContain("平台上没有", "点击", "入库时没填重量");
        assertThat(result).containsEntry("intent", "UNSUPPORTED").containsEntry("fallback", true);
        // An invented menu path is caught by the navigation guard whatever the intent.
        model("UNSUPPORTED", "在「仓库管理 > 让料登记」里新建一张单就行。", List.of());
        var invented = handler.process(ctx);
        assertThat(invented.get("reply").toString()).contains("没在平台说明里找到关于「让料」").doesNotContain("让料登记", "仓库管理");
        // A clarifying question that names pages the user can open is kept.
        model("CLARIFY", "你是想看「生产报工」的说明，还是「设置」？", List.of());
        assertThat(handler.process(ctx)).containsEntry("intent", "CLARIFY")
                .containsEntry("reply", "你是想看「生产报工」的说明，还是「设置」？");
    }

    @Test void aModelRefusalWithoutAnySourceIsAnHonestNotFoundNotAPermissionRefusal() throws Exception {
        ask("让料是什么意思");
        model("OUT_OF_SCOPE", "这个超出范围。", List.of());
        var result = handler.process(ctx);
        assertThat(result).containsEntry("intent", "UNSUPPORTED").containsEntry("_scope", "MODEL");
        assertThat(result.get("reply").toString()).contains("没在平台说明里找到", "我能帮你的是")
                .doesNotContain("超出了我能使用的资料", "你当前的权限");
        // The prompt keeps OUT_OF_SCOPE for the real scope categories only and never asks to "tell where to look".
        assertThat(sent().systemPrompt()).contains("OUT_OF_SCOPE only for the out-of-scope requests", "never just because no source")
                .doesNotContain("tell the user where to look");
    }

    @Test void aDataQuestionWithoutAToolSaysTheDataWasNotFoundNeverAPassage() throws Exception {
        ask("XD20261006000003这个订单发货了没");
        model("KNOWLEDGE", "已经发货了。", List.of());
        var result = handler.process(ctx);
        assertThat(result.get("reply").toString()).contains("这个要查业务数据").doesNotContain("《", "哪张单据");
        verify(docs, never()).search(anyString(), anyString(), anySet());
    }

    @Test void aBarelyRelatedPassageIsNotPastedAndHolesAreDropped() throws Exception {
        when(docs.search(eq("螺丝还有吗"), eq(""), anySet())).thenReturn(List.of(SURPLUS));
        ask("螺丝还有吗");
        model("KNOWLEDGE", "螺丝 LS-009 还有很多。", List.of("knowledge." + SURPLUS.id()));
        var result = handler.process(ctx);
        assertThat(result.get("reply").toString()).doesNotContain("《", "超收").contains("没在平台说明里找到");
        assertThat(AiChatJobHandler.withoutHoles("( 恒为 0，落不进任何链路大类)\n后端 新增 ( 的订货单， 门控\n"
                + "订货单审核通过后才进入排产，草稿不进入任何大类。")).isEqualTo("订货单审核通过后才进入排产，草稿不进入任何大类。");
    }

    @Test void aPastedInternalErrorGetsTheFixedHelpfulTextWithoutAModelCall() throws Exception {
        ask("页面报错 NullPointerException 怎么办");
        var result = handler.process(ctx);
        assertThat(result).containsEntry("intent", "UNSUPPORTED").containsEntry("_scope", "INTERNAL_ERROR");
        assertThat(result.get("reply").toString()).contains("截图", "管理员").doesNotContain("调试代码");
        verify(ctx, never()).completeJson(any());
    }

    // ------------------------------------------------------------------ P1-6 navigation guard, P1-9 user access

    @Test void aMenuPathIsShownOnlyWhenTheUserCanOpenItOrASourceNamesIt() throws Exception {
        String reply = "在「生产管理 > 生产报工」点新建，报工填本次实际产量。";
        ask("怎么报工");
        model("KNOWLEDGE", reply, List.of("knowledge.PRODUCTION_FLOW"));
        assertThat(handler.process(ctx)).containsEntry("reply", reply).doesNotContainKey("fallback");
        // Without the permission the page is not in the user's directory, and no source names it: the catalog answer.
        actor = new AuthUser(actor.getId(), actor.getEmployeeId(), "worker-zhang", Set.of("ai:use", "production_plan:view"),
                false, true, false);
        var withoutPage = handler.process(ctx);
        assertThat(withoutPage.get("reply").toString()).doesNotContain("生产管理 > 生产报工").contains("报工填本次实际产量");
        assertThat(withoutPage).containsEntry("fallback", true);
    }

    @Test void theSystemPromptStatesWhatTheUserCanOpenWithoutWhoTheyAre() throws Exception {
        ask("我能看哪些模块");
        model("CLARIFY", "你想查什么？", List.of());
        handler.process(ctx);
        String prompt = sent().systemPrompt();
        assertThat(prompt).contains("USER ACCESS", "modules the user can open: 生产管理、生产部、我的", "assistant domains: 个人事务、生产")
                .doesNotContain(actor.getId().toString(), actor.getEmployeeId().toString(), "worker-zhang");
    }

    // ------------------------------------------------------------------ P0-10 and P0-11 pages

    @Test void aPageOutsideTheUsersDepartmentsIsAnsweredWithoutReadingIt() throws Exception {
        when(pages.resolve("/subcontract/orders/new", null)).thenThrow(new ApiException(ErrorCode.FORBIDDEN, "这项暂时不能查看，请联系管理员。"));
        ask(Map.of("message", "怎么改密码", "pageContext", Map.of("route", "/subcontract/orders/new",
                "snapshot", Map.of("title", "委外订货单", "fields", List.of(Map.of("label", "委外商", "value", "PRIVATE_SUPPLIER"))))));
        model("UNSUPPORTED", "这个我没找到说明。", List.of());
        var result = handler.process(ctx);
        assertThat(result).doesNotContainKey("_route").doesNotContainKey("_page");
        assertThat(parts(sent())).doesNotContain("PAGE SNAPSHOT", "PRIVATE_SUPPLIER");
        // The submit endpoint drops the page the same way; an explicit page-help request is still refused.
        var request = new AiChatRequest("怎么改密码", null, new AiChatRequest.PageContext("/subcontract/orders/new", null));
        var forbidden = new ApiException(ErrorCode.FORBIDDEN, "这项暂时不能查看，请联系管理员。");
        assertThat(AiChatJobHandler.withoutUnreadablePage(request, forbidden).pageContext()).isNull();
        var hinted = new AiChatRequest("help", null, new AiChatRequest.PageContext("/subcontract/orders/new", null), "PAGE_HELP");
        assertThatThrownBy(() -> AiChatJobHandler.withoutUnreadablePage(hinted, forbidden)).isSameAs(forbidden);
        var invalid = new ApiException(ErrorCode.VALIDATION_FAILED, "x");
        assertThatThrownBy(() -> AiChatJobHandler.withoutUnreadablePage(request, invalid)).isSameAs(invalid);
    }

    @Test void onAPageRuleQuestionsSearchTheDocumentsAndPureQuestionsAboutThePageDoNot() {
        var snapshot = new AiChatPageSnapshot(1, "车间任务", List.of(), List.of(), List.of(), List.of(), List.of(), null, List.of());
        for (String question : List.of("超收比例是多少", "采购超收比例默认多少", "这个状态代表什么", "待料是啥", "退货的货还能再卖",
                "直送资格", "齐套率", "这里报错库存不足是什么意思")) {
            assertThat(AiChatJobHandler.searchesDocuments(new AiChatRequest(question, null, null), snapshot)).as(question).isTrue();
        }
        for (String question : List.of("不同状态是什么颜色", "红色的行", "这个页面的提示写了什么", "第3行是什么", "有哪些需要核对的",
                "把第3行数量改成100", "帮我筛选只看缺料的任务")) {
            assertThat(AiChatJobHandler.searchesDocuments(new AiChatRequest(question, null, null), snapshot)).as(question).isFalse();
        }
    }
}
