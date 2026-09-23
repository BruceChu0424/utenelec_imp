package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

/** security-10: 审计只存账号脱敏值(保留后 4 位), 未认证输入不像号码就不落库。 */
class AuditAccountMaskTest {

    @Test
    void phoneLikeAccountsKeepOnlyTheLastFourDigits() {
        assertEquals("*******8000", AuditAccountMask.mask("13800138000"));
        assertEquals("*******1234", AuditAccountMask.mask("138****1234"),
                "an already partially masked number is normalized to the same shape");
        assertEquals("admin", AuditAccountMask.mask("admin"));
        assertEquals("ops:reset_business_data", AuditAccountMask.mask("ops:reset_business_data"));
        assertNull(AuditAccountMask.mask("  "));
    }

    @Test
    void unverifiedInputIsKeptOnlyWhenItLooksLikeANumberOrSystemLabel() {
        assertEquals("*******8000", AuditAccountMask.forStorage(false, "13800138000"));
        assertNull(AuditAccountMask.forStorage(false, "Secret#Typed"),
                "a password typed into the account box must never be stored");
        assertEquals("system", AuditAccountMask.forStorage(false, "system"));
        assertEquals("V2026-001", AuditAccountMask.forStorage(true, "V2026-001"));
    }
}
