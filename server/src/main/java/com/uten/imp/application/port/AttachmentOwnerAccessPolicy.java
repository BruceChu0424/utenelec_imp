package com.uten.imp.application.port;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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

    /** Separate selected-avatar visibility; it never authorizes listing private documents. */
    default void requireCanViewAvatar(UUID ownerId, AuthUser user) {
        requireCanView(ownerId, user);
    }

    void requireCanManage(UUID ownerId, AuthUser user);

    default void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        requireCanManage(ownerId, user);
    }

    /** Optional owner-specific avatar selection gate; never grants upload or delete. */
    default void requireCanSelectAvatar(UUID ownerId, AuthUser user) {
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "Owner does not support avatars");
    }
}
