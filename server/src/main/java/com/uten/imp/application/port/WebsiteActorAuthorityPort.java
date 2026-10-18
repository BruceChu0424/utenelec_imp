package com.uten.imp.application.port;

import java.util.Set;
import java.util.UUID;

/** Current staff operation authority for reverse website session leases; never a stored login snapshot. */
public interface WebsiteActorAuthorityPort {
    Set<String> WEBSITE_PERMISSIONS=Set.of("website:view","website:content_edit","website:product_edit",
            "website:media_manage","website:publish","website:rollback","webinquiry:view");

    /** Unknown, inactive, password-reset or departed identities return no authority. */
    Set<String> currentPermissions(UUID actorId, UUID authSessionId);
}
