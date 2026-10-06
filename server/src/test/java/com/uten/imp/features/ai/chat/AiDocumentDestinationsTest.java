package com.uten.imp.features.ai.chat;

import com.uten.imp.features.ai.chat.AiDocumentIntent.Intent;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AiDocumentDestinationsTest {
    /** The same shape the client contract test parses (test/shared/ai/ai_document_destinations_contract_test.dart). */
    private static final Pattern LINE = Pattern.compile(
            "^\\s*new Destination\\(\"([a-z_]+)\", \"([^\"]+)\", \"([^\"]+)\", List\\.of\\((\"[a-z_:]+\"(?:, \"[a-z_:]+\")*)\\), \"([^\"]+)\"\\),$");
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final AiDocumentWorkflows workflows = new AiDocumentWorkflows(access);
    private final AiDocumentDestinations destinations = new AiDocumentDestinations(access, workflows);

    private void actor(boolean superAdmin, String... permissions) {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "staff", Set.of(permissions), false, true, superAdmin);
        when(access.requireChat()).thenReturn(actor);
        when(access.domains()).thenReturn(superAdmin ? Set.of("SELF", "SALES", "HR") : Set.of("SELF", "HR"));
    }

    @Test void catalogIsDeclaredOnePagePerLiteralLineWithFixedSafeRoutes() throws Exception {
        String source = Files.readString(Path.of("src/main/java/com/uten/imp/features/ai/chat/AiDocumentDestinations.java"), StandardCharsets.UTF_8);
        var parsed = source.lines().filter(line -> line.contains("new Destination(\"")).toList();
        assertThat(parsed).hasSize(AiDocumentDestinations.PAGES.size());
        Set<String> keys = new HashSet<>();
        for (String line : parsed) {
            var match = LINE.matcher(line);
            assertThat(match.matches()).as(line).isTrue();
            assertThat(keys.add(match.group(1))).as("unique key " + match.group(1)).isTrue();
            assertThat(match.group(3)).as("a plain local path without parameters").matches("/[a-z0-9/_-]+").doesNotContain("//", ":");
            assertThat(match.group(5)).as("a Chinese label, never a permission code").doesNotContain(":");
        }
        for (var page : AiDocumentDestinations.PAGES) assertThat(page.permissions()).isNotEmpty();
    }

    @Test void rosterReconcileForAViewerOffersOnlyTheEmployeePageAndExplainsEveryMissingPermission() {
        actor(false, "ai:use", "employee:view");
        var advice = destinations.advise("EMPLOYEE_ROSTER", Intent.RECONCILE, List.of());
        assertThat(advice.pages()).containsExactly(Map.of("key", "employee", "title", "员工档案", "route", "/employee"));
        assertThat(advice.blocked()).extracting(item -> item.get("title")).containsExactly("按花名册批量更正员工资料", "修改员工资料",
                "修改身份证号和手机号", "新增缺少的员工", "证件核对", "办理入职");
        assertThat(reason(advice, "修改员工资料")).isEqualTo("需要「员工档案编辑」权限，请联系管理员开通。");
        assertThat(reason(advice, "证件核对")).isEqualTo("需要「员工档案查看和证件修改」权限，请联系管理员开通。");
        assertThat(advice.blocked().toString()).doesNotContain("employee:", "pii");
        assertThat(String.join("\n", advice.lines())).contains("还不能按花名册自动批量更正", "可以去「员工档案」逐个核对", "另有 6 项");
    }

    @Test void fullHrPermissionsUnlockAllRosterPagesAndLeaveOnlyTheHonestLimit() {
        actor(false, "ai:use", "employee:view", "employee:edit", "employee:create", "employee:pii:edit", "department:view");
        var advice = destinations.advise("EMPLOYEE_ROSTER", Intent.RECONCILE, List.of());
        assertThat(advice.pages()).extracting(page -> page.get("route")).containsExactly("/employee", "/hr/tasks/identity", "/employee/onboarding");
        assertThat(advice.blocked()).extracting(item -> item.get("title")).containsExactly("按花名册批量更正员工资料");
    }

    @Test void superAdminPassesEveryPermissionAndAQuestionAddsNoChangeLimit() {
        actor(true);
        var advice = destinations.advise("EMPLOYEE_ROSTER", Intent.QUESTION, List.of());
        assertThat(advice.pages()).hasSize(3);
        assertThat(advice.blocked()).isEmpty();
        assertThat(advice.lines()).noneMatch(line -> line.contains("另有"));
    }

    @Test void withoutAnyPermissionNothingIsOfferedAndReasonsNamePermissionsInChinese() {
        actor(false, "ai:use");
        var advice = destinations.advise("BANK_STATEMENT", Intent.RECONCILE, List.of());
        assertThat(advice.pages()).isEmpty();
        assertThat(advice.blocked()).extracting(item -> item.get("title")).contains("按银行流水自动记账或对账", "账户流水", "收款单", "付款单");
        assertThat(reason(advice, "账户流水")).isEqualTo("需要「账户、余额和流水查看」权限，请联系管理员开通。");
    }

    @Test void goodsImportIsMentionedOnlyToWhoeverMayImport() {
        actor(false, "ai:use", "goods:view", "material_category:view", "goods:import");
        var allowed = destinations.advise("GOODS_LIST", Intent.IMPORT, List.of());
        assertThat(String.join("\n", allowed.lines())).contains("导入货品", "只新增货品");
        assertThat(allowed.blocked()).isEmpty();
        actor(false, "ai:use", "goods:view", "material_category:view");
        var denied = destinations.advise("GOODS_LIST", Intent.IMPORT, List.of());
        assertThat(String.join("\n", denied.lines())).doesNotContain(".xlsx");
        assertThat(reason(denied, "批量导入货品")).isEqualTo("需要「导入货品」权限，请联系管理员开通。");
    }

    @Test void formsTheReaderCannotUseAreBlockedForARecognizedFileButNeverListedForAnUnknownOne() {
        actor(false, "ai:use");
        var invoice = destinations.advise("INVOICE", Intent.NONE, List.of("EXPENSE_CLAIM"));
        assertThat(reason(invoice, "填写报销申请")).isEqualTo("需要「报销申请」权限，请联系管理员开通。");
        var unknown = destinations.advise("UNKNOWN", Intent.NONE, List.of("SALES_ORDER", "SALES_QUOTE", "EXPENSE_CLAIM"));
        assertThat(unknown.blocked()).isEmpty();
        actor(false, "ai:use", "sales_order:view", "sales_order:create");
        var quote = destinations.advise("SALES_QUOTATION", Intent.NONE, List.of("SALES_ORDER"));
        assertThat(reason(quote, "填写销售订货单")).as("permission held, but not in a sales department").contains("销售部门");
    }

    private static String reason(AiDocumentDestinations.Advice advice, String title) {
        return advice.blocked().stream().filter(item -> item.get("title").equals(title)).map(item -> item.get("reason")).findFirst().orElse(null);
    }
}
