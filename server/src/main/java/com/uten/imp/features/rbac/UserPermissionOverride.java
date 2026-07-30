package com.uten.imp.features.rbac;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/** 个人权限点覆盖（grant=角色之外加授，revoke=从角色权限中回收）。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "user_permission_overrides")
public class UserPermissionOverride {

    @EmbeddedId
    private UserPermissionOverrideId id;

    /** 覆盖方向：grant / revoke（DB CHECK 约束）。 */
    @Column(nullable = false)
    private String effect;
}
