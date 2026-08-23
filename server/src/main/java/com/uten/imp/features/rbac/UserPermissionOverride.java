package com.uten.imp.features.rbac;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

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

    @Column(name = "authority_source", nullable = false)
    private String authoritySource = "LEGACY_UNKNOWN";

    @Column(name = "source_actor_user_id")
    private UUID sourceActorUserId;

    /** Compare-and-set version for page-context super-admin mutations. */
    @Column(name = "row_version", nullable = false)
    private long rowVersion = 1L;

    /** Inactive rows are neutral tombstones retained so CAS versions never reset. */
    @Column(nullable = false)
    private boolean active = true;
}
