package com.uten.imp.features.notice;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Business information is a subscription of the corresponding operators, never of its readers.
 * This catalog owns both delivery and SQL read eligibility. Object routing, precise action-event
 * predicates and document state remain in their existing policies; this gate can only narrow them.
 */
final class BusinessNoticeParticipation {
    record Rule(String route, List<Set<String>> alternatives, Pattern pattern) {
        Rule(String route, List<Set<String>> alternatives) { this(route, List.copyOf(alternatives), Pattern.compile(route)); }
        boolean matches(String value) { return pattern.matcher(value == null ? "" : value).find(); }
        boolean allowed(Set<String> permissions) { return alternatives.stream().anyMatch(permissions::containsAll); }
    }

    private static Rule rule(String path, String... alternatives) {
        return new Rule("^" + path + "(/|[?]|$)", java.util.Arrays.stream(alternatives)
                .map(value -> Set.of(value.split(","))).toList());
    }

    static final List<Rule> RULES = List.of(
            rule("/profile/(edit|me/changes)", "profile:edit:self"),
            rule("/finance/sales-order-(confirmations|changes)", "sales_order_finance:view,sales_order_finance:confirm"),
            rule("/finance/quote-review", "sales_quote_finance:view,sales_quote_finance:confirm", "sales_quote_finance:view,sales_quote_finance:reject"),
            rule("/finance/procurement-(approvals|arrival-exceptions)", "finance_order_approval:view,finance_order_approval:approve", "finance_order_approval:view,finance_order_approval:reject"),
            rule("/finance/payables", "subcontract_loss_claim:view,subcontract_loss_claim:review", "subcontract_loss_claim:view,subcontract_loss_claim:fulfill", "procurement_iqc_rejection:view,procurement_iqc_rejection:confirm_credit", "procurement_iqc_rejection:view,procurement_iqc_rejection:close_no_credit"),
            rule("/finance/stock-count-review", "stock:count:finance_review"),
            rule("/warehouse/stock-count-review", "stock:count:warehouse_review"),
            rule("/stock/count-requests", "stock:count:submit", "stock:count:finance_review", "stock:count:warehouse_review"),
            rule("/sales/quotes", "sales_quote:view,sales_quote:edit", "sales_quote:view,sales_quote:convert,sales_order:create"),
            rule("/sales/orders", "sales_order:view,sales_order:edit", "sales_order:view,sales_order:approve", "sales_order:view,sales_shipment:view,sales_shipment:create"),
            rule("/sales/customer-shipments", "sales_other_shipment:view,sales_other_shipment:edit", "sales_other_shipment:view,sales_other_shipment:approve"),
            rule("/sales/shipments", "sales_shipment:view,sales_shipment:edit", "sales_shipment:view,sales_shipment:approve", "sales_shipment_finance:view,sales_shipment_finance:approve", "sales_shipment_finance:view,sales_shipment_finance:reject", "warehouse_sales_outbound:view,warehouse_sales_outbound:execute"),
            rule("/sales/returns", "sales_return:view,sales_return:edit", "sales_return:view,sales_return:approve"),
            rule("/purchase/requests", "purchase_request:view,purchase_order:create,purchase_order:decompose"),
            rule("/purchase/orders", "purchase_order:view,purchase_order:edit", "purchase_order:view,purchase_order:submit_finance"),
            rule("/subcontract/applications", "subcontract_application:view,subcontract_order:create,subcontract_order:decompose"),
            rule("/subcontract/orders", "subcontract_order:view,subcontract_order:edit", "subcontract_order:view,subcontract_order:draw"),
            rule("/subcontract/short-deliveries", "subcontract_order:view,subcontract_short_delivery:decide"),
            rule("/operations/workbench/purchase", "purchase_request:view,purchase_order:create,purchase_order:decompose", "purchase_order:view,purchase_order:edit"),
            rule("/operations/workbench/subcontract", "subcontract_application:view,subcontract_order:create,subcontract_order:decompose", "subcontract_order:view,subcontract_order:edit", "subcontract_order:view,subcontract_order:draw", "subcontract_order:view,subcontract_short_delivery:decide"),
            rule("/procurement/arrival-exceptions", "supplier_return_task:view,supplier_return_task:complete"),
            rule("/procurement/iqc-rejections", "procurement_iqc_rejection:view,procurement_iqc_rejection:record_return", "procurement_iqc_rejection:view,procurement_iqc_rejection:confirm_credit", "procurement_iqc_rejection:view,procurement_iqc_rejection:close_no_credit"),
            rule("/production/material-analys(is|es)", "production_material_analysis:view,production_material_analysis:create", "production_material_analysis:view,production_material_analysis:notify", "production_material_analysis:view,production_material_analysis:generate", "production_material_analysis:view,production_material_analysis:route"),
            rule("/production/plans", "production_plan:view,production_plan:edit", "production_plan:view,production_plan:approve", "production_material_analysis:view,production_material_analysis:create", "production_material_analysis:view,production_material_analysis:generate"),
            rule("/production/daily-reports", "production_daily_report:view,production_daily_report:edit", "production_daily_report:view,production_daily_report:approve", "production_daily_report:view,production_daily_report:create"),
            rule("/production/material-increment-requests", "production_plan:approve", "production_execution:view,production_execution:request_material_increment"),
            rule("/production/overproduction-rate-requests", "production_plan:approve", "production_execution:view,production_execution:request_overproduction_rate"),
            rule("/production/over-limit-dispositions", "production_plan:approve", "production_daily_report:view,production_daily_report:edit"),
            rule("/production/workshop-tasks", "production_execution:view,production_execution:start", "production_execution:view,production_daily_report:view,production_daily_report:create"),
            rule("/warehouse/subcontract-outbound", "subcontract_outbound:view,subcontract_outbound:execute"),
            rule("/warehouse/inspections", "procurement_inspection:view,procurement_inspection:handle"),
            rule("/warehouse/(iqc-stock-ins|quality-results)", "warehouse_iqc_stock_in:view,warehouse_iqc_stock_in:confirm", "warehouse_iqc_return:view,procurement_iqc_rejection:record_return"),
            rule("/warehouse/inbound", "warehouse_inbound:view,warehouse_inbound:stock_in"),
            rule("/warehouse/(DRAW|FINISHED_IN|production-finished-in|tasks)", "stock_doc:view,stock_doc:approve", "workshop_material:view,workshop_material:issue"),
            rule("/workshop-material", "workshop_material:view,workshop_material:issue", "workshop_material:view,workshop_material:choose", "workshop_material:view,workshop_material:setup"),
            rule("/quality/task-center", "procurement_inspection:view,procurement_inspection:handle", "production_quality_inspection:view,production_quality_inspection:approve"),
            rule("/rd/tasks", "rd_task:view,rd_task:resolve", "rd_task:view,goods:view,goods:bom:create", "rd_task:view,goods:view,goods:bom:edit", "rd_task:view,goods:view,goods:edit,unit:view"),
            rule("/expense/approval", "expense:approve", "expense:pay"),
            rule("/expense", "expense:apply", "expense:approve", "expense:pay"),
            rule("/hr/profile-changes", "profile:review"),
            rule("/visitor-approval", "visitor:approve"),
            rule("/my-visitors", "visitor:host_confirm"),
            rule("/suggestion", "suggestion:submit", "suggestion:reply"),
            rule("/payroll/(generate|review)", "payroll:generate", "payroll:review", "payroll:publish"),
            rule("/webinquiry", "webinquiry:view,webinquiry:claim"),
            rule("/admin/server-status", "server_status:alert:receive"),
            rule("/admin/server-operations", "server:update")
    );

    private static final Set<String> PROFILE_RESULT_EVENTS = Set.of("PROFILE_CHANGE_APPROVED", "PROFILE_CHANGE_REJECTED");
    private static final Map<String,String> LEGACY_PROFILE_RESULT = Map.of(
            "type", "approval", "kind", "NORMAL", "scope", "selected", "summary", "指定人员",
            "interaction", "none", "priority", "normal", "emptyJson", "[]",
            "title", "个人信息修改已批准",
            "contentPattern", "^您提交的 [1-9][0-9]* 项个人信息修改\\([^\\r\\n]+\\)已批准并生效。$");
    private static final Pattern BUSINESS_EVENT = Pattern.compile("^(SALES_|PROCUREMENT_|PURCHASE_|SUBCONTRACT_|PRODUCTION_|PREPLAN_|RD_TASK_|GOODS_BOM_|MATERIAL_ANALYSIS_|WORKSHOP_MATERIAL_|STOCK_COUNT_|EXPENSE_CLAIM_|PROFILE_CHANGE_|VISITOR_APPLY_|VISITOR_HOST_|PAYROLL_BATCH_|SUGGESTION_SUBMITTED|WEBSITE_INQUIRY_)");
    private static final Pattern BUSINESS_ROUTE = Pattern.compile("^/(sales|purchase|subcontract|production|warehouse|workshop-material|quality|rd|expense|finance|operations|webinquiry|hr/profile-changes|visitor-approval|my-visitors|suggestion|stock/count-requests)(/|[?]|$)");

    static boolean requiresPermission(String route, String event) {
        return ReviewNoticeCatalog.isReviewEvent(event) || BusinessNoticeActionCatalog.contains(event)
                || RULES.stream().anyMatch(rule -> rule.matches(route))
                || BUSINESS_ROUTE.matcher(route == null ? "" : route).find()
                || BUSINESS_EVENT.matcher(event == null ? "" : event).find();
    }

    static boolean allowed(String route, String event, Set<String> permissions) {
        if (receiptKind(event) != null) return permissions.containsAll(Set.of("notice:read", "profile:edit:self"));
        if (ReviewNoticeCatalog.isReviewEvent(event)) return ReviewNoticeAudience.eligible(event, permissions);
        if (BusinessNoticeActionCatalog.contains(event)) return BusinessNoticeActionCatalog.eligible(event, permissions);
        for (Rule rule : RULES) if (rule.matches(route)) return permissions.contains("notice:read") && rule.allowed(permissions);
        return !BUSINESS_ROUTE.matcher(route == null ? "" : route).find()
                && !BUSINESS_EVENT.matcher(event == null ? "" : event).find();
    }

    /** Classifies a known old producer's complete result shape, never infers its source batch. */
    static boolean allowed(Notice notice, Set<String> permissions) {
        return legacyProfileResult(notice)
                ? allowed(null, "PROFILE_CHANGE_APPROVED", permissions)
                : allowed(notice.getActionRoute(), notice.getSourceEvent(), permissions);
    }

    static boolean legacyProfileResult(Notice notice) {
        return notice.getSourceEvent()==null && notice.getActionRoute()==null && notice.getAudienceUserId()!=null
                && notice.getAggregateKind()==null && notice.getAggregateId()==null && notice.getSourceRevision()==null
                && notice.getDueAt()==null && !notice.isTopPriority() && Integer.valueOf(1).equals(notice.getAudienceCount())
                && LEGACY_PROFILE_RESULT.get("type").equals(notice.getType())
                && LEGACY_PROFILE_RESULT.get("kind").equals(notice.getKind())
                && LEGACY_PROFILE_RESULT.get("scope").equals(notice.getAudienceScope())
                && LEGACY_PROFILE_RESULT.get("summary").equals(notice.getAudienceSummary())
                && LEGACY_PROFILE_RESULT.get("interaction").equals(notice.getInteractionMode())
                && LEGACY_PROFILE_RESULT.get("priority").equals(notice.getPriority())
                && LEGACY_PROFILE_RESULT.get("emptyJson").equals(notice.getAttachments())
                && LEGACY_PROFILE_RESULT.get("emptyJson").equals(notice.getTargetDepartmentIds())
                && LEGACY_PROFILE_RESULT.get("emptyJson").equals(notice.getTargetEmployeeIds())
                && LEGACY_PROFILE_RESULT.get("title").equals(notice.getTitle())
                && Pattern.matches(LEGACY_PROFILE_RESULT.get("contentPattern"),
                        notice.getContent()==null?"":notice.getContent());
    }

    /** SQL receives resolved booleans, never maintains a second list of permission combinations. */
    static String readRules(Set<String> permissions) {
        Map<String, Object> snapshot = new LinkedHashMap<>();
        Map<String, Boolean> events = new LinkedHashMap<>();
        ReviewNoticeCatalog.events().stream().sorted().forEach(event -> events.put(event, ReviewNoticeAudience.eligible(event, permissions)));
        BusinessNoticeActionCatalog.events().stream().sorted().forEach(event -> events.put(event, BusinessNoticeActionCatalog.eligible(event, permissions)));
        PROFILE_RESULT_EVENTS.stream().sorted().forEach(event -> events.put(event, allowed(null, event, permissions)));
        snapshot.put("events", events);
        List<Map<String, Object>> routes = new ArrayList<>();
        for (Rule rule : RULES) routes.add(Map.of("pattern", rule.route(), "allowed", permissions.contains("notice:read") && rule.allowed(permissions)));
        snapshot.put("routes", routes);
        snapshot.put("businessRoute", BUSINESS_ROUTE.pattern());
        snapshot.put("businessEvent", BUSINESS_EVENT.pattern());
        Map<String,Object> legacyProfileResult=new LinkedHashMap<>(LEGACY_PROFILE_RESULT);
        legacyProfileResult.put("allowed", allowed(null,"PROFILE_CHANGE_APPROVED",permissions));
        snapshot.put("legacyProfileResult", legacyProfileResult);
        try { return new ObjectMapper().writeValueAsString(snapshot); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Cannot serialize business notice participation", failure); }
    }

    /** Result receipts keep a durable batch identity without becoming actionable review cards. */
    static String receiptKind(String event) {
        return event != null && PROFILE_RESULT_EVENTS.contains(event) ? "PROFILE_CHANGE_RESULT" : null;
    }

    private BusinessNoticeParticipation() {}
}
