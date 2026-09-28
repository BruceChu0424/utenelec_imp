package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** 公共 AI 平台的审计中文名称与分级(ADR-133): 服务商配置与系统设置同级, 记系统类高风险。 */
class AuditAiPlatformLabelsTest {

    private final AuditEventInterpreter interpreter = new AuditEventInterpreter();

    private AuditEventInterpreter.InterpretedEvent stored(AuditLog log) {
        AuditClassifier.Classification classification = AuditClassifier.classify(
                log.getEventSource(), log.getAction(), log.getTargetType(), log.getHttpPath(),
                log.getResult(), log.getStatusCode());
        log.setRiskLevel(classification.riskLevel());
        log.setEventCategory(classification.eventCategory());
        return interpreter.interpret(log);
    }

    private static AuditLog event(String action, String targetType, String path, String method, String result) {
        AuditLog log = new AuditLog();
        log.setAction(action);
        log.setTargetType(targetType);
        log.setTargetId(UUID.randomUUID().toString());
        log.setHttpPath(path);
        log.setHttpMethod(method);
        log.setEventSource("business");
        log.setResult(result);
        return log;
    }

    @Test
    void providerConfigurationChangesAreHighRiskSystemEventsWithPlainNames() {
        Map<String, String> expected = Map.of(
                "ai_provider.create", "新增 AI 服务",
                "ai_provider.update", "修改 AI 服务",
                "ai_provider.delete", "删除 AI 服务",
                "ai_provider.set_default", "设为默认 AI 服务",
                "ai_provider.set_enabled", "启用或停用 AI 服务",
                "ai_provider.test_stored", "用已保存密钥测试 AI 服务连接",
                "ai_provider.test_typed", "测试 AI 服务连接");
        expected.forEach((action, label) -> {
            AuditEventInterpreter.InterpretedEvent event = stored(event(action, "ai_providers",
                    "/api/admin/ai/providers", "POST", "success"));
            assertThat(event.actionLabel()).as(action).isEqualTo(label);
            assertThat(event.category()).as(action).isEqualTo("system");
            assertThat(event.riskLevel()).as(action).isEqualTo("high");
            assertThat(event.objectLabel()).as(action).isEqualTo("AI 服务配置");
        });
    }

    @Test
    void jobEventsAreOrdinaryBusinessEvents() {
        AuditEventInterpreter.InterpretedEvent submit = stored(event("ai_job.submit", null, "/api/ai/jobs",
                "POST", "success"));
        assertThat(submit.actionLabel()).isEqualTo("提交 AI 识别");
        assertThat(submit.objectLabel()).isEqualTo("AI 识别任务");
        assertThat(submit.category()).isEqualTo("business");
        assertThat(submit.riskLevel()).isEqualTo("low");

        AuditEventInterpreter.InterpretedEvent cancel = stored(event("ai_job.cancel", null,
                "/api/ai/jobs/3e27d660-5c36-41c8-8ea1-7f777f52a9cc/cancel", "POST", "success"));
        assertThat(cancel.actionLabel()).isEqualTo("取消 AI 识别");
    }

    @Test
    void newTablesHaveChineseNames() {
        Map<String, String> expected = Map.of(
                "ai_providers", "AI 服务配置",
                "ai_jobs", "AI 识别任务",
                "ai_call_logs", "AI 调用记录",
                "client_goods_aliases", "客户货品对照",
                "sales_intake_layouts", "客户文件版式",
                "sales_quote_revision_logs", "报价修订记录");
        expected.forEach((table, label) -> {
            AuditLog log = new AuditLog();
            log.setAction("update");
            log.setTargetType(table);
            log.setTargetId("target-id");
            log.setResult("success");
            log.setEventSource("database");
            assertThat(interpreter.interpret(log).objectLabel()).as(table).isEqualTo(label);
        });
    }
}
