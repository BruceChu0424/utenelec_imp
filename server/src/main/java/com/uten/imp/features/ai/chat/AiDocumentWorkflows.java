package com.uten.imp.features.ai.chat;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AiChatAccessPolicy;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Fixed frontend destinations, current principal only. No model can provide a URL or a write action. */
@Component
public class AiDocumentWorkflows {
    /** Every form a file can fill, in display order. */
    static final List<String> ALL = List.of("SALES_ORDER", "SALES_QUOTE", "EXPENSE_CLAIM");
    private final AiChatAccessPolicy access;
    public AiDocumentWorkflows(AiChatAccessPolicy access) { this.access = access; }
    public List<Map<String, String>> available() {
        var actor = access.requireChat();
        Set<String> domains = access.domains();
        var choices = new ArrayList<Map<String, String>>();
        if (domains.contains("SALES")) {
            if (actor.isSuperAdmin() || actor.getPermissions().containsAll(Set.of("sales_order:view", "sales_order:create")))
                choices.add(Map.of("workflow", "SALES_ORDER", "title", title("SALES_ORDER")));
            if (actor.isSuperAdmin() || actor.getPermissions().containsAll(Set.of("sales_quote:view", "sales_quote:create")))
                choices.add(Map.of("workflow", "SALES_QUOTE", "title", title("SALES_QUOTE")));
        }
        if (actor.isSuperAdmin() || actor.getPermissions().contains("expense:apply"))
            choices.add(Map.of("workflow", "EXPENSE_CLAIM", "title", title("EXPENSE_CLAIM")));
        return List.copyOf(choices);
    }
    public void require(String workflow) {
        if (available().stream().noneMatch(item -> item.get("workflow").equals(workflow)))
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号没有这项业务的填写权限");
    }

    /** Plain reason why the current account cannot use a workflow; null when it can. */
    public String blockedReason(String workflow) {
        if (available().stream().anyMatch(item -> item.get("workflow").equals(workflow))) return null;
        var actor = access.requireChat();
        return switch (workflow) {
            case "SALES_ORDER", "SALES_QUOTE" -> {
                boolean order = workflow.equals("SALES_ORDER");
                Set<String> needed = order ? Set.of("sales_order:view", "sales_order:create") : Set.of("sales_quote:view", "sales_quote:create");
                yield actor.getPermissions().containsAll(needed)
                        ? "只有销售部门的人员可以用助手填写销售单据，请联系管理员确认你的部门。"
                        : "需要「" + (order ? "销售订货单查看和新建" : "销售报价单查看和新建") + "」权限，请联系管理员开通。";
            }
            case "EXPENSE_CLAIM" -> "需要「报销申请」权限，请联系管理员开通。";
            default -> "这项业务不能由助手辅助填写。";
        };
    }

    static String title(String workflow) {
        return switch (workflow) {
            case "SALES_ORDER" -> "打开销售订货单并辅助填写";
            case "SALES_QUOTE" -> "打开销售报价单并辅助填写";
            case "EXPENSE_CLAIM" -> "打开我的报销申请并辅助填写";
            default -> "";
        };
    }
}
