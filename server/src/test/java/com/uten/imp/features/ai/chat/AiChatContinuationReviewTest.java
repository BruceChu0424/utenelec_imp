package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiJobHandler;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.job.AiJobView;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AiChatContinuationReviewTest {
    final ObjectMapper json = new ObjectMapper();
    final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    final AiChatEvidence evidence = mock(AiChatEvidence.class);
    final AiChatToolRegistry tools = mock(AiChatToolRegistry.class);
    final AiChatPageGuideCatalog pages = mock(AiChatPageGuideCatalog.class);
    final AiChatToolPort cost = mock(AiChatToolPort.class);
    final AiChatJobHandler handler = new AiChatJobHandler(access,evidence,tools,pages,json);
    @BeforeEach void setup() {
        when(access.requireChat()).thenReturn(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"reader",
                Set.of("ai:use","goods:view","goods:cost:view","client:view","client:create"),false,true,false));
        when(access.domains()).thenReturn(Set.of("SELF","FINANCE","SALES"));
        when(cost.name()).thenReturn("query_goods_cost"); when(cost.title()).thenReturn("查询货品成本");
        when(cost.domain()).thenReturn("FINANCE"); when(cost.description()).thenReturn("Read scoped goods costs");
        when(cost.rememberQueryArguments()).thenReturn(true);
        when(cost.parameters()).thenReturn(Map.of("type","object","additionalProperties",false,
                "properties",Map.of("goodsKeyword",Map.of("type","string","minLength",1,"maxLength",100),
                        "basis",Map.of("type","string","enum",List.of("ACTUAL","ESTIMATE","BOTH"))),
                "required",List.of("goodsKeyword")));
        when(tools.available()).thenReturn(List.of(cost));
        when(tools.available(anyString())).thenReturn(Optional.empty());
        when(tools.available("query_goods_cost")).thenReturn(Optional.of(cost));
        when(cost.execute(anyMap())).thenReturn(Map.of("reply","PRIVATE_VALUE_91234","_toolEvidence",Map.of("secretObject","PRIVATE_OBJECT")));
    }
    AiJobHandler.AiJobContext context(String message, UUID previous, String output, boolean ai) throws Exception {
        var ctx=mock(AiJobHandler.AiJobContext.class);
        var request=new java.util.LinkedHashMap<String,Object>(); request.put("message",message);
        if(previous!=null) request.put("previousJobId",previous.toString());
        byte[] bytes=json.writeValueAsBytes(Map.of("request",request,"access",Map.of("actor","fixture")));
        when(ctx.input()).thenReturn(new AiJobHandler.AiJobInput("request.json","application/json","JSON",bytes.length,bytes,"hash"));
        when(ctx.params()).thenReturn(Map.of()); when(ctx.aiAllowed()).thenReturn(ai); when(ctx.jobId()).thenReturn(UUID.randomUUID());
        when(ctx.completeJson(any())).thenReturn(new AiCompletionPort.AiCompletionResult(output,"fixture","fixture",1,1,1));
        return ctx;
    }
    UUID prior(Map<String,Object> result) {
        UUID id=UUID.randomUUID();
        Map<String,Object> filtered=handler.filterResultForReader(result);
        when(evidence.previous(id)).thenReturn(new AiJobView(id,id,"ERP_CHAT","SUCCEEDED","DONE",100,false,
                filtered,null,null,"request.json",null,null,null));
        return id;
    }
    String selected(String args) { return "{\"intent\":\"TOOL\",\"tool\":\"query_goods_cost\",\"arguments\":"+args+"}"; }
    @Test void readFilterSurvivesPoliteTurnButFactsNeverEnterRoutingPrompt() throws Exception {
        var first=handler.process(context("查询 A001 成本",null,selected("{\"goodsKeyword\":\"A001\",\"basis\":\"ACTUAL\"}"),true));
        UUID firstId=prior(first);
        var thanks=handler.process(context("谢谢",firstId,"{}",true));
        assertThat(thanks).containsKey("_query").doesNotContainKey("_toolEvidence");
        UUID thanksId=prior(thanks);
        var followup=context("再查这个产品的测算成本",thanksId,selected("{\"goodsKeyword\":\"A001\",\"basis\":\"ESTIMATE\"}"),true);
        handler.process(followup);
        var sent=ArgumentCaptor.forClass(AiCompletionPort.AiCompletionRequest.class);
        verify(followup).completeJson(sent.capture());
        assertThat(sent.getValue().systemPrompt()).contains(BusinessTime.today().toString(),"Asia/Shanghai");
        assertThat(sent.getValue().userParts().toString()).contains("A001","ACTUAL").doesNotContain("PRIVATE_VALUE","PRIVATE_OBJECT");
        assertThat(sent.getValue().userParts().stream().filter(part->part.toString().contains("A001")))
                .allMatch(part->part instanceof AiCompletionPort.AiText value && value.untrusted());
    }
    @Test void previewsCannotOptIntoContinuationWithoutExplicitReadContract() throws Exception {
        when(cost.rememberQueryArguments()).thenReturn(false);
        var result=handler.process(context("查询A001",null,selected("{\"goodsKeyword\":\"A001\"}"),true));
        assertThat(result).doesNotContainKey("_query");
    }
    @Test void unavailableReadToolIsNotCarriedByAStoredSocialReply() {
        when(tools.available("query_goods_cost")).thenReturn(Optional.empty());
        var result=handler.filterResultForReader(Map.of("_access",Map.of(),"_domain","SELF","reply","不客气",
                "_query",Map.of("tool","query_goods_cost","arguments",Map.of("goodsKeyword","A001"))));
        assertThat(result).doesNotContainKey("queryContext");
    }
    @Test void missingRequiredFilterProducesAQuestionWithoutExecutingAnything() throws Exception {
        var result=handler.process(context("查实际成本",null,selected("{\"basis\":\"ACTUAL\"}"),true));
        assertThat(result).containsEntry("intent","CLARIFY");
        assertThat(result.get("reply").toString()).contains("货品名称或编号");
        verify(cost,never()).execute(any());
    }
    @Test void missingFilterCannotHideForgedAuthorityArguments() throws Exception {
        var ctx=context("查成本",null,selected("{\"superAdmin\":true}"),true);
        assertThatThrownBy(()->handler.process(ctx)).isInstanceOf(ApiException.class);
        verify(cost,never()).execute(any());
    }
    @Test void noProviderDoesNotAnswerLiveCostQuestionWithStaticCostExplanation() throws Exception {
        var ctx=context("A001 现在实际成本多少",null,"{}",false);
        var result=handler.process(ctx);
        assertThat(result).containsEntry("intent","AI_UNAVAILABLE");
        assertThat(result.get("reply").toString()).contains("暂时查不了").doesNotContain("PRIVATE_VALUE");
        verify(ctx,never()).completeJson(any()); verify(cost,never()).execute(any());
    }
    @Test void noProviderStillExplainsAuthorizedWorkflow() throws Exception {
        assertThat(handler.process(context("成本口径怎么理解",null,"{}",false))).containsEntry("intent","KNOWLEDGE");
    }
    @Test void invalidBusinessPeriodAsksForCorrectionButForbiddenNeverBecomesASuccess() throws Exception {
        when(cost.execute(any())).thenThrow(new ApiException(ErrorCode.VALIDATION_FAILED,"请成对填写查询日期"));
        assertThat(handler.process(context("A001成本",null,selected("{\"goodsKeyword\":\"A001\"}"),true)))
                .containsEntry("intent","CLARIFY").containsEntry("reply","请成对填写查询日期");
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(cost).execute(any());
        var ctx=context("A001成本",null,selected("{\"goodsKeyword\":\"A001\"}"),true);
        assertThatThrownBy(()->handler.process(ctx)).isInstanceOf(ApiException.class);
    }
    @Test void authorizedClientCreationGuideIncludesActualRequiredFieldsAndManualSave() throws Exception {
        var result=handler.process(context("如何新增客户",null,"{\"intent\":\"KNOWLEDGE\",\"knowledgeId\":\"CLIENT_CREATE_GUIDE\"}",true));
        assertThat(result.get("reply").toString()).contains("分类","名称与状态","编号由系统","由你点击保存","示例客户 A");
        verify(cost,never()).execute(any());
    }
    @Test void detailIsShownOnlyOnRequestAndUsesTheSameAuthorizedReadFilters() throws Exception {
        when(cost.execute(any())).thenReturn(Map.of("reply","已知成本 3 元/个。",
                "detailReply","材料 2 元，加工 1 元；运费尚未核齐。"));
        var first=handler.process(context("A001成本多少",null,selected("{\"goodsKeyword\":\"A001\"}"),true));
        assertThat(first).containsEntry("reply","已知成本 3 元/个。");
        UUID id=prior(first);
        var expanded=context("展开",id,"{}",false);
        assertThat(handler.process(expanded)).containsEntry("reply","材料 2 元，加工 1 元；运费尚未核齐。");
        verify(expanded,never()).completeJson(any());
        verify(cost,times(2)).execute(Map.of("goodsKeyword","A001"));
        var shortAgain=context("简单说 A001 的所有成本",null,selected("{\"goodsKeyword\":\"A001\"}"),true);
        assertThat(handler.process(shortAgain)).containsEntry("reply","已知成本 3 元/个。");
    }
    @Test void expandingCannotRecoverARevokedToolsFacts() throws Exception {
        var first=handler.process(context("A001成本",null,selected("{\"goodsKeyword\":\"A001\"}"),true));
        UUID id=prior(first);
        clearInvocations(cost);
        when(tools.available("query_goods_cost")).thenReturn(Optional.empty());
        var expanded=context("展开",id,"{}",false);
        assertThat(handler.process(expanded).get("reply").toString()).doesNotContain("PRIVATE_VALUE");
        verify(cost,never()).execute(any());
    }
}
