package com.uten.imp.features.attachment;

import com.uten.imp.security.AuthUser;

import java.util.UUID;

/**
 * 业务对象对附件的对象级授权端口。
 *
 * <p>通用附件层不能只检查 attachment:view/manage，否则持该权限的人可以枚举任意
 * ownerType/ownerId。每个接入附件的业务域必须实现本端口，并按业务对象的所有者、状态和
 * 审批职责再次判定。
 */
public interface AttachmentOwnerAccessPolicy {

    /** 本策略负责的稳定 owner_type，例如 {@code EXPENSE_CLAIM}。 */
    String ownerType();

    /** 当前员工是否能查看该业务对象及其附件；拒绝时直接抛业务异常。 */
    void requireCanView(UUID ownerId, AuthUser user);

    /** 当前员工是否能在该业务对象上新增/删除附件；拒绝时直接抛业务异常。 */
    void requireCanManage(UUID ownerId, AuthUser user);

    /**
     * Serializes attachment binding/removal with business-state transitions.
     * Policies whose owner can leave an editable state should override this with
     * a pessimistic owner-row lookup. The default preserves simple owner policies.
     */
    default void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        requireCanManage(ownerId, user);
    }
}
