package com.uten.imp.features.ai.usage;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

class AiUsageAuditPostgresTest extends AiPlatformPostgresTestSupport {
    @Test void retriesLocalHelpUnknownUsageAndCurrencyAreAccountedWithoutInventingCosts() throws Exception {
        Staff actor = aiUser(); UUID provider = provider();
        UUID paid = job(actor,1,"成本是多少？","SUCCEEDED"), local = job(actor,0,"怎么填写？","SUCCEEDED"),
                failed = job(actor,1,"失败的问题也保留","FAILED");
        call(actor,provider,paid,100,20,1,"USD","0.10",null,false);
        call(actor,provider,paid,200,40,1,"USD","0.20",null,true);
        call(actor,provider,failed,null,null,1,null,null,null,false);
        JsonNode result = read(actor,""); JsonNode summary = result.path("summary");
        assertThat(result.path("total").asLong()).isEqualTo(3);
        assertThat(summary.path("uses").asLong()).isEqualTo(3);
        assertThat(summary.path("calls").asLong()).isEqualTo(3);
        assertThat(summary.path("localUses").asLong()).isEqualTo(1);
        assertThat(summary.path("inputTokens").isNull()).isTrue();
        assertThat(summary.path("unknownTokenCalls").asLong()).isEqualTo(1);
        assertThat(summary.path("unknownCostCalls").asLong()).isEqualTo(1);
        assertCost(summary,"USD","ESTIMATED","0.3");
        JsonNode localRecord = record(result,local);
        assertThat(localRecord.path("calls").asInt()).isZero();
        assertThat(localRecord.path("inputTokens").asInt(-1)).isZero();
        assertThat(record(result,failed).path("question").asText()).isEqualTo("失败的问题也保留");
        assertThat(record(result,paid).path("calls").asInt()).isEqualTo(2);
        assertThat(record(result,paid).path("models").toString()).contains("test-model");
        assertThat(record(result,paid).path("providerNames").toString()).contains("Test AI");
        assertThat(result.toString()).doesNotContain("HIDDEN_RAW_RESULT", "HIDDEN_UPLOAD_BYTES");
    }

    @Test void actualChargeReplacesEstimateAndCurrenciesAreNotAddedTogether() throws Exception {
        Staff actor = aiUser(); UUID provider = provider(); UUID job = job(actor,2,"查工作台","SUCCEEDED");
        call(actor,provider,job,100,20,1,"USD","5","2",true);
        call(actor,provider,job,100,20,1,"CNY","8",null,true);
        JsonNode summary = read(actor,"").path("summary");
        assertThat(summary.path("costs").size()).isEqualTo(2);
        assertCost(summary,"USD","ACTUAL","2"); assertCost(summary,"CNY","ESTIMATED","8");
        assertThat(summary.path("unknownCostCalls").asInt()).isZero();
    }

    @Test void legacyZerosMissingCallLogsAndStandaloneProbesDoNotDisappear() throws Exception {
        Staff actor = aiUser(); UUID provider = provider();
        UUID legacy = job(actor,1,"旧任务","SUCCEEDED"), missing = job(actor,1,"没有调用明细","FAILED");
        call(actor,provider,legacy,0,0,0,null,null,null,true);
        call(actor,provider,null,0,0,1,"USD","0",null,true);
        JsonNode result = read(actor,"");
        assertThat(result.path("total").asInt()).isEqualTo(3);
        assertThat(result.path("summary").path("calls").asInt()).isEqualTo(2);
        assertThat(result.path("summary").path("localUses").asInt()).isZero();
        assertThat(result.path("summary").path("unknownTokenCalls").asInt()).isEqualTo(2);
        assertThat(record(result,missing).path("unknownCostCalls").asInt()).isEqualTo(1);
        assertThat(record(result,legacy).path("inputTokens").isNull()).isTrue();
        assertCost(result.path("summary"),"USD","ESTIMATED","0");
    }

    @Test void filtersPaginationAndProviderSelectionDoNotDuplicateJobsOrChargeLocalHelp() throws Exception {
        Staff actor = aiUser(), other = aiUser(); UUID a = provider(), b = provider();
        UUID first = job(actor,2,"同一任务两个服务","SUCCEEDED"), local = job(actor,0,"本地帮助","SUCCEEDED");
        call(actor,a,first,10,1,1,"USD","1",null,true); call(actor,b,first,20,2,1,"USD","2",null,true);
        call(other,a,job(other,1,"OTHER_PRIVATE_QUESTION","SUCCEEDED"),99,9,1,"USD","9",null,true);
        var filtered = read(actor,"&providerId="+a+"&size=1&page=0");
        assertThat(filtered.path("total").asInt()).isEqualTo(1);
        assertThat(filtered.path("summary").path("calls").asInt()).isEqualTo(1);
        assertCost(filtered.path("summary"),"USD","ESTIMATED","1");
        assertThat(filtered.toString()).doesNotContain("OTHER_PRIVATE_QUESTION", local.toString());
        var page0 = read(actor,"&size=1&page=0"); var page1 = read(actor,"&size=1&page=1");
        assertThat(page0.path("total").asInt()).isEqualTo(2);
        assertThat(page0.path("records").size()).isEqualTo(1);
        assertThat(page0.path("records").get(0).path("id").asText()).isNotEqualTo(page1.path("records").get(0).path("id").asText());
        assertThat(page0.path("summary")).isEqualTo(page1.path("summary"));
    }

    @Test void periodIncludesRecentChargesForAnOlderJobAndRetainedAuditDoesNotReadOldRawResults() throws Exception {
        Staff actor = aiUser(); UUID provider = provider(), old = job(actor,1,null,"SUCCEEDED");
        jdbc.update("UPDATE ai_jobs SET created_at=now()-interval '40 days',audit_question_state='UNAVAILABLE' WHERE id=?",old);
        call(actor,provider,old,4,5,1,"USD","0.9",null,true);
        JsonNode result = read(actor,"");
        assertThat(result.path("total").asInt()).isEqualTo(1);
        assertThat(record(result,old).path("question").isNull()).isTrue();
        assertThat(record(result,old).path("questionState").asText()).isEqualTo("UNAVAILABLE");
        assertThat(result.toString()).doesNotContain("HIDDEN_RAW_RESULT");
        jdbc.update("UPDATE ai_call_logs SET created_at=now()-interval '40 days' WHERE job_id=?",old);
        assertThat(read(actor,"").path("total").asInt()).isZero();
    }

    @Test void ordinaryEmployeesCannotReadCoworkerQuestionsAndInvalidRangesFailBeforeQuery() throws Exception {
        Staff actor = aiUser();
        String token = login(actor.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        var denied = mvc.perform(authed(get("/api/admin/ai/usage-audit"),token)).andReturn();
        assertEquals(403,denied.getResponse().getStatus(),body(denied));
        for (String params : new String[]{"days=0","days=367","page=-1","size=101"}) {
            var invalid = mvc.perform(authed(get("/api/admin/ai/usage-audit?"+params),adminToken())).andReturn();
            assertEquals(422,invalid.getResponse().getStatus(),body(invalid));
        }
    }

    private JsonNode read(Staff staff,String suffix) throws Exception {
        return getJson("/api/admin/ai/usage-audit?days=30&userId="+staff.userId()+suffix,adminToken());
    }
    private UUID provider() {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO ai_providers(id,name,preset,region,protocol,base_url,model) VALUES(?,?,'CUSTOM','LOCAL','OPENAI_CHAT','https://example.invalid','test-model')",id,"audit-"+id);
        return id;
    }
    private UUID job(Staff actor,int calls,String question,String status) {
        UUID id=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,
                  submitted_by_user,submitted_by_employee,submitted_auth_version,ai_calls,audit_question,audit_question_state,audit_intent,result,finished_at)
                VALUES(?,'ERP_CHAT',?,'conversation.json','application/json','JSON',0,?,?::uuid,?::uuid,0,?,?,'CAPTURED','KNOWLEDGE',
                  '{"reply":"HIDDEN_RAW_RESULT"}'::jsonb,now())
                """,id,status,"a".repeat(64),actor.userId(),actor.employeeId(),calls,question);
        return id;
    }
    private void call(Staff actor,UUID provider,UUID job,Integer input,Integer output,int capture,String currency,String estimated,String actual,boolean ok) {
        jdbc.update("""
                INSERT INTO ai_call_logs(purpose,provider_id,provider_name,model,protocol,ok,input_tokens,output_tokens,
                  latency_ms,job_id,user_id,employee_id,usage_capture_version,billing_currency,estimated_cost,actual_cost,actual_cost_source)
                VALUES('ERP_CHAT_ROUTE',?,'Test AI','test-model','OPENAI_CHAT',?,?,?,2,?,?::uuid,?::uuid,?,?,?,?,?)
                """,provider,ok,input,output,job,actor.userId(),actor.employeeId(),capture,currency,
                estimated==null?null:new BigDecimal(estimated),actual==null?null:new BigDecimal(actual),actual==null?null:"verified-test-charge");
    }
    private static JsonNode record(JsonNode root,UUID job) {
        for (JsonNode row : root.path("records")) if (row.path("jobId").asText().equals(job.toString())) return row;
        throw new AssertionError("Missing record " + job);
    }
    private static void assertCost(JsonNode value,String currency,String basis,String amount) {
        for (JsonNode row : value.path("costs")) if (row.path("currency").asText().equals(currency) && row.path("basis").asText().equals(basis)) {
            assertThat(new BigDecimal(row.path("amount").asText())).isEqualByComparingTo(amount); return;
        }
        throw new AssertionError("Missing cost " + currency + "/" + basis);
    }
}
