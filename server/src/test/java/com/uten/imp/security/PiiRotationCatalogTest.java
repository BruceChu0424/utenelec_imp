package com.uten.imp.security;

import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PiiRotationCatalogTest {
    @Test void immutablePreservationIsExactlyDeclaredAndNeverChangesTheAppRewrapProtocol() {
        Set<String> application=new HashSet<>();
        for(var target:PiiRotationCatalog.TARGETS) {
            assertNotEquals("employee_identity_merge_payloads",target.table());
            for(String column:target.columns())assertTrue(application.add(target.table()+"."+column));
        }
        assertEquals("pii-pgp-v1",PiiRotationCatalog.VERSION);
        assertEquals(8,PiiRotationCatalog.TARGETS.size());
        assertEquals(27,application.size());
        assertEquals(Map.of("employee_identity_merge_payloads.snapshot_enc",
                PiiRotationCatalog.PreservationPolicy.IMMUTABLE_EMPLOYEE_MERGE_ENVELOPE),PiiRotationCatalog.PRESERVED_CIPHERS);
        assertTrue(java.util.Collections.disjoint(application,PiiRotationCatalog.PRESERVED_CIPHERS.keySet()));
        var governed=new HashSet<>(application);governed.addAll(PiiRotationCatalog.PRESERVED_CIPHERS.keySet());
        assertEquals(28,governed.size());
        assertFalse(governed.contains("unknown_table.new_enc"));
        assertThrows(UnsupportedOperationException.class,()->PiiRotationCatalog.PRESERVED_CIPHERS.clear());
    }
}
