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
    private final AiChatAccessPolicy access;
    public AiDocumentWorkflows(AiChatAccessPolicy access) { this.access = access; }
    public List<Map<String, String>> available() {
        var actor = access.requireChat();
        Set<String> domains = access.domains();
        var choices = new ArrayList<Map<String, String>>();
        if (domains.contains("SALES")) {
            if (actor.isSuperAdmin() || actor.getPermissions().containsAll(Set.of("sales_order:view", "sales_order:create")))
                choices.add(Map.of("workflow", "SALES_ORDER", "title", "打开销售订货单并辅助填写"));
            if (actor.isSuperAdmin() || actor.getPermissions().containsAll(Set.of("sales_quote:view", "sales_quote:create")))
                choices.add(Map.of("workflow", "SALES_QUOTE", "title", "打开销售报价单并辅助填写"));
        }
        if (actor.isSuperAdmin() || actor.getPermissions().contains("expense:apply"))
            choices.add(Map.of("workflow", "EXPENSE_CLAIM", "title", "打开我的报销申请并辅助填写"));
        return List.copyOf(choices);
    }
    public void require(String workflow) {
        if (available().stream().noneMatch(item -> item.get("workflow").equals(workflow)))
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号没有这项业务的填写权限");
    }
}
