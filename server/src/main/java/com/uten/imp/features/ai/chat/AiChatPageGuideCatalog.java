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

/** Reviewed page semantics, never a screenshot, DOM, form payload or arbitrary repository retrieval. */
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
            throw new ApiException(ErrorCode.FORBIDDEN, "这个字段未开放说明或不在你当前的权限范围内");
        }
        return Optional.of(new PageGuide(page.key(), page.title(), page.domain(), page.source(), fields));
    }

    /** Respond from the reviewed catalog, with clearly hypothetical examples and a source. */
    public String answer(PageGuide guide, String fieldKey) {
        return answer(guide, fieldKey, "OVERVIEW");
    }

    public String answer(PageGuide guide, String fieldKey, String mode) {
        if (guide == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先打开需要帮助的页面");
        List<FieldGuide> chosen = fieldKey == null || fieldKey.isBlank() ? guide.fields()
                : guide.fields().stream().filter(f -> f.key().equals(fieldKey)).toList();
        if (chosen.isEmpty()) throw new ApiException(ErrorCode.FORBIDDEN, "这个字段未开放说明或不在你当前的权限范围内");
        StringBuilder reply = new StringBuilder("当前页面: ").append(guide.title())
                .append("。以下按系统页面规则说明；示例是假设数据，不是当前单据的实际值。\n");
        for (FieldGuide field : chosen) {
            reply.append("\n").append(field.label()).append(": ");
            if ("STEPS".equals(mode)) {
                int step = 1;
                for (String sentence : field.instruction().split("[。；]")) {
                    if (!sentence.isBlank()) reply.append("\n").append(step++).append(". ").append(sentence.strip());
                }
            } else if (!"EXAMPLE".equals(mode)) {
                reply.append(field.instruction());
            }
            if (!"SUMMARY".equals(mode)) reply.append("\n举例: ").append(field.example());
            reply.append("\n");
        }
        return reply.append("\n来源: ").append(guide.source())
                .append("。实际能否编辑、保存或审核，以当前单据状态和页面可用操作为准。").toString();
    }

    private boolean fieldAllowed(AuthUser user, Field field) {
        return (field.domain().isEmpty() || access.hasDomain(field.domain()))
                && (field.anyPermission().isEmpty() || user.isSuperAdmin()
                || field.anyPermission().stream().anyMatch(user.getPermissions()::contains));
    }
    private static void requirePermission(AuthUser user, String permission) {
        if (!permission.isEmpty() && !user.isSuperAdmin() && !user.getPermissions().contains(permission)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前页面不在你的权限范围内，请联系管理员核对权限");
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
            "按这行货品的计量单位填写真实需求数量。不同单位分开合计，不能把箱和个直接相加。",
            "客户要 120 个零件，单位选个、数量填 120；另有 3 箱包装则另起一行，不能合计为 123 个。");
    private static final Field CLIENT = f("client", "客户",
            "从你有权限查看的客户资料中选择，核对负责人和结账条件。找不到客户时先检查负责范围，不要用相似名称替代。",
            "假设客户为示例客户 A，先选中该客户，再核对带出的币种和结账方式；看到客户 B 不能因名称相近就代用。");
    private static final Field TERMS = f("terms", "币种、结账方式和交期",
            "核对本单币种、结账方式、业务员和交货日期；客户文件币种是识别参考，不会自动替你确定交易币种。",
            "假设双方约定人民币、月结 30 天、交货日为 2026-11-15，就按该约定选择；示例日期不是系统建议交期。");
    private static final Field PRICE = restricted(f("price", "价格和折扣",
            "报价可以提出本单单价和折扣，不会修改货品资料售价。报价转入订货后的已确认价款受锁定规则保护，修改须走原业务流程。",
            "假设单价 10 元、折扣显示为 90%，100 个的示例金额为 900 元。不要把 9 折填成 9%；以页面实际折扣格式核对。"),
            "SALES", "sales_order:price:view");
    private static final Field FILE = f("file", "识别客户文件",
            "选择 Excel、CSV 或支持的 PDF/图片后，核对客户、货品、数量、颜色、单位及来源行，再带入草稿。不能确定的匹配应人工选择。",
            "文件中写 A-01、100 个，识别为两个近似货品时先选对货品，再确认导入；导入成功不代表订货单已经保存或审核。");
    private static final Field COMMERCIAL = f("terms", "供应商和行级商业条款",
            "采购或委外订货按明细行核对供应商、结账/结算方式、币种、汇率和税率。保存按供应商及条款组合分组。",
            "两行同一家供应商但一行人民币月结、一行美元预付，会分成不同条款组。统一设置条款时先确认勾选的行确实适用。");
    private static final List<Page> PAGES = buildPages();

    private static List<Page> buildPages() {
        List<Page> pages = new ArrayList<>();
        pages.add(p("sales_order", "销售订货单", "SALES", "/sales/orders" + DOC, "sales_order:view",
                "订货单公共表头规范 / ADR-139", CLIENT, QUANTITY, TERMS, PRICE, FILE));
        pages.add(p("sales_quote", "销售报价单", "SALES", "/sales/quotes" + DOC, "sales_quote:view",
                "ADR-139 销售报价议价与客户确认", CLIENT, QUANTITY, PRICE, FILE,
                f("validUntil", "有效期", "核对报价截止日期，预填日期仍需人工确认。已过期报价不能直接登记客户同意或转订货。",
                        "假设报价约定至 2026-11-30 有效，就选择该日；客户 12 月才接受时先按实际业务重新处理报价。"),
                f("workflow", "财务核价和客户同意", "保存报价后提交财务核价；财务确认后由销售登记客户对当前版本的同意，再生成订货草稿。重新修改会使旧客户确认失效。",
                        "报价版本 3 已核价并获客户同意；若再改数量形成新版本，不能沿用版本 3 的客户同意直接转单。")));
        pages.add(p("purchase_order", "采购订货单", "PURCHASE", "/purchase/orders" + DOC, "purchase_order:view",
                "订货单公共表头规范 / ADR-068", QUANTITY, COMMERCIAL,
                f("source", "申请来源", "从采购任务核对申请与剩余需求再分解订货；数量应反映实际采购约定，来源保留到后续收货。",
                        "剩余需求 100 个，本次约定采购 120 个，应按实际约定填 120，并核对超出部分，不把申请来源改成另一行。")));
        pages.add(p("subcontract_order", "委外订货单", "SUBCONTRACT", "/subcontract/orders" + DOC, "subcontract_order:view",
                "订货单公共表头规范 / 委外全链路 SOP", QUANTITY, COMMERCIAL,
                f("source", "委外来源和供料", "核对委外任务、委外商及需发出的子件。加工订货、子件出仓、回厂点收是不同步骤。",
                        "假设委外加工 50 个，先核对加工件与子件领用需求；保存委外订单并不等于 50 个已经回厂入库。")));
        pages.add(p("production_analysis", "生产物料分析", "PRODUCTION",
                "/production/material-analysis|/production/material-analyses(?:/" + ID + "/summary)?", "production_material_analysis:view",
                "生产物料分析页 / ADR-102 / ADR-118",
                f("supplyMode", "供应方式", "系统按规则自动确认供应方式；直接修改会保存。红色待补项先处理，路线确认本身不会下达采购、委外或生产任务。",
                        "某物料改为采购后，仍要核对缺口并执行备料下达，不能认为选了采购就已经生成采购订货单。"),
                f("shortage", "需求、库存和缺口", "区分原始需求、已分配库存、后续供给和当前缺口。在途、待检和尚未入库的物料不能当作当前可领的合格库存。",
                        "需要 100 个、合格可用 60 个、在途 40 个；当前仍不能把这 40 个当作现货发料。"),
                f("generate", "下达和审核", "生成草稿或待审核计划与批准生产不同。缺料允许等待，完整齐套和实际领料仍按后续规则检查。",
                        "需求 100 个但尚缺物料，可以按允许流程形成待料任务；不能把待料状态解释为可以直接开工。")));
        pages.add(p("workshop_tasks", "我的车间任务", "PRODUCTION",
                "/production/workshop-tasks(?:/draw-request|/batch-draw)?", "production_execution:view", "我的车间任务页 / ADR-118",
                f("status", "任务状态", "待料、可领料、已领料、开工、报工和入库分别表示不同事实。实际发完必需材料后，按页面可用操作开工。",
                        "看到可领料时先申请并完成实际领料；不是点击查看任务就自动开工。"),
                f("output", "产量和去向", "完成产量按实际填写并核对来源工单；后续直送、公共余量及品质/入库状态分别保留，报工不等于成品库存。",
                        "本次实际完成 105 个，就核对并填写真实产量和合法去向；不能为了配计划 100 个而少报 5 个。")));
        pages.add(p("daily_report", "生产报工", "PRODUCTION", "/production/daily-reports" + DOC,
                "production_daily_report:view", "生产执行与报工 / ADR-118",
                f("source", "工单和报工日期", "选择本次实际生产的工单和执行分段，核对车间、货品、日期及计量单位。来源不能只凭同名货品替换。",
                        "同一货品有两个工单时，分别按实际生产来源报工，不把另一工单的数量填到本单。"),
                f("quantity", "本次完成数量", "填写本次实际完成数量，区分累计数量与本次增量；不良、退回及去向按页面独立字段核对。",
                        "昨天已报 60 个，今天又完成 40 个，本次填 40，不能填累计 100 导致重复计数。"),
                f("output", "产出去向", "按页面给出的合法去向分配数量，合计须与本次产出相符。直送仍受同车间与接收缺口约束，公共余量沿品质及入库流程。",
                        "本次产出 100 个，若允许直送 30 个，其余 70 个按实际去向处理，不能把 100 个同时填入两个去向。")));
        pages.add(p("workshop_count", "车间内料仓盘点", "PRODUCTION", "/workshop-material/count",
                "workshop_material:view", "车间内料仓盘点页 / ADR-131",
                f("containers", "料斗和料桶", "逐个启用容器选择正在使用的物料并录入档位或过秤公斤数。空容器要明确记空，漏填不代表零。",
                        "一只料斗空了就记空，另一只称得 12.5 公斤就填写 12.5，不能把未检查的容器都当成空。"),
                f("bags", "整袋和开口袋", "整袋按袋数乘每袋净重，开口袋逐笔录入过秤净重。核对公斤单位与实际物料。",
                        "3 袋每袋 25 公斤，加开口袋 6.2 公斤，实盘为 81.2 公斤；这里的数字仅作计算示例。"),
                f("zero", "零库存和提交", "有账或本期有进出的物料即使用完也要明确录零。提交前补齐容器、物料和仍在保存的行。",
                        "某料本期曾领入但现已用完，核对后填 0；空白会被视为尚未盘点。")));
        pages.add(p("goods", "货品资料", "SELF", "/basicinfo/goods(?:/" + ID + ")?", "goods:view", "货品资料 / ADR-138",
                f("unit", "单位和数量", "基本单位是数量和成本换算的基础，核对物料实际计量方式。不同单位不直接相加。",
                        "螺丝按个计量、塑料按公斤计量，不能把 100 个加 10 公斤显示成 110。"),
                restricted(f("cost", "成本口径", "区分测算成本、已确认成本版本和实际库存价值。缺价保留待核，不能按 0 元解释。",
                        "每 1 个产品测算材料 2 元加加工 1 元得 3 元；若运费尚缺，3 元只是已知部分，不能称为完整成本。"),
                        "FINANCE", "goods:cost:view")));
        pages.add(p("quote_finance", "报价财务核价", "FINANCE", "/finance/quote-review(?:/" + ID + ")?",
                "sales_quote_finance:view", "销售报价财务核价页 / ADR-139",
                f("claim", "认领与版本", "先认领当前报价任务，再核对价格、折扣、数量和财务条款。修改保存后再确认，版本冲突应刷新核对。",
                        "同事已修改数量时，你手里的旧版本不能直接确认；先刷新查看变更。"),
                f("confirm", "核价后的下一步", "财务核价确认后仍需销售登记客户同意当前版本，才能生成订货草稿。",
                        "财务接受 9 元单价，不代表客户已经同意 9 元，销售还需记录客户反馈。")));
        pages.add(p("employee", "员工档案", "HR", "/employee(?:/" + ID + ")?", "employee:view", "员工档案 / 权限体系总设计",
                f("identity", "人员身份", "按姓名和工号核对人员，部门是任职信息。姓名相同不能视为同一员工。敏感资料仍由原字段权限控制。",
                        "张三(示例工号 A001)和张三(示例工号 A002)是两个档案，操作前应核对工号。")));
        pages.add(p("dashboard", "我的工作台", "SELF", "/dashboard", "", "工作台部门分区与动态权限配置",
                f("todos", "待办和数字", "工作台显示本人部门及权限允许的入口，红色表示轮到你处理。不同入口的数字按各自业务口径统计。",
                        "有 3 项采购待办表示该入口有 3 项待处理事项，不代表全公司只有 3 张采购单。")));
        return List.copyOf(pages);
    }
}
