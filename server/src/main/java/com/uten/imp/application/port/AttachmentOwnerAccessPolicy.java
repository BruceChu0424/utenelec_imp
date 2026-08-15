package com.uten.imp.application.port;

import com.uten.imp.security.AuthUser;

import java.util.UUID;

/**
 * Business-owner authorization SPI used by the attachment feature.
 *
 * <p>Each owning feature implements this contract without depending on attachment persistence.
 * The attachment feature dispatches to exactly one policy for each stable owner type.</p>
 */
public interface AttachmentOwnerAccessPolicy {

    String ownerType();

    void requireCanView(UUID ownerId, AuthUser user);

    void requireCanManage(UUID ownerId, AuthUser user);

    default void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        requireCanManage(ownerId, user);
    }
}
