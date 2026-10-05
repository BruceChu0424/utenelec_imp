package com.uten.imp.features.admin;

import com.uten.imp.application.port.AiChatActionProposalPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.AiChatAccessPolicy;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.Map;
import java.util.UUID;

/**
 * Atomic single-permission merge; a preview can never replace unrelated overrides. The ADR-150 proposal
 * is consumed once inside this transaction, so a double click or replay grants nothing twice.
 */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('ai:use') and hasAuthority('authorization:manage') and principal.superAdmin")
public class AiPermissionGrantService {
    private final SecurityContextCurrentUser current;
    private final AiChatAccessPolicy access;
    private final UserAccountRepository accounts;
    private final PermissionRepository permissions;
    private final AdminAccountLifecycleLock lifecycle;
    private final AdminUserSupport support;
    private final PermissionOverrideAdminService overrides;
    private final AiChatActionProposalPort proposals;

    @Transactional
    public Map<String, Object> confirm(UUID proposalId) {
        access.requireDomain("ADMIN");
        var actor = current.get().filter(AiPermissionGrantTool::allowed)
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "仅超级管理员可执行对话授权"));
        var proposal = proposals.consumeServerAction(proposalId, AiChatActionProposalPort.PERMISSION_GRANT);
        UUID targetId = UUID.fromString(proposal.targetRef());
        String permissionCode = String.valueOf(proposal.args().get("permissionCode"));
        UUID permissionId = UUID.fromString(String.valueOf(proposal.args().get("permissionId")));
        var target = lifecycle.lock(targetId);
        support.requireAuthorizationTarget(target.account());
        lifecycle.requireCurrentEmployee(target);
        lifecycle.requireActiveAccount(target);
        // Keep the actor row stable until the existing authorization transaction commits.
        var liveActor = accounts.findByIdForUpdate(actor.getId()).orElseThrow(AiPermissionGrantService::conflict);
        if (liveActor.isDeleted() || !liveActor.isSuperAdmin() || !"active".equals(liveActor.getStatus())) throw conflict();
        var permission = permissions.findByCode(permissionCode).orElseThrow(AiPermissionGrantService::conflict);
        if (!permission.getId().equals(permissionId) || !GrantPolicy.individuallyGrantable(permission.grantPolicies())) throw conflict();
        var before = overrides.getPermissionOverrides(targetId);
        var grants = new LinkedHashSet<>(before.grants());
        var revokes = new LinkedHashSet<>(before.revokes());
        if (grants.contains(permissionCode) && !revokes.contains(permissionCode)) {
            String reply = "该员工已经可以使用这项功能，无需重复开通。";
            proposals.completeServerAction(proposalId, reply);
            return Map.of("status", "ALREADY_GRANTED", "reply", reply);
        }
        if (proposal.targetVersion() == null || target.account().getAuthVersion() != proposal.targetVersion()) throw conflict();
        grants.add(permissionCode);
        revokes.remove(permissionCode);
        overrides.setPermissionOverrides(targetId, grants.stream().toList(), revokes.stream().toList());
        String reply = "已为 " + target.employee().getFullName() + "(" + target.employee().getCode() + ")开通 "
                + permission.getName() + "。";
        proposals.completeServerAction(proposalId, reply);
        return Map.of("status", "GRANTED", "reply", reply);
    }

    private static ApiException conflict() {
        return new ApiException(ErrorCode.CONFLICT, "授权对象或权限状态已变化，请重新发起并确认授权");
    }
}
