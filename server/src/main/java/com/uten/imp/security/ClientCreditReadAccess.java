package com.uten.imp.security;

/** A personal narrow grant never confers finance-wide access or access to another customer's records. */
public final class ClientCreditReadAccess {
    public static final String VIEW = "client:credit:view";
    private ClientCreditReadAccess() {}
    public static boolean canRead(AuthUser actor) {
        return actor != null && !actor.isVisitor() && actor.getEmployeeId() != null
                && actor.getImpersonatedBy() == null && !actor.isMustChangePassword() && actor.isAccountNonLocked()
                && (actor.isSuperAdmin() || actor.getPermissions().contains(VIEW)
                || actor.getPermissions().containsAll(java.util.Set.of("ar_ap_ledger:view", "finance:view:all")));
    }
}
