package com.uten.imp.features.ai.chat;

import com.uten.imp.features.ai.chat.AiDocumentIntent.Intent;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * What the assistant can honestly say about a recognized file: which fixed pages handle it, what it cannot
 * do, and what the current account lacks. Everything is filtered by the reader's current permissions; a page
 * is offered only when the account holds ALL of its permissions, so the client route guard never blocks it.
 * Routes are fixed literals here, never taken from a model or a file.
 */
@Component
public class AiDocumentDestinations {
    /** A fixed page. Declared ONE per line in exactly this shape: the client contract test parses these lines. */
    record Destination(String key, String title, String route, List<String> permissions, String permissionLabel) {}

    private static final Destination[] CATALOG = {
        new Destination("employee", "员工档案", "/employee", List.of("employee:view"), "员工档案查看"),
        new Destination("hr_identity", "证件核对", "/hr/tasks/identity", List.of("employee:view", "employee:pii:edit"), "员工档案查看和证件修改"),
        new Destination("employee_onboarding", "办理入职", "/employee/onboarding", List.of("employee:create", "employee:pii:edit", "department:view"), "办理员工入职、证件修改和部门查看"),
        new Destination("payroll_generate", "工资条生成", "/payroll/generate", List.of("payroll:generate"), "生成工资条"),
        new Destination("payroll_slips", "工资条", "/payroll/slip", List.of("payroll:view:all"), "查看全员工资条"),
        new Destination("goods", "货品资料", "/basicinfo/goods", List.of("goods:view", "material_category:view"), "货品资料和物料分类查看"),
        new Destination("client", "客户资料", "/basicinfo/client", List.of("client:view", "client_category:view"), "客户资料和客户分类查看"),
        new Destination("supplier", "供应商资料", "/basicinfo/supplier", List.of("supplier:view", "supplier_category:view"), "供应商资料和供应商分类查看"),
        new Destination("instant_inventory", "即时库存", "/stock/instant-inventory", List.of("stock:view"), "库存查看"),
        new Destination("stock_count_requests", "我的盘点", "/stock/count-requests", List.of("stock:count:submit"), "录入盘点并提交审核"),
        new Destination("warehouse_tasks", "仓库任务中心", "/warehouse/tasks", List.of("stock_doc:view"), "仓库单据查看"),
        new Destination("purchase_orders", "采购订货单", "/purchase/orders", List.of("purchase_order:view"), "采购订货单查看"),
        new Destination("production_plans", "生产计划单", "/production/plans", List.of("production_plan:view"), "生产计划查看"),
        new Destination("production_daily_reports", "生产报工", "/production/daily-reports", List.of("production_daily_report:view"), "生产日报查看"),
        new Destination("production_where_used", "物料反查", "/production/where-used", List.of("production_where_used:view"), "物料反查"),
        new Destination("account_flow", "账户流水", "/finance/reconciliations", List.of("account:view", "account:balance:view", "account:flow:view"), "账户、余额和流水查看"),
        new Destination("finance_receipts", "收款单", "/finance/receipts", List.of("finance_receipt:view"), "收款单查看"),
        new Destination("finance_payments", "付款单", "/finance/payments", List.of("finance_payment:view"), "付款单查看"),
    };
    static final List<Destination> PAGES = List.of(CATALOG);

    /** A page that handles a document type, with what to do there. */
    private record Use(String page, String hint) {}
    /** A follow-up that needs a permission; missing it is listed as blocked, holding it may unlock a line. */
    private record Step(Set<Intent> intents, String title, List<String> permissions, String label, String grantedLine) {}
    /** Something the assistant or the system honestly cannot do for this type. */
    private record Limit(Set<Intent> intents, String title, String reason) {}
    record Advice(List<Map<String, String>> pages, List<Map<String, String>> blocked, List<String> lines) {}

    private static final Set<Intent> CHANGE = Set.of(Intent.RECONCILE, Intent.IMPORT);
    private static final Map<String, List<Use>> USES = Map.ofEntries(
            Map.entry("EMPLOYEE_ROSTER", List.of(new Use("employee", "逐个核对、修改员工资料"),
                    new Use("hr_identity", "处理身份证号有问题的员工"), new Use("employee_onboarding", "新增缺少的员工"))),
            Map.entry("PAYROLL", List.of(new Use("payroll_generate", "按月生成工资条"), new Use("payroll_slips", "查看已生成的工资条"))),
            Map.entry("ATTENDANCE", List.of(new Use("employee", "查看员工资料"))),
            Map.entry("HR_DOCUMENT", List.of(new Use("employee", "查看和修改员工资料"), new Use("employee_onboarding", "办理新员工入职"))),
            Map.entry("GOODS_LIST", List.of(new Use("goods", "查看、新增或修改货品"))),
            Map.entry("BOM_LIST", List.of(new Use("goods", "打开产品，在「组件」里查看或修改组装明细"),
                    new Use("production_where_used", "查某个物料用在哪些产品上"))),
            Map.entry("CUSTOMER_LIST", List.of(new Use("client", "查看、新增或修改客户"))),
            Map.entry("SUPPLIER_LIST", List.of(new Use("supplier", "查看、新增或修改供应商"))),
            Map.entry("STOCK_LIST", List.of(new Use("instant_inventory", "查看库存，有盘点权限时可进入盘点模式录入实盘数量"),
                    new Use("stock_count_requests", "查看已提交的盘点申请"))),
            Map.entry("WAREHOUSE_DOCUMENT", List.of(new Use("warehouse_tasks", "办理入库、出库等仓库任务"), new Use("instant_inventory", "查看库存"))),
            Map.entry("PRODUCTION_DOCUMENT", List.of(new Use("production_plans", "查看生产计划单"), new Use("production_daily_reports", "查看和填写生产报工"))),
            Map.entry("PURCHASE_DOCUMENT", List.of(new Use("purchase_orders", "查看和新建采购订货单"))),
            Map.entry("BANK_STATEMENT", List.of(new Use("account_flow", "核对账户流水和余额"), new Use("finance_receipts", "登记收款"),
                    new Use("finance_payments", "登记付款"))));
    private static final Map<String, String> CAN = Map.ofEntries(
            Map.entry("EMPLOYEE_ROSTER", "助手暂时还不能按花名册自动批量更正或补录员工资料，这次没有改动任何数据。"),
            Map.entry("PAYROLL", "工资由系统在「工资条生成」里按员工档案计算，助手不能导入或修改这份工资表。"),
            Map.entry("ATTENDANCE", "系统暂时没有考勤功能，这份考勤表不能导入，助手也不能据此修改工资。"),
            Map.entry("HR_DOCUMENT", "助手不能根据这份人事资料自动修改员工档案或办理入职、离职。"),
            Map.entry("GOODS_LIST", "助手不能按文件自动新增或修改货品资料。"),
            Map.entry("BOM_LIST", "助手不能按文件自动修改产品组装明细(BOM)。"),
            Map.entry("CUSTOMER_LIST", "客户资料暂时没有批量导入功能，助手也不能按文件自动新增或修改客户。"),
            Map.entry("SUPPLIER_LIST", "供应商资料暂时没有批量导入功能，助手也不能按文件自动新增或修改供应商。"),
            Map.entry("STOCK_LIST", "库存不能按文件直接修改：要在「即时库存」的盘点模式里录入实盘数量并送审，审核通过后才生效。"),
            Map.entry("WAREHOUSE_DOCUMENT", "助手不能按文件自动生成入库、出库等仓库单据。"),
            Map.entry("PRODUCTION_DOCUMENT", "助手不能按文件自动生成生产计划或报工。"),
            Map.entry("PURCHASE_DOCUMENT", "助手不能按文件自动生成采购订货单。"),
            Map.entry("CONTRACT", "系统暂时不管理合同文件，助手只能看出它是合同。"),
            Map.entry("BANK_STATEMENT", "助手不能按银行流水自动记账或对账，收款和付款要逐笔登记。"),
            Map.entry("UNKNOWN", "可以告诉我这份文件是做什么用的，或者直接打开对应的业务页面处理。"));
    private static final Map<String, List<Step>> STEPS = Map.ofEntries(
            Map.entry("EMPLOYEE_ROSTER", List.of(
                    new Step(Set.of(Intent.RECONCILE), "修改员工资料", List.of("employee:edit"), "员工档案编辑", null),
                    new Step(Set.of(Intent.RECONCILE), "修改身份证号和手机号", List.of("employee:pii:edit"), "员工证件与联系方式修改", null),
                    new Step(CHANGE, "新增缺少的员工", List.of("employee:create"), "办理员工入职", null))),
            Map.entry("HR_DOCUMENT", List.of(
                    new Step(CHANGE, "修改员工资料", List.of("employee:edit"), "员工档案编辑", null),
                    new Step(CHANGE, "办理新员工入职", List.of("employee:create"), "办理员工入职", null))),
            Map.entry("PAYROLL", List.of(new Step(CHANGE, "生成工资条", List.of("payroll:generate"), "生成工资条", null))),
            Map.entry("GOODS_LIST", List.of(new Step(CHANGE, "批量导入货品", List.of("goods:import"), "导入货品",
                    "「货品资料」页的「导入货品」可以导入 .xlsx 文件：先检测再导入，导入后可撤回；它只新增货品，不修改已有货品。"))),
            Map.entry("BOM_LIST", List.of(new Step(CHANGE, "导入产品组装明细", List.of("goods:bom:create"), "新增货品组装明细",
                    "在「货品资料」打开对应产品，在「组件」里用「导入组件」导入，格式与「导出组件」相同，一次导入一个产品。"))),
            Map.entry("CUSTOMER_LIST", List.of(new Step(CHANGE, "新增客户", List.of("client:create"), "新增客户", null))),
            Map.entry("SUPPLIER_LIST", List.of(new Step(CHANGE, "新增供应商", List.of("supplier:create"), "新增供应商", null))),
            Map.entry("STOCK_LIST", List.of(new Step(CHANGE, "录入实盘数量", List.of("stock:count:submit"), "录入盘点并提交审核",
                    "你可以在「即时库存」选具体仓库进入盘点模式，逐项录入实盘数量后送审。"))));
    private static final Map<String, List<Limit>> LIMITS = Map.ofEntries(
            Map.entry("EMPLOYEE_ROSTER", List.of(
                    new Limit(Set.of(Intent.RECONCILE), "按花名册批量更正员工资料",
                            "助手暂时还不能按花名册自动批量更正或补录员工资料，请在员工档案里逐个处理。"),
                    new Limit(Set.of(Intent.IMPORT), "按花名册批量新增员工", "助手暂时还不能按花名册批量新增员工，请在「办理入职」里逐个办理。"))),
            Map.entry("HR_DOCUMENT", List.of(new Limit(CHANGE, "按文件自动修改员工资料",
                    "助手不能按文件自动修改员工档案或办理入职、离职，请在员工档案里处理。"))),
            Map.entry("PAYROLL", List.of(new Limit(CHANGE, "按文件导入或修改工资",
                    "工资由系统在工资条生成里按员工档案计算，不能直接导入或修改这份工资表。"))),
            Map.entry("ATTENDANCE", List.of(new Limit(CHANGE, "导入考勤", "系统暂时没有考勤功能，这份考勤表不能导入。"))),
            Map.entry("GOODS_LIST", List.of(new Limit(Set.of(Intent.RECONCILE), "按文件批量修改已有货品",
                    "货品导入只能新增货品，已有货品请在货品资料里逐个修改。"))),
            Map.entry("BOM_LIST", List.of(new Limit(Set.of(Intent.RECONCILE), "按文件一次修改多个产品的组装明细",
                    "组件导入一次只处理一个产品，助手不能按文件一次改多个产品。"))),
            Map.entry("CUSTOMER_LIST", List.of(new Limit(CHANGE, "批量导入客户", "客户资料暂时没有批量导入功能，请在客户资料里逐个新增或修改。"))),
            Map.entry("SUPPLIER_LIST", List.of(new Limit(CHANGE, "批量导入供应商", "供应商资料暂时没有批量导入功能，请在供应商资料里逐个新增或修改。"))),
            Map.entry("STOCK_LIST", List.of(new Limit(CHANGE, "按文件直接修改库存",
                    "库存不能按文件直接修改，要在即时库存的盘点模式里录入实盘数量并送审，审核通过后才生效。"))),
            Map.entry("BANK_STATEMENT", List.of(new Limit(CHANGE, "按银行流水自动记账或对账", "助手不能按银行流水自动记账或对账，收款和付款要逐笔登记。"))),
            Map.entry("WAREHOUSE_DOCUMENT", List.of(new Limit(CHANGE, "按文件自动生成单据", "助手暂时不能按这类文件自动生成单据，请在对应页面新建。"))),
            Map.entry("PRODUCTION_DOCUMENT", List.of(new Limit(CHANGE, "按文件自动生成单据", "助手暂时不能按这类文件自动生成单据，请在对应页面新建。"))),
            Map.entry("PURCHASE_DOCUMENT", List.of(new Limit(CHANGE, "按文件自动生成单据", "助手暂时不能按这类文件自动生成单据，请在对应页面新建。"))));
    private static final Set<String> UNRECOGNIZED = Set.of("UNKNOWN", "MIXED_DOCUMENT");

    private final AiChatAccessPolicy access;
    private final AiDocumentWorkflows workflows;

    public AiDocumentDestinations(AiChatAccessPolicy access, AiDocumentWorkflows workflows) {
        this.access = access;
        this.workflows = workflows;
    }

    /**
     * Pages, blocked follow-ups and advice lines for the reader's CURRENT permissions.
     *
     * @param workflows forms this file could fill (before permission filtering); the ones the reader cannot use
     *                  are listed as blocked only for a recognized type, never for an unrecognized file
     */
    Advice advise(String type, Intent intent, List<String> workflows) {
        AuthUser actor = access.requireChat();
        List<Map<String, String>> pages = new ArrayList<>();
        Map<String, Map<String, String>> blocked = new LinkedHashMap<>();
        List<String> lines = new ArrayList<>();
        if (CAN.containsKey(type)) lines.add(CAN.get(type));
        for (Limit limit : LIMITS.getOrDefault(type, List.of()))
            if (limit.intents().contains(intent)) blocked.putIfAbsent(limit.title(), entry(limit.title(), limit.reason()));
        for (Step step : STEPS.getOrDefault(type, List.of())) {
            boolean held = allowed(actor, step.permissions());
            if (held && step.grantedLine() != null && (step.intents().contains(intent) || intent == Intent.NONE || intent == Intent.QUESTION))
                lines.add(step.grantedLine());
            if (!held && step.intents().contains(intent)) blocked.putIfAbsent(step.title(), entry(step.title(), need(step.label())));
        }
        for (Use use : USES.getOrDefault(type, List.of())) {
            Destination page = page(use.page());
            if (allowed(actor, page.permissions())) {
                pages.add(Map.of("key", page.key(), "title", page.title(), "route", page.route()));
                lines.add("可以去「" + page.title() + "」" + use.hint() + "。");
            } else blocked.putIfAbsent(page.title(), entry(page.title(), need(page.permissionLabel())));
        }
        if (!UNRECOGNIZED.contains(type) && workflows != null) for (String workflow : workflows) {
            String reason = this.workflows.blockedReason(workflow);
            if (reason != null) blocked.putIfAbsent(formTitle(workflow), entry(formTitle(workflow), reason));
        }
        if (!blocked.isEmpty()) lines.add("另有 " + blocked.size() + " 项你暂时办不了，原因见下方。");
        return new Advice(List.copyOf(pages), List.copyOf(blocked.values()), List.copyOf(lines));
    }

    static Destination page(String key) {
        for (Destination page : CATALOG) if (page.key().equals(key)) return page;
        throw new IllegalArgumentException("unknown page " + key);
    }

    static String formTitle(String workflow) {
        return switch (workflow) {
            case "SALES_ORDER" -> "填写销售订货单";
            case "SALES_QUOTE" -> "填写销售报价单";
            case "EXPENSE_CLAIM" -> "填写报销申请";
            default -> "填写单据";
        };
    }

    private static boolean allowed(AuthUser actor, List<String> permissions) {
        return actor.isSuperAdmin() || actor.getPermissions().containsAll(permissions);
    }

    private static String need(String label) { return "需要「" + label + "」权限，请联系管理员开通。"; }

    private static Map<String, String> entry(String title, String reason) { return Map.of("title", title, "reason", reason); }
}
