package com.uten.imp.features.ai.chat;

import com.uten.imp.security.AuthUser;

import java.util.List;
import java.util.Map;
import java.util.Set;

/** Reviewed workflow facts, isolated by the same domain gate as tools. No database schema or secrets. */
final class AiChatKnowledge {
    record Entry(String id, String domain, String title, String reply, List<String> keywords) {}
    static final List<Entry> ALL = List.of(
            entry("SELF_HELP", "SELF", "我的 AI 助手", "告诉我遇到的问题，或打开页面问我怎么填。", "帮助", "你好", "能做", "hello"),
            entry("CLIENT_CREATE_GUIDE", "SALES", "新增客户与基础资料填写", "打开基础资料里的客户资料，选分类后点新增。填写名称与状态，编号由系统自动生成，核对后由你点击保存。", "新增客户", "新建客户", "创建客户", "客户资料", "客户怎么", "客户如何"),
            entry("SALES_ORDER", "SALES", "报价文件与订货单", "上传文件后，我会帮你填单。核对客户、货品、数量和价格后再保存。已有报价转订货，先完成财务核价和客户同意。", "订货", "报价", "excel", "文件", "订单"),
            entry("PRODUCTION_FLOW", "PRODUCTION", "生产执行与日报", "先领料、再生产，报工填本次实际产量。报工后还要质检和入库。", "生产", "日报", "排产", "车间", "产量", "领料"),
            entry("PURCHASE_FLOW", "PURCHASE", "采购与到货", "先做采购单，财务通过后安排到货，再验收、入库。分批到货就分批填写。", "采购", "供应商", "到货"),
            entry("WAREHOUSE_FLOW", "WAREHOUSE", "仓库与库存", "入库、出库和盘点时，核对仓库、货品、数量和单位。待检数量不算可用库存。", "库存", "仓库", "入库", "出库", "盘点"),
            entry("FINANCE_COST", "FINANCE", "成本口径", "参考成本是估算，实际成本按业务单据计算。请告诉我货品名称或编号。", "成本", "财务", "核价"),
            entry("QUALITY_FLOW", "QUALITY", "质量检验", "打开对应检验任务，分别填合格、不合格和待复检数量。待复检不能算合格。", "质检", "质量", "检验", "不合格"),
            entry("SUBCONTRACT_FLOW", "SUBCONTRACT", "委外业务", "按原委外订单发料、收货和结算。分批回厂就分批登记，保留剩余数量。", "委外", "外协"),
            entry("HR_FLOW", "HR", "人员与部门", "可以问我转正、入职等提醒。处理员工资料前，先核对姓名和工号。工资等详情请到对应页面查看。", "人事", "部门", "员工", "薪资", "工资"),
            entry("ADMIN_GRANT", "ADMIN", "授权操作", "告诉我要给哪位员工开通哪项功能。核对确认卡后，再由你确认。", "授权", "权限", "赋予", "grant")
    );
    private static Entry entry(String id, String domain, String title, String reply, String... keywords) {
        String example = switch (id) {
            case "SELF_HELP" -> "可以问‘数量怎么填？’或‘我有哪些待办？’。";
            case "CLIENT_CREATE_GUIDE" -> "名称填‘示例客户 A’，状态选‘使用’。保存后，再回订货单选择这个客户。";
            case "SALES_ORDER" -> "版本 3 已核价且客户同意，才能转订货；改了数量，要重新确认。";
            case "PRODUCTION_FLOW" -> "昨天报 60 个，今天做 40 个，本次报 40 个，不填累计 100 个。";
            case "PURCHASE_FLOW" -> "买 100 个，先到 60 个，本次填 60，剩余 40 个等下批。";
            case "WAREHOUSE_FLOW" -> "账上 100 个，实际数到 98 个，盘点就填 98。";
            case "FINANCE_COST" -> "材料 2 元、加工 1 元，共 3 元；运费未核齐，不能当作完整成本。";
            case "QUALITY_FLOW" -> "100 个里有 5 个待复检，这 5 个先别计入合格数。";
            case "SUBCONTRACT_FLOW" -> "委外 50 个，先回来 30 个，本次记 30，剩余 20 个继续跟进。";
            case "HR_FLOW" -> "两个人都叫张三，先用 A001、A002 工号分清。";
            case "ADMIN_GRANT" -> "给示例员工 A 开通报价查看，先核对员工和功能名称，再确认。";
            default -> "请提供具体业务问题。";
        };
        return new Entry(id, domain, title, reply + "\n\n举例(假设数据，不是系统当前事实): " + example, List.of(keywords));
    }
    private static final Map<String, Set<String>> READ_PERMISSIONS = Map.of(
            "SALES_ORDER", Set.of("sales_quote:view", "sales_order:view"),
            "PRODUCTION_FLOW", Set.of("production_execution:view", "production_daily_report:view", "production_plan:view",
                    "production_material_analysis:view", "workshop_material:view"),
            "PURCHASE_FLOW", Set.of("purchase_request:view", "purchase_order:view", "purchase_receipt:view", "purchase_return:view"),
            "WAREHOUSE_FLOW", Set.of("stock:view", "stock_doc:view", "warehouse_inbound:view"),
            "QUALITY_FLOW", Set.of("production_quality_inspection:view", "procurement_inspection:view", "sales_return_quality:view"),
            "SUBCONTRACT_FLOW", Set.of("subcontract_inquiry:view", "subcontract_application:view", "subcontract_order:view",
                    "subcontract_receipt:view", "subcontract_material_issue:view", "subcontract_return:view",
                    "subcontract_material_return:view", "subcontract_waste:view"),
            "HR_FLOW", Set.of("employee:view", "department:view"));

    /** The real department scope and this topic's read permission are independent requirements. */
    static List<Entry> visible(Set<String> domains, AuthUser actor) {
        if (domains == null || !chatActor(actor)) return List.of();
        return ALL.stream().filter(entry -> domains.contains(entry.domain()) && allowed(entry, actor)).toList();
    }

    /** Closed catalog policy, also usable when revalidating a stored conversation topic. */
    static boolean allowed(Entry entry, AuthUser actor) {
        if (!chatActor(actor) || entry == null || !ALL.contains(entry)) return false;
        Set<String> permissions = actor.getPermissions();
        if ("ADMIN_GRANT".equals(entry.id())) return actor.isSuperAdmin() && permissions.contains("authorization:manage");
        if (actor.isSuperAdmin() || "SELF_HELP".equals(entry.id())) return true;
        if ("CLIENT_CREATE_GUIDE".equals(entry.id())) return permissions.containsAll(Set.of("client:view", "client:create"));
        if ("FINANCE_COST".equals(entry.id())) return permissions.containsAll(Set.of("goods:view", "goods:cost:view"));
        return READ_PERMISSIONS.getOrDefault(entry.id(), Set.of()).stream().anyMatch(permissions::contains);
    }

    private static boolean chatActor(AuthUser actor) {
        return actor != null && !actor.isVisitor() && actor.getEmployeeId() != null && actor.getImpersonatedBy() == null
                && !actor.isMustChangePassword() && actor.isAccountNonLocked() && actor.getPermissions() != null
                && (actor.isSuperAdmin() || actor.getPermissions().contains("ai:use"));
    }
    private AiChatKnowledge() {}
}
