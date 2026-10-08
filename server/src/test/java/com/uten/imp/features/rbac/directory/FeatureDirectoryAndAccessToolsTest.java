package com.uten.imp.features.rbac.directory;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.rbac.directory.AiChatFeatureDirectory.Feature;
import com.uten.imp.features.rbac.directory.AiFeatureAccess.PermissionName;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;

import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * SPEC P1-1 / P1-4 with the real generated directory and real permission sets. Permission names are the catalog's
 * own (copied from the migrated permission table; {@code AiFeatureAccessPostgresTest} reads the real table).
 */
class FeatureDirectoryAndAccessToolsTest {
    private static final AiChatFeatureDirectory DIRECTORY = new AiChatFeatureDirectory(new ObjectMapper());
    private static final List<PermissionName> CATALOG = List.of(
            name("account:support", "查看、开通、锁定、启停及重置登录账号", "系统管理", "账号管理"),
            name("authorization:manage", "配置权限与系统安全策略", "系统管理", "授权管理"),
            name("customer_prepayment:view", "查看客户预收款", "财税管理", "客户预收"),
            name("department:view", "查看部门", "人事行政", "部门"),
            name("employee:create", "办理员工入职", "人事行政", "员工档案"),
            name("employee:pii:edit", "编辑员工证件、联系方式与银行字段", "人事行政", "员工档案"),
            name("employee:view", "查看员工档案", "人事行政", "员工档案"),
            name("expense:approve", "审批报销", "人事行政", "报销"),
            name("finance:view:all", "查看全部财务单据", "财税管理", "数据范围"),
            name("finance_report:view", "查看钱流报表", "财税管理", "钱流报表"),
            name("payroll:view:all", "查看全员工资条", "人事行政", "工资条"),
            name("payroll:view:self", "查看本人工资条", "常用模块", "工资条"),
            name("sales_order:approve", "审核销售订货单", "销售管理", "销售订货"),
            name("sales_order:create", "新增销售订货单", "销售管理", "销售订货"),
            name("sales_order:view", "查看销售订货", "销售管理", "销售订货"),
            name("stock:view", "查看库存余额、即时库存及出入库流水", "仓库管理", "库存"),
            name("stock_doc:view", "查看仓库单据", "仓库管理", "仓库单据"),
            name("stock_report:view", "查看仓库报表", "仓库管理", "仓库报表"));
    /** A route, a permission code or an internal path in a reply or in model facts is a leak. */
    private static final java.util.regex.Pattern LEAK =
            java.util.regex.Pattern.compile("/[a-z]|[a-z_]+:[a-z_]+|\\.dart|\\.md");

    private static PermissionName name(String code, String name, String module, String category) {
        return new PermissionName(code, name, module, category);
    }

    /** The real tools for one reader; names come from the fixed catalog instead of a database. */
    private record Tools(FeatureDirectoryAiChatTool directory, MyAccessAiChatTool access) {}

    private static Tools tools(Set<String> permissions, boolean superAdmin, Set<String> domains) {
        AiChatAccessPolicy policy = mock(AiChatAccessPolicy.class);
        AuthUser actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reader", permissions, false, true, superAdmin);
        when(policy.requireChat()).thenReturn(actor);
        when(policy.domains()).thenReturn(domains);
        Map<String, PermissionName> byCode = CATALOG.stream().collect(Collectors.toMap(PermissionName::code, Function.identity()));
        AiFeatureAccess access = new AiFeatureAccess(DIRECTORY, policy, null) {
            @Override Map<String, PermissionName> names(Collection<String> codes) {
                return codes.stream().filter(byCode::containsKey).collect(Collectors.toMap(Function.identity(), byCode::get));
            }

            @Override List<PermissionName> catalog() {
                return CATALOG;
            }
        };
        return new Tools(new FeatureDirectoryAiChatTool(access), new MyAccessAiChatTool(access));
    }

    private static Tools warehouseClerk() {
        return tools(Set.of("ai:use", "stock:view", "stock_doc:view", "payroll:view:self", "expense:apply", "notice:read"),
                false, Set.of("SELF", "WAREHOUSE"));
    }

    private static String reply(Map<String, Object> result) {
        return (String) result.get("reply");
    }

    private static Feature feature(String route) {
        return DIRECTORY.features().stream().filter(item -> item.route().equals(route)).findFirst().orElseThrow();
    }

    @Test
    void theGeneratedDirectoryIsLoadedWithGuardsAndMenuWords() {
        assertThat(DIRECTORY.features()).hasSizeGreaterThan(100);
        Feature inventory = feature("/stock/instant-inventory");
        assertThat(inventory.title()).isEqualTo("即时库存");
        assertThat(inventory.anyOf()).containsExactly("stock:view");
        assertThat(DIRECTORY.howToOpen(inventory)).isEqualTo("工作台 > PMC运营部 > 仓库管理 > 即时库存");
        assertThat(feature("/warehouse").hubOf()).contains("/stock/instant-inventory", "/warehouse/insights");
        for (Feature item : DIRECTORY.features()) {
            assertThat(item.title()).as(item.route()).isNotBlank();
            assertThat(LEAK.matcher(DIRECTORY.howToOpen(item)).find()).as(item.route()).isFalse();
        }
    }

    @Test
    void whereToSeeStockListsTheWarehousePagesTheClerkOpensAndNamesWhatTheReportNeeds() {
        Tools clerk = warehouseClerk();
        Map<String, Object> result = clerk.directory().execute(Map.of("keyword", "哪个页面可以看库存"));
        String reply = reply(result);
        assertThat(reply).contains("即时库存(仓库管理)", "进入：工作台 > PMC运营部 > 仓库管理 > 即时库存",
                "库存分析(仓库管理)：你暂时打不开，缺少「查看仓库报表」权限", "打不开的页面请联系管理员开通。");
        assertThat(reply.indexOf("即时库存(")).isLessThan(reply.indexOf("库存分析("));
        assertThat(reply).doesNotContain("钱流管理", "普通仓盘点审核");
        assertThat(LEAK.matcher(reply).find()).isFalse();
        assertThat(reply.lines().filter(line -> line.startsWith("• ")).count()).isBetween(2L, (long) FeatureDirectoryAiChatTool.MAX_PAGES);
        // Missing access is never sent to the model: the answer stays deterministic.
        assertThat(clerk.directory().modelFacts(result)).isEmpty();
    }

    @Test
    void openPagesMayBeComposedFromTitlesAndMenuWordsWithoutRoutes() {
        Map<String, Object> result = warehouseClerk().directory().execute(Map.of("keyword", "即时库存在哪"));
        Map<String, Object> facts = warehouseClerk().directory().modelFacts(result);
        assertThat(facts).containsKey("pages");
        String json = facts.toString();
        assertThat(json).contains("即时库存", "工作台 > PMC运营部 > 仓库管理 > 即时库存");
        assertThat(LEAK.matcher(json).find()).isFalse();
    }

    @Test
    void withoutKeywordTheReaderGetsTheModulesTheyCanOpen() {
        String reply = reply(warehouseClerk().directory().execute(Map.of()));
        assertThat(reply).startsWith("你现在能在工作台打开这些模块：").contains("仓库管理", "常用功能")
                .doesNotContain("钱流管理", "销售管理", "系统管理");
        String everything = reply(tools(Set.of("ai:use"), true, Set.of("SELF")).directory().execute(Map.of("keyword", "  ")));
        assertThat(everything).contains("钱流管理", "销售管理", "系统管理", "仓库管理");
    }

    @Test
    void aModuleHomeOpensWhenAnyOfItsCardsOpens() {
        Feature warehouse = feature("/warehouse");
        assertThat(DIRECTORY.opens(warehouse, Set.of("stock:view"), false)).isTrue();
        assertThat(DIRECTORY.opens(warehouse, Set.of("finance_report:view"), false)).isFalse();
        assertThat(DIRECTORY.opens(warehouse, Set.of(), true)).isTrue();
        // An all-of guard is part of the contract: the any-of code alone does not open the onboarding wizard.
        Feature onboarding = feature("/employee/onboarding");
        assertThat(DIRECTORY.opens(onboarding, Set.of("employee:create"), false)).isFalse();
        assertThat(DIRECTORY.opens(onboarding, Set.of("employee:create", "employee:pii:edit", "department:view"), false)).isTrue();
    }

    @Test
    void whyCanINotOpenTheFinanceReportNamesTheMissingPermission() {
        String reply = reply(warehouseClerk().access().execute(Map.of("target", "我为什么打不开财务报表")));
        assertThat(reply).contains("你暂时打不开，缺少「查看钱流报表」权限").endsWith("请联系管理员开通。");
        // The prepayment ledger also needs two more permissions, listed by name.
        String prepayment = reply(warehouseClerk().access().execute(Map.of("target", "客户预收流水")));
        assertThat(prepayment).contains("「客户预收流水」：你暂时打不开，缺少「查看客户预收款」、「查看全部财务单据」、「查看钱流报表」权限");
        assertThat(LEAK.matcher(reply + prepayment).find()).isFalse();
        assertThat(reply + prepayment).doesNotContain("管理员是", "超级管理员");
    }

    @Test
    void aPastedPlatformErrorIsAnsweredByPermissionName() {
        Tools seller = tools(Set.of("ai:use", "sales_order:view", "sales_order:create"), false, Set.of("SELF", "SALES"));
        String reply = reply(seller.access().execute(Map.of("target", "保存时报错：缺少操作权限：sales_order:approve")));
        assertThat(reply).isEqualTo("你还没有「审核销售订货单」权限(属于「销售管理 · 销售订货」)。\n请联系管理员开通。");
        String held = reply(seller.access().execute(Map.of("target", "缺少操作权限：sales_order:create、sales_order:view")));
        assertThat(held).contains("你已经有「新增销售订货单」权限。", "你已经有「查看销售订货」权限。", "请把完整的报错和所在页面告诉管理员")
                .doesNotContain("请联系管理员开通");
        String unknown = reply(seller.access().execute(Map.of("target", "缺少操作权限：made_up:thing")));
        assertThat(unknown).contains("在系统的权限目录里找不到").doesNotContain("made_up");
    }

    @Test
    void personnelPermissionNamesStayHiddenFromReadersOutsideThePersonnelDomain() {
        Tools clerk = warehouseClerk();
        String pages = reply(clerk.access().execute(Map.of("target", "员工档案打不开")));
        assertThat(pages).contains("「员工档案」", "需要管理员开通相关权限").doesNotContain("查看员工档案", "办理员工入职", "人事相关的操作");
        String pasted = reply(clerk.access().execute(Map.of("target", "缺少操作权限：employee:view")));
        assertThat(pasted).contains("人事相关的权限", "需要管理员开通相关权限").doesNotContain("查看员工档案").endsWith("请联系管理员开通。");
        // An HR clerk reads the names of what the onboarding wizard still needs.
        Tools hr = tools(Set.of("ai:use", "employee:view", "employee:create"), false, Set.of("SELF", "HR"));
        String wizard = reply(hr.access().execute(Map.of("target", "入职向导")));
        assertThat(wizard).contains("「入职向导」：你暂时打不开，缺少「查看部门」、「编辑员工证件、联系方式与银行字段」权限");
    }

    @Test
    void systemPagesAndSuperAdminsAreAnsweredWithoutNamingAdministrators() {
        String clerk = reply(warehouseClerk().access().execute(Map.of("target", "权限管理")));
        assertThat(clerk).contains("「权限管理」：你暂时打不开，这是系统管理页面，需要管理员开通相关权限")
                .doesNotContain("配置权限与系统安全策略");
        String admin = reply(tools(Set.of("ai:use"), true, Set.of("SELF", "ADMIN")).access().execute(Map.of("target", "权限管理")));
        assertThat(admin).contains("「权限管理」：你可以打开。进入：工作台 > 系统管理 > 权限管理").doesNotContain("请联系管理员开通");
        // Live 2026-10-06 (AC1, X03): a reader who can open it was asked because it would not open; say what to try next.
        assertThat(admin).endsWith(MyAccessAiChatTool.STILL_BLOCKED);
        assertThat(clerk).doesNotContain(MyAccessAiChatTool.STILL_BLOCKED);
        Tools finance = tools(Set.of("ai:use", "expense:approve"), false, Set.of("SELF", "FINANCE"));
        assertThat(reply(finance.access().execute(Map.of("target", "审批报销")))).endsWith(MyAccessAiChatTool.STILL_BLOCKED);
    }

    @Test
    void operationsAreMatchedByTheirCatalogName() {
        Tools finance = tools(Set.of("ai:use", "expense:approve"), false, Set.of("SELF", "FINANCE"));
        assertThat(reply(finance.access().execute(Map.of("target", "审批报销")))).contains("「审批报销」：你已经有这项权限。");
        Tools clerk = warehouseClerk();
        assertThat(reply(clerk.access().execute(Map.of("target", "审批报销"))))
                .contains("「审批报销」：你还没有这项权限。").endsWith("请联系管理员开通。");
        assertThat(reply(clerk.access().execute(Map.of("target", "火星基地"))))
                .startsWith("没找到和你说的页面或操作对应的权限");
    }

    @Test
    void argumentsAreBoundedAndTheToolsAreOfferedToEveryChatUser() {
        Tools clerk = warehouseClerk();
        assertThatThrownBy(() -> clerk.directory().execute(Map.of("keyword", "库存", "route", "/admin")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> clerk.directory().execute(Map.of("keyword", "库".repeat(51)))).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> clerk.access().execute(Map.of())).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> clerk.access().execute(Map.of("target", " "))).isInstanceOf(ApiException.class);
        assertThat(clerk.directory().name()).isEqualTo("feature_directory");
        assertThat(clerk.access().name()).isEqualTo("my_access");
        assertThat(clerk.directory().domain()).isEqualTo("SELF");
        assertThat(clerk.access().domain()).isEqualTo("SELF");
        assertThat(clerk.directory().available()).isTrue();
        assertThat(clerk.access().modelFacts(clerk.access().execute(Map.of("target", "即时库存")))).isEmpty();
        assertThat(clerk.directory().parameters().toString()).contains("additionalProperties=false");
    }

    @Test
    void searchMatchesNamesBeforeModulesAndPurposes() {
        assertThat(AiChatFeatureDirectory.terms("库存 在哪里看？")).containsExactly("库存");
        assertThat(AiChatFeatureDirectory.terms("哪个页面可以看库存")).containsExactly("库存");
        assertThat(AiChatFeatureDirectory.terms("我的盘点在哪")).containsExactly("盘点");
        List<Feature> orders = DIRECTORY.search("销售订单");
        assertThat(orders).isNotEmpty();
        assertThat(orders.getFirst().module()).isEqualTo("销售管理");
        assertThat(DIRECTORY.search("往来对账单").getFirst().route()).isEqualTo("/finance/report/statement");
        assertThat(DIRECTORY.search("的")).isEmpty();
    }

    @Test
    void wholeQuestionsStillFindThePages() {
        assertThat(DIRECTORY.search("客户对账单在哪里看").stream().map(Feature::route))
                .contains("/finance/report/recon", "/finance/report/statement");
        assertThat(DIRECTORY.search("销售订单做到哪一步了在哪里看进度").stream().map(Feature::route)).contains("/sales/progress");
        assertThat(AiChatFeatureDirectory.terms("系统里有哪些模块")).isEmpty();
        assertThat(reply(warehouseClerk().directory().execute(Map.of("keyword", "系统里有哪些模块"))))
                .startsWith("你现在能在工作台打开这些模块：");
        // Two characters name an area: the pages answer, not every operation that mentions it.
        String purchase = reply(warehouseClerk().access().execute(Map.of("target", "我打不开采购页面 是没权限吗 找谁开")));
        assertThat(purchase).contains("「采购管理」：你暂时打不开，这个模块里的页面你都还没有开通。").endsWith("请联系管理员开通。")
                .doesNotContain("这项权限");
    }
}
