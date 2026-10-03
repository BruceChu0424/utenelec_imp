package com.uten.imp.features.admin;

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

/** Atomic single-permission merge; a preview can never replace unrelated overrides. */
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
    private final AiPermissionProposalCodec codec;

    @Transactional
    public Map<String, Object> confirm(String proposalId) {
        access.requireDomain("ADMIN");
        var actor = current.get().filter(AiPermissionGrantTool::allowed)
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "仅超级管理员可执行对话授权"));
        var proposal = codec.decode(proposalId);
        if (!actor.getId().equals(proposal.actorId())) throw conflict();
        var target = lifecycle.lock(proposal.targetId());
        support.requireAuthorizationTarget(target.account());
        lifecycle.requireCurrentEmployee(target);
        lifecycle.requireActiveAccount(target);
        // Keep the actor row stable until the existing authorization transaction commits.
        var liveActor = accounts.findByIdForUpdate(actor.getId()).orElseThrow(AiPermissionGrantService::conflict);
        var actorState = accounts.findAccountStateById(actor.getId()).orElseThrow(AiPermissionGrantService::conflict);
        if (liveActor.isDeleted() || !liveActor.isSuperAdmin() || !"active".equals(liveActor.getStatus())
                || liveActor.getAuthVersion() != proposal.actorAuthVersion()
                || actorState.getAuthorizationEpoch() != proposal.authorizationEpoch()) throw conflict();
        var permission = permissions.findByCode(proposal.permissionCode()).orElseThrow(AiPermissionGrantService::conflict);
        if (!permission.getId().equals(proposal.permissionId()) || !GrantPolicy.individuallyGrantable(permission.grantPolicies())) throw conflict();
        var before = overrides.getPermissionOverrides(proposal.targetId());
        var grants = new LinkedHashSet<>(before.grants());
        var revokes = new LinkedHashSet<>(before.revokes());
        if (grants.contains(proposal.permissionCode()) && !revokes.contains(proposal.permissionCode())) {
            return Map.of("status", "ALREADY_GRANTED", "reply", "该员工已获得这项个人权限，无需重复授权。");
        }
        if (target.account().getAuthVersion() != proposal.targetAuthVersion()) throw conflict();
        grants.add(proposal.permissionCode());
        revokes.remove(proposal.permissionCode());
        overrides.setPermissionOverrides(proposal.targetId(), grants.stream().toList(), revokes.stream().toList());
        return Map.of("status", "GRANTED", "reply", "已为 " + target.employee().getFullName() + "("
                + target.employee().getCode() + ")授予 " + permission.getName() + "。本次授权已记录审计。");
    }

    private static ApiException conflict() {
        return new ApiException(ErrorCode.CONFLICT, "授权对象或权限状态已变化，请重新发起并确认授权");
    }
}
