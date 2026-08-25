package com.uten.imp.common.identity;

import java.util.List;

/** Foundation-level source of truth for statuses that represent a current employee. */
public final class CurrentEmployeeStatusPolicy {

    public static final List<String> CURRENT_EMPLOYEE_STATUSES =
            List.of("active", "probation", "onLeave");

    public static boolean isCurrentEmployee(String status) {
        return CURRENT_EMPLOYEE_STATUSES.contains(status);
    }

    private CurrentEmployeeStatusPolicy() {
    }
}
