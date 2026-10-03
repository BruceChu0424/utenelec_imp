package com.uten.imp.features.ai.chat;

import com.uten.imp.security.AuthUser;

import java.util.List;
import java.util.Map;
import java.util.Set;

/** Reviewed workflow facts, isolated by the same domain gate as tools. No database schema or secrets. */
final class AiChatKnowledge {
    record Entry(String id, String domain, String title, String reply, List<String> keywords) {}
    static final List<Entry> ALL = List.of(
            entry("SELF_HELP", "SELF", "我的 AI 助手", "我可以解释你有权限的业务流程、查看已开放的本人工作台信息，并提供可检查的操作入口。具体单据仍遵守部门、负责人、车间和字段权限。未开放的数据我会明确说明，不能代替审核或绕过权限。", "帮助", "你好", "能做", "hello"),
            entry("SALES_ORDER", "SALES", "报价文件与订货单", "上传 Excel、CSV 或 PDF 报价文件后，可以识别客户和货品并带入新建订货单页面。请核对客户、规格、数量、单位、价格与未匹配行，再按原流程保存和审核。销售可在授权范围内调整单据价格与折扣；已有报价单经财务核价后，还需登记客户同意当前版本，才能生成订货草稿。聊天不会自动审核或出库。", "订货", "报价", "excel", "文件", "订单"),
            entry("PRODUCTION_FLOW", "PRODUCTION", "生产执行与日报", "生产按计划、执行段、领料、日报及质检入库衔接。填写真实产量，保留来源与数量去向；日报保存不等于已入库，需继续走审批、质检和仓库点收。跨车间或来源不一致的数据不能通过聊天操作。", "生产", "日报", "排产", "车间", "产量", "领料"),
            entry("PURCHASE_FLOW", "PURCHASE", "采购与到货", "采购业务按采购单、财务审批、到货、验收和入库衔接。单据状态、供应商与负责人范围由原业务接口校验；价格和财务信息需要单独权限。聊天不会代为确认付款或修改库存。", "采购", "供应商", "到货"),
            entry("WAREHOUSE_FLOW", "WAREHOUSE", "仓库与库存", "库存数量以正式入库、出库、退回及盘点审批链为准。请在有权限的仓库和单据范围核对货品、单位、颜色、批次及来源，不能把聊天中的数量说明当作正式库存凭据。", "库存", "仓库", "入库", "出库", "盘点"),
            entry("FINANCE_COST", "FINANCE", "成本口径", "物料成本需区分货品资料中的参考成本与业务凭据归集的实际成本。查询会标明数据来源、币种和完整性；没有证据时不会把参考值称为完整实际成本。请提供准确货品编码或名称。", "成本", "财务", "核价"),
            entry("QUALITY_FLOW", "QUALITY", "质量检验", "质量检验按对应任务和原始来源处理，检验结论与后续入库、退回或返工保持关联。只在当前授权的检验范围填写、复核和确认；聊天不会直接发布检验结论。", "质检", "质量", "检验", "不合格"),
            entry("SUBCONTRACT_FLOW", "SUBCONTRACT", "委外业务", "委外业务需保留订单、发料、收货、退料与结算之间的来源和数量关系。请使用有权限的业务页面处理；价格和结算信息另受字段权限控制，聊天不会直接生成库存或财务流水。", "委外", "外协"),
            entry("HR_FLOW", "HR", "人员与部门", "人员与部门资料按现有组织权限管理。员工隐私、薪资、证件和银行资料不会提供给对话模型；本助手仅说明流程，人员敏感信息需到获授权的专用页面查看。", "人事", "部门", "员工", "薪资", "工资"),
            entry("ADMIN_GRANT", "ADMIN", "授权操作", "超级管理员可说明目标员工及具体权限。助手先生成明确的授权预览，核对目标、权限和影响后再确认，并按原安全流程进行密码再认证和审计。不会通过聊天文本直接提权、修改超级管理员身份或一次性授予未知权限。", "授权", "权限", "赋予", "grant")
    );
    private static Entry entry(String id, String domain, String title, String reply, String... keywords) {
        String example = switch (id) {
            case "SELF_HELP" -> "你可以问‘当前页面的数量怎么填写，请举例’，或者‘我的工作台有哪些待办’。";
            case "SALES_ORDER" -> "报价版本 3 核价后获客户同意，才按版本 3 转订货；若改了数量形成新版本，应重新核对客户确认。";
            case "PRODUCTION_FLOW" -> "昨天已报 60 个、今天又完成 40 个，本次报 40 个，不能重复填累计 100 个。";
            case "PURCHASE_FLOW" -> "约定采购 100 个、首批到货 60 个，本次按实际到货和验收结果办理，其余 40 个保持未到状态。";
            case "WAREHOUSE_FLOW" -> "账面 100 个、实盘 98 个，应录入 98 并按盘点差异流程处理；聊天说明不会直接把账面改成 98。";
            case "FINANCE_COST" -> "已知材料 2 元、加工 1 元但运费缺价，3 元仅是已知部分，不能当作完整实际成本。";
            case "QUALITY_FLOW" -> "收到 100 个、其中 5 个待复检，按检验规则分别记录，不能把待复检数量直接视为合格库存。";
            case "SUBCONTRACT_FLOW" -> "委外 50 个、首批回厂 30 个时，保留原委外来源和剩余 20 个的去向，不改用另一订单抵数。";
            case "HR_FLOW" -> "同名的两位员工分别为示例工号 A001 和 A002，核对工号后再到获授权的档案页面处理。";
            case "ADMIN_GRANT" -> "超级管理员要求给示例员工 A 增加一个指定查看权限，先检查唯一目标与权限预览，再再认证确认；不会顺带赋予修改或授权能力。";
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
