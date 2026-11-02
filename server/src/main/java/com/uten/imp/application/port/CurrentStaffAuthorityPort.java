package com.uten.imp.application.port;

import java.util.Set;

/** Current active staff eligibility and fresh authorities, without granting any business capability. */
public interface CurrentStaffAuthorityPort {
    Set<String> currentStaffPermissions();
}
