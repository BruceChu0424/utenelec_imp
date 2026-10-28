package com.uten.imp.support;

import com.uten.imp.common.util.IdCardUtil;
import org.junit.jupiter.api.Test;
import java.util.HashSet;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class SyntheticEmployeeIdentityTest {
    @Test void sameRoleKeepsItsLabelAndHasDistinctStableIdentityNames() {
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        assertNotEquals(SyntheticEmployeeIdentity.name("审核员",first),SyntheticEmployeeIdentity.name("审核员",second));
        assertEquals(SyntheticEmployeeIdentity.name("审核员",first),SyntheticEmployeeIdentity.name("审核员",first));
        assertTrue(SyntheticEmployeeIdentity.name("审核员",first).startsWith("审核员 ["));
        assertThrows(IllegalArgumentException.class,()->SyntheticEmployeeIdentity.name(" ",first));
        assertThrows(NullPointerException.class,()->SyntheticEmployeeIdentity.name("role",null));
    }

    @Test void syntheticDocumentsAreUniqueAndUseTheCanonicalValidationAndNormalizationRules() {
        var documents=new HashSet<String>();
        for(int index=0;index<2000;index++) {
            String document=SyntheticEmployeeIdentity.document();
            assertTrue(IdCardUtil.isValid(document));
            assertEquals(document,IdCardUtil.normalize(document));
            assertTrue(document.startsWith("99"));
            assertTrue(documents.add(document));
        }
    }
}
