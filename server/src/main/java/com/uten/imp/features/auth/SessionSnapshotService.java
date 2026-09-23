package com.uten.imp.features.auth;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.UserPreferenceReadPort;
import com.uten.imp.features.auth.dto.DocumentScopeCapabilityDto;
import com.uten.imp.features.org.department.staffpermission.PagePermissionWorkspaceService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 会话快照(ADR-108): 只随登录、切身份、授权变化而变的「会话级事实」, 由 /api/auth/me 一次带回。
 *
 * <ul>
 *   <li>{@code delegableSurfaceKeys}: 当前主体能打开「本页权限设置」的页面 key(替代每个页面
 *       顶栏各自请求一次 capability);</li>
 *   <li>{@code documentScopes}: 六个单据范围的普通写能力(替代详情页每次加载都作废重拉);</li>
 *   <li>{@code preferences}: 用户偏好整表(替代 9 个页面偏好各自拉整张表)。</li>
 * </ul>
 *
 * <p>快照只决定按钮显隐与默认值; 服务端写接口的对象级校验不变, 仍是最终把关。
 */
@Service
@RequiredArgsConstructor
public class SessionSnapshotService {

    private final PagePermissionWorkspaceService pagePermissions;
    private final DocumentScopeCapabilityService documentScopes;
    private final UserPreferenceReadPort preferences;

    @Transactional(readOnly = true)
    public SessionSnapshot current() {
        Map<String, DocumentScopeCapabilityDto> scopes = new LinkedHashMap<>();
        for (String scope : DocumentScopeCapabilityService.scopes()) {
            scopes.put(scope, documentScopes.current(scope));
        }
        return new SessionSnapshot(
                pagePermissions.delegableSurfaceKeys(),
                scopes,
                preferences.currentUserPreferences());
    }

    /** 会话快照内容, 见类注释。 */
    public record SessionSnapshot(
            List<String> delegableSurfaceKeys,
            Map<String, DocumentScopeCapabilityDto> documentScopes,
            Map<String, JsonNode> preferences) {
    }
}
