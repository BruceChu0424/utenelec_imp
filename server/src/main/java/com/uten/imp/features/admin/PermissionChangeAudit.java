package com.uten.imp.features.admin;

import com.uten.imp.audit.AuditService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 授权变更的语义化业务事件(audit-retention-settings-03)。
 *
 * <p>部门矩阵、全员基础包、个人覆盖、负责人页面委派、数据范围五个入口都在各自事务里
 * 算出差量，只在真的有改动时写且只写一条事件：result 是给人看的
 * {@code added=[..]; removed=[..]} 摘要，完整列表放在 after JSON 里。没有改动时
 * 调用方直接不调这里——保存一个没改动的矩阵，审计 0 行。
 */
@Component
public class PermissionChangeAudit {

    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    public PermissionChangeAudit(AuditService audit, SecurityContextCurrentUser currentUser) {
        this.audit = audit;
        this.currentUser = currentUser;
    }

    /**
     * 记一条授权变更事件；必须在写授权行的同一事务里调用，业务回滚时事件一起消失。
     *
     * @param action     语义化动作码，如 department_permission_change
     * @param targetType 被改的对象表，如 departments / users
     * @param targetId   被改对象 id
     * @param added      本次新增的条目(码或 grant:码 等)
     * @param removed    本次移除的条目
     * @param context    附加上下文(如页面权限面、数据范围名)，可为空
     */
    public void record(String action, String targetType, String targetId,
                       Collection<String> added, Collection<String> removed,
                       Map<String, Object> context) {
        List<String> addedList = added.stream().sorted().toList();
        List<String> removedList = removed.stream().sorted().toList();
        Map<String, Object> change = new LinkedHashMap<>();
        if (context != null) {
            change.putAll(context);
        }
        change.put("added", addedList);
        change.put("removed", removedList);
        AuthUser actor = currentUser.get().orElse(null);
        audit.logCommittedChange(
                actor == null ? null : actor.getId(),
                actor == null ? null : actor.getLoginAccount(),
                action,
                targetType,
                targetId,
                summary(addedList, removedList),
                change);
    }

    static String summary(List<String> added, List<String> removed) {
        return "added=" + added + "; removed=" + removed;
    }
}
