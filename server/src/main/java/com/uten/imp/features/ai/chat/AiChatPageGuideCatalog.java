package com.uten.imp.features.ai.chat;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Reviewed page semantics (supplementary since ADR-150). What is actually on screen arrives in the
 * bounded page snapshot; this catalog only adds reviewed filling guidance and hypothetical examples.
 */
@Component
public class AiChatPageGuideCatalog {
    public record FieldGuide(String key, String label, String instruction, String example) { }
    public record PageGuide(String key, String title, String domain, String source, List<FieldGuide> fields) { }
    private record Field(FieldGuide guide, Set<String> anyPermission, String domain) { }
    private record Page(String key, String title, String domain, Pattern route, String permission,
                        String source, List<Field> fields) { }
    private static final String ID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
    private static final String DOC = "(?:/(?:new|" + ID + "(?:/edit)?))?";
    private final AiChatAccessPolicy access;

    public AiChatPageGuideCatalog(AiChatAccessPolicy access) { this.access = access; }

    public Optional<PageGuide> resolve(String route, String fieldKey) {
        if (route == null || route.isBlank()) return Optional.empty();
        if (route.length() > 240 || !route.startsWith("/") || route.contains("//") || route.contains("..")
                || route.contains("%") || route.contains("?") || route.contains("#") || route.contains("\\")
                || route.chars().anyMatch(Character::isISOControl)) return Optional.empty();
        Page page = PAGES.stream().filter(p -> p.route().matcher(route).matches()).findFirst().orElse(null);
        if (page == null) return Optional.empty();
        AuthUser actor = access.requireChat();
        access.requireDomain(page.domain());
        requirePermission(actor, page.permission());
        if (route.endsWith("/new") && !page.permission().isEmpty()) {
            requirePermission(actor, page.permission().replace(":view", ":create"));
        } else if (route.endsWith("/edit") && !page.permission().isEmpty()) {
            requirePermission(actor, page.permission().replace(":view", ":edit"));
        }
        List<FieldGuide> fields = page.fields().stream().filter(f -> fieldAllowed(actor, f)).map(Field::guide).toList();
        if (fieldKey != null && !fieldKey.isBlank() && fields.stream().noneMatch(f -> f.key().equals(fieldKey))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "这个字段暂时不能说明，请联系管理员。");
        }
        return Optional.of(new PageGuide(page.key(), page.title(), page.domain(), page.source(), fields));
    }

    /** Every suggested question is answerable by this same authorized local guide. */
    public List<String> suggestions(PageGuide guide) {
        if (guide.fields().isEmpty()) return List.of();
        List<String> suggestions = new ArrayList<>();
        suggestions.add("这个页面怎么填写？请举例。");
        guide.fields().stream().limit(2).forEach(field -> suggestions.add(field.label() + "怎么填写？请举例。"));
        return List.copyOf(suggestions);
    }

    /** Respond from the reviewed catalog, with clearly hypothetical examples. */
    public String answer(PageGuide guide, String fieldKey) {
        return answer(guide, fieldKey, "OVERVIEW");
    }

    /**
     * Full reviewed guide (ADR-150): every permitted field, hypothetical examples kept in every mode.
     * SUMMARY shortens each instruction to its first sentence only because the user asked for brevity.
     */
    public String answer(PageGuide guide, String fieldKey, String mode) {
        if (guide == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先打开需要帮助的页面");
        List<FieldGuide> chosen = fieldKey == null || fieldKey.isBlank() ? guide.fields()
                : guide.fields().stream().filter(f -> f.key().equals(fieldKey)).toList();
        if (chosen.isEmpty()) throw new ApiException(ErrorCode.FORBIDDEN, "这个字段暂时不能说明，请联系管理员。");
        boolean overview = fieldKey == null || fieldKey.isBlank();
        if ("EXAMPLE".equals(mode)) return "举例(假设):\n" + String.join("\n", chosen.stream()
                .map(field -> field.label() + ": " + field.example()).toList());
        StringBuilder reply = new StringBuilder();
        if (overview) reply.append(guide.title()).append(" 的填写要点:");
        int index = 1;
        for (FieldGuide field : chosen) {
            if (!reply.isEmpty()) reply.append("\n");
            if (overview) reply.append(index++).append(". ");
            reply.append(field.label()).append(": ");
            if ("STEPS".equals(mode)) {
                int step = 1;
                for (String sentence : field.instruction().split("[。；]")) {
                    if (!sentence.isBlank()) reply.append("\n   ").append(step++).append(") ").append(sentence.strip());
                }
            } else if ("SUMMARY".equals(mode)) {
                reply.append(field.instruction().split("(?<=[。；])")[0].strip());
            } else {
                reply.append(field.instruction());
            }
            reply.append(overview ? "\n   举例(假设): " : "\n举例(假设): ").append(field.example());
        }
        return reply.toString();
    }

    /** Reviewed guide text offered to the model as a trusted source. */
    public java.util.Map<String, Object> modelView(PageGuide guide) {
        return java.util.Map.of("title", guide.title(), "fields", guide.fields().stream().map(field -> java.util.Map.of(
                "key", field.key(), "label", field.label(), "instruction", field.instruction(),
                "hypotheticalExample", field.example())).toList());
    }

    private boolean fieldAllowed(AuthUser user, Field field) {
        return (field.domain().isEmpty() || access.hasDomain(field.domain()))
                && (field.anyPermission().isEmpty() || user.isSuperAdmin()
                || field.anyPermission().stream().anyMatch(user.getPermissions()::contains));
    }
    private static void requirePermission(AuthUser user, String permission) {
        if (!permission.isEmpty() && !user.isSuperAdmin() && !user.getPermissions().contains(permission)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "这个页面暂时不能查看，请联系管理员。");
        }
    }
    private static Field f(String key, String label, String instruction, String example) {
        return new Field(new FieldGuide(key, label, instruction, example), Set.of(), "");
    }
    private static Field restricted(Field field, String domain, String... permissions) {
        return new Field(field.guide(), Set.of(permissions), domain);
    }
    private static Page p(String key, String title, String domain, String route, String permission, String source, Field... fields) {
        return new Page(key, title, domain, Pattern.compile(route), permission, source, List.of(fields));
    }

    private static final Field QUANTITY = f("quantity", "数量和单位",
            "按实际数量填写，箱和个分开记录。",
            "要 120 个就填 120，单位选个；3 箱另起一行。");
    private static final Field CLIENT = f("client", "客户",
            "选对客户，核对结账条件。找不到时不要用相似名称代替。",
            "给客户 A 做单，就选客户 A，再核对币种和结账方式。");
    private static final Field TERMS = f("terms", "币种、结账方式和交期",
            "按双方约定选币种、结账方式、业务员和交货日期。",
            "约定人民币、月结 30 天，就按这个约定填写。");
    private static final Field PRICE = restricted(f("price", "价格和折扣",
            "按本单约定填写；已确认的价格不能直接改。",
            "单价 10 元、9 折填 90%，100 个共 900 元。"),
            "SALES", "sales_order:price:view");
    private static final Field FILE = f("file", "识别客户文件",
            "上传文件，核对客户、货品和数量，再保存单据。",
            "文件写 A-01、100 个，先核对货品，再确认数量 100。");
    private static final Field COMMERCIAL = f("terms", "供应商和行级商业条款",
            "逐行核对供应商、币种、税率和付款方式。条款不同要分开。",
            "同一家供应商，人民币月结和美元预付要分开记录。");
    private static final List<Page> PAGES = buildPages();

    private static List<Page> buildPages() {
        List<Page> pages = new ArrayList<>();
        pages.add(p("sales", "销售管理", "SALES", "/sales", "", "销售管理 / ADR-139",
                restricted(f("order", "订货单", "点新建销售订货单，选客户、填货品和数量，核对后保存。也可以上传客户文件帮你填写。",
                        "客户订 100 个 A001，选客户后添加 A001，数量填 100。"), "SALES", "sales_order:create"),
                restricted(f("quote", "报价单", "点新建销售报价单，选客户、填货品和数量，补充有效期后保存。",
                        "给客户 A 报 100 个 A001，按约定填有效期。"), "SALES", "sales_quote:create")));
        pages.add(p("sales_order", "销售订货单", "SALES", "/sales/orders" + DOC, "sales_order:view",
                "订货单公共表头规范 / ADR-139", CLIENT, QUANTITY, TERMS, PRICE, FILE));
        pages.add(p("sales_quote", "销售报价单", "SALES", "/sales/quotes" + DOC, "sales_quote:view",
                "ADR-139 销售报价议价与客户确认", CLIENT, QUANTITY, PRICE, FILE,
                f("validUntil", "有效期", "填双方约定的截止日期；过期后要重新处理报价。",
                        "约定 11 月 30 日截止，就选这一天。"),
                f("workflow", "财务核价和客户同意", "先财务核价，再登记客户对当前版本的同意，最后转订货。修改后要重新确认。",
                        "客户同意了版本 3；再改数量，就要请客户重新确认。")));
        pages.add(p("expense", "报销申请", "SELF", "/expense" + DOC, "expense:apply", "报销申请 / ADR-094",
                f("purpose", "报销事由", "写清哪一天、因为什么工作产生了费用。", "10 月 3 日到客户 A 处送样，填写送样交通费。"),
                f("amount", "费用金额", "按实际支出填写，核对币种和票面金额。", "车费 35 元、停车费 10 元，分别列明，共 45 元。"),
                f("invoice", "发票和凭证", "上传清晰发票，核对金额和日期后再保存。", "发票写 100 元，先核对实际支出，再填写报销金额。")));
        pages.add(p("purchase_order", "采购订货单", "PURCHASE", "/purchase/orders" + DOC, "purchase_order:view",
                "订货单公共表头规范 / ADR-068", QUANTITY, COMMERCIAL,
                f("source", "申请来源", "选对采购任务，按实际约定填写数量。",
                        "还需 100 个，约定买 120 个，就填 120，并核对多买的 20 个。")));
        pages.add(p("subcontract_order", "委外订货单", "SUBCONTRACT", "/subcontract/orders" + DOC, "subcontract_order:view",
                "订货单公共表头规范 / 委外全链路 SOP", QUANTITY, COMMERCIAL,
                f("source", "委外来源和供料", "选对委外任务和委外商，核对需要发出的材料。",
                        "委外加工 50 个，先做单和发料；回厂后再收货。")));
        pages.add(p("production_analysis", "生产物料分析", "PRODUCTION",
                "/production/material-analysis|/production/material-analyses(?:/" + ID + "/summary)?", "production_material_analysis:view",
                "生产物料分析页 / ADR-102 / ADR-118",
                f("supplyMode", "供应方式", "先补齐红色项。修改供应方式会立即保存，随后还要下达备料。",
                        "改成采购后，再核对缺口并下达，不等于已经下单。"),
                f("shortage", "需求、库存和缺口", "核对需要多少、现货多少。待检和在途数量暂时不能领用。",
                        "需要 100 个，现货 60 个、在途 40 个，现在只能按现货安排。"),
                f("generate", "下达和审核", "缺料可以先等待，领齐材料后再开工。",
                        "任务显示待料，先等材料，不能直接开工。")));
        pages.add(p("workshop_tasks", "我的车间任务", "PRODUCTION",
                "/production/workshop-tasks(?:/draw-request|/batch-draw)?", "production_execution:view", "我的车间任务页 / ADR-118",
                f("status", "任务状态", "先领齐材料再开工，完工后报工，再质检入库。",
                        "显示可领料时，先申请领料，领齐后再开工。"),
                f("output", "产量和去向", "按实际产量报工，核对工单和去向；报工还不算入库。",
                        "实际做了 105 个，就填 105，不按计划 100 个少报。")));
        pages.add(p("daily_report", "生产报工", "PRODUCTION", "/production/daily-reports" + DOC,
                "production_daily_report:view", "生产执行与报工 / ADR-118",
                f("source", "工单和报工日期", "选本次生产的工单，核对车间、货品、日期和单位。",
                        "同一货品有两个工单，分别按各自完成数量填写。"),
                f("quantity", "本次完成数量", "只填本次完成数，不填累计数；不良数量另填。",
                        "昨天报 60 个，今天做 40 个，本次填 40，不填 100。"),
                f("output", "产出去向", "填写实际去向，各项数量相加要等于本次产量。",
                        "做了 100 个，分成 30 个和 70 个，合计还是 100 个。")));
        pages.add(p("workshop_count", "车间内料仓盘点", "PRODUCTION", "/workshop-material/count",
                "workshop_material:view", "车间内料仓盘点页 / ADR-131",
                f("containers", "料斗和料桶", "逐个核对容器，填物料和重量；空的也要明确记空。",
                        "空料斗记空，另一桶称得 12.5 公斤就填 12.5。"),
                f("bags", "整袋和开口袋", "整袋填袋数和每袋重量，开口袋按实际净重填写。",
                        "3 袋各 25 公斤，加散料 6.2 公斤，共 81.2 公斤。"),
                f("zero", "零库存和提交", "用完的物料填 0，不要留空；核对齐全后再提交。",
                        "本期领过的料已用完，填 0；空白表示还没盘。")));
        pages.add(p("goods", "货品资料", "SELF", "/basicinfo/goods(?:/" + ID + ")?", "goods:view", "货品资料 / ADR-138",
                f("unit", "单位和数量", "按实际计量方式选单位，不同单位分开计算。",
                        "螺丝填个，塑料填公斤；100 个和 10 公斤不能相加。"),
                restricted(f("cost", "成本口径", "分清估算和实际成本；缺少的费用待核，不能当成 0 元。",
                        "材料 2 元、加工 1 元，共 3 元；运费没核齐，成本还不完整。"),
                        "FINANCE", "goods:cost:view")));
        pages.add(p("quote_finance", "报价财务核价", "FINANCE", "/finance/quote-review(?:/" + ID + ")?",
                "sales_quote_finance:view", "销售报价财务核价页 / ADR-139",
                f("claim", "认领与版本", "先认领，再核对价格和数量。修改后先保存，再确认。",
                        "同事刚改过数量，先刷新核对，再确认。"),
                f("confirm", "核价后的下一步", "财务核价后，销售还要登记客户同意，再转订货。",
                        "财务同意 9 元后，还要问客户是否接受。")));
        pages.add(p("employee", "员工档案", "HR", "/employee(?:/" + ID + ")?", "employee:view", "员工档案 / 权限体系总设计",
                f("identity", "人员身份", "核对姓名和工号，避免同名认错人。",
                        "两个张三，用 A001、A002 工号分清。")));
        pages.add(p("dashboard", "我的工作台", "SELF", "/dashboard", "", "工作台部门分区与动态权限配置",
                f("todos", "待办和数字", "红色数字表示有事情需要处理，点进去查看。",
                        "采购显示 3，表示有 3 项采购待办。")));
        return List.copyOf(pages);
    }
}
