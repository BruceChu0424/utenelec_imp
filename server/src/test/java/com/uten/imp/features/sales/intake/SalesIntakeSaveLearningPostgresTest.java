package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.text.IntakeTextNormalizer;
import com.uten.imp.features.ai.AiPlatformPostgresTestSupport;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 客户文件识别到保存学习的完整链路(ADR-133 + ADR-134, 真实 PostgreSQL + 完整过滤链 + 真实后台线程):
 * 业务员上传 CSV → 公共 AI 任务框架以提交人身份跑识别(没有配置 AI 服务, 走固定规则) → 用识别结果保存报价单
 * (POST /api/sales/quotes, 带 aiIntake) → 提交后两段学习按顺序都拿到了同一份识别结果: 识别模块先登记表格版式,
 * 主档学习再写对照、英文名称与客户资料, 最后才标记任务已采用并清空结果。
 *
 * <p>断言: 客户版式行、客户与全局对照行、货品英文名称、客户邮箱、任务去向与结果清空, 以及审计两行
 * ({@code sales_quote.create} 请求本身的语义事件 + {@code client.learn_from_document} 旁路事件, 同一请求编号)。
 * <b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>, 否则整类跳过。
 */
class SalesIntakeSaveLearningPostgresTest extends AiPlatformPostgresTestSupport {

    private static final String INTAKE_KIND = "SALES_DOCUMENT_INTAKE";

    @Test
    void savingAQuoteFromAnIntakeJobLearnsLayoutAliasesNameAndClientFieldsThenConsumesTheJob() throws Exception {
        String tag = UUID.randomUUID().toString().replace("-", "").substring(0, 8).toUpperCase(Locale.ROOT);
        // 没有 AI 服务: 识别只走固定规则(表格文件照常识别), 结果与假服务商无关、稳定可断言。
        jdbc.update("DELETE FROM ai_providers");
        grantSalesDepartment("sales_quote:view", "sales_quote:create", "sales_quote:edit", "client:view",
                "client:edit", "goods:view", "ai:use", "goods:name_en:edit");
        Staff seller = newEmployee(adminToken(), "DEPT_SALES");
        UUID userId = UUID.fromString(seller.userId());
        UUID employeeId = UUID.fromString(seller.employeeId());

        UUID clientId = UUID.randomUUID();
        jdbc.update("""
                insert into clients(id, code, name, status, code_sequence, owner_employee_id)
                values (?, ?, ?, '使用', (select coalesce(max(code_sequence), 0) + 1 from clients), ?)
                """, clientId, "SIL-" + tag, "识别学习客户" + tag, employeeId);
        UUID unitId = UUID.randomUUID();
        jdbc.update("insert into units(id, code, name, status) values (?, ?, '个', '使用')", unitId, "U-SIL-" + tag);
        String model = "GZ23/D" + tag;
        String description = "DOUBLE SOCKET WITH SWITCH " + tag;
        UUID goodsId = UUID.randomUUID();
        jdbc.update("""
                insert into goods(id, code, name, model, source_type, status, unit_id, price, code_sequence)
                values (?, ?, ?, ?, '自制', '使用', ?, 21, (select coalesce(max(code_sequence), 0) + 1 from goods))
                """, goodsId, "G-SIL-" + tag, "两开插座" + tag, model, unitId);
        String email = "buyer@" + tag.toLowerCase(Locale.ROOT) + ".example";

        // ① 上传客户文件, 等后台识别完成。
        String csv = "Buyer: SIL BUYER " + tag + " LTD\n"
                + "Email: " + email + "\n"
                + "Item No,Description,Qty,Unit Price,Amount\n"
                + model + "," + description + ",100,21,2100\n";
        MvcResult submitted = mvc.perform(post("/api/ai/jobs")
                        .param("kind", INTAKE_KIND)
                        .param("docType", "quote")
                        .param("clientId", clientId.toString())
                        .contentType(MediaType.APPLICATION_OCTET_STREAM)
                        .content(csv.getBytes(StandardCharsets.UTF_8))
                        .header("X-Uten-File-Name", URLEncoder.encode("客户报价 " + tag + ".csv", StandardCharsets.UTF_8)
                                .replace("+", "%20"))
                        .header("X-Uten-File-Type", "text/csv")
                        .header("Authorization", "Bearer " + seller.token()))
                .andReturn();
        assertEquals(202, submitted.getResponse().getStatus(), body(submitted));
        String jobId = json(submitted).path("jobId").asText();
        JsonNode done = awaitTerminal(seller.token(), jobId);
        assertThat(done.path("status").asText()).as(done.toString()).isEqualTo("SUCCEEDED");
        JsonNode result = done.path("result");
        assertThat(result.path("extraction").path("layoutSource").asText()).isEqualTo("RULES");
        String fingerprint = result.path("extraction").path("layoutFingerprint").asText();
        assertThat(fingerprint).isNotBlank();
        JsonNode line = result.path("lines").get(0);
        String lineKey = line.path("key").asText();
        assertThat(lineKey).startsWith("S");
        assertThat(line.path("partNo").asText()).isEqualTo(model);
        assertThat(line.path("description").asText()).isEqualTo(description);

        // ② 用识别结果保存报价单(整条 HTTP 链路, 审计拦截器照常记账)。
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("goodsId", goodsId.toString());
        item.put("unitId", unitId.toString());
        item.put("unitRate", 1);
        item.put("qty", 100);
        item.put("clientModel", model);
        item.put("clientGoodsName", description);
        item.put("clientPrice", 21);
        item.put("intakeLineKey", lineKey);
        item.put("userConfirmed", true);
        item.put("setNameEn", true);
        Map<String, Object> quote = new LinkedHashMap<>();
        quote.put("billDate", LocalDate.now().toString());
        quote.put("clientId", clientId.toString());
        quote.put("items", List.of(item));
        quote.put("aiIntake", Map.of("jobId", jobId, "clientFields", Map.of("email", email)));
        MvcResult saved = mvc.perform(json(post("/api/sales/quotes"), quote, seller.token())).andReturn();
        assertEquals(200, saved.getResponse().getStatus(), body(saved));
        UUID quoteId = UUID.fromString(json(saved).path("id").asText());

        // ③ 版式: 识别模块在主档学习清空结果之前读到了它(客户专属 + 全局各一行)。
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM sales_intake_layouts WHERE fingerprint = ? AND client_id = ?
                """, Long.class, fingerprint, clientId)).as("客户专属版式").isEqualTo(1L);
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM sales_intake_layouts WHERE fingerprint = ? AND client_id IS NULL
                """, Long.class, fingerprint)).as("全局版式").isEqualTo(1L);

        // ④ 对照: 客户型号与客户品名都记成该客户的对照(明确选择 1 次), 与识别原文一致的另记全局对照。
        List<Map<String, Object>> aliases = jdbc.queryForList("""
                SELECT client_id, alias_kind, alias_norm, confirm_count, explicit_count, last_source_doc_id
                FROM client_goods_aliases WHERE goods_id = ? ORDER BY alias_kind, client_id NULLS LAST
                """, goodsId);
        assertThat(aliases).filteredOn(a -> clientId.equals(a.get("client_id")))
                .extracting(a -> a.get("alias_kind"), a -> a.get("alias_norm"))
                .containsExactlyInAnyOrder(
                        org.assertj.core.groups.Tuple.tuple("DESCRIPTION",
                                IntakeTextNormalizer.normalizeDescription(description)),
                        org.assertj.core.groups.Tuple.tuple("PART_NO", IntakeTextNormalizer.normalizePart(model)));
        assertThat(aliases).filteredOn(a -> clientId.equals(a.get("client_id")))
                .allSatisfy(a -> {
                    assertThat(((Number) a.get("confirm_count")).intValue()).isEqualTo(1);
                    assertThat(((Number) a.get("explicit_count")).intValue()).isEqualTo(1);
                    assertThat(a.get("last_source_doc_id")).isEqualTo(quoteId);
                });
        assertThat(aliases).filteredOn(a -> a.get("client_id") == null)
                .extracting(a -> a.get("alias_kind")).containsExactlyInAnyOrder("DESCRIPTION", "PART_NO");

        // ⑤ 货品英文名称(勾了「设为货品英文名」且有权限) 与客户邮箱(勾选的客户资料)。
        assertThat(jdbc.queryForMap("SELECT name_en, name_en_source FROM goods WHERE id = ?", goodsId))
                .containsEntry("name_en", description).containsEntry("name_en_source", "LEARNED");
        assertThat(jdbc.queryForObject("SELECT email FROM clients WHERE id = ?", String.class, clientId))
                .isEqualTo(email);

        // ⑥ 任务: 记下被这张报价单采用, 结果已清空, 查询接口不再返回结果。
        Map<String, Object> job = jdbc.queryForMap("""
                SELECT used_doc_type, used_doc_id, result IS NULL AS purged, result_purged_at IS NOT NULL AS stamped
                FROM ai_jobs WHERE id = ?::uuid
                """, jobId);
        assertThat(job).containsEntry("used_doc_type", "quote").containsEntry("used_doc_id", quoteId)
                .containsEntry("purged", false).containsEntry("stamped", false);
        assertThat(getJson("/api/ai/jobs/" + jobId, seller.token()).path("result").isNull()).isTrue();

        // ⑦ 审计: 保存请求自己的语义事件与「从客户文件补全资料」旁路事件都在, 同一个请求编号。
        List<Map<String, Object>> audit = jdbc.queryForList("""
                SELECT action, target_type, target_id, request_id, result
                FROM audit_log
                WHERE actor_id = ? AND action IN ('sales_quote.create', 'client.learn_from_document')
                """, userId);
        assertThat(audit).extracting(row -> row.get("action"))
                .containsExactlyInAnyOrder("sales_quote.create", "client.learn_from_document");
        Map<String, Object> operation = row(audit, "sales_quote.create");
        Map<String, Object> learned = row(audit, "client.learn_from_document");
        assertThat(learned).containsEntry("target_type", "clients").containsEntry("target_id", clientId.toString());
        assertThat((String) learned.get("result")).contains("邮箱").doesNotContain(email);
        assertThat(learned.get("request_id")).isNotNull().isEqualTo(operation.get("request_id"));
    }

    /** 销售部门持有这些权限(已有则不变); 必须在拿管理员令牌之前做(授权会推进全局授权纪元)。 */
    private void grantSalesDepartment(String... codes) {
        for (String code : codes) {
            jdbc.update("""
                    INSERT INTO department_permissions (department_id, permission_id)
                    SELECT d.id, p.id FROM departments d, permissions p
                    WHERE d.code = 'DEPT_SALES' AND NOT d.is_deleted AND p.code = ?
                    ON CONFLICT DO NOTHING
                    """, code);
        }
    }

    private JsonNode awaitTerminal(String token, String jobId) throws Exception {
        long deadline = System.nanoTime() + Duration.ofSeconds(60).toNanos();
        JsonNode view = null;
        while (System.nanoTime() < deadline) {
            view = getJson("/api/ai/jobs/" + jobId, token);
            String status = view.path("status").asText();
            if (status.equals("SUCCEEDED") || status.equals("FAILED") || status.equals("CANCELLED")) {
                return view;
            }
            Thread.sleep(100);
        }
        throw new AssertionError("intake job " + jobId + " did not finish: " + view);
    }

    private static Map<String, Object> row(List<Map<String, Object>> rows, String action) {
        return rows.stream().filter(r -> action.equals(r.get("action"))).findFirst().orElseThrow();
    }
}
