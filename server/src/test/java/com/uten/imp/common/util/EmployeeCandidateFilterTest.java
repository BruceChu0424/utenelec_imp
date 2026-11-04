package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class EmployeeCandidateFilterTest {
    @Test void emptyImmutableExclusionsDoNotFailAndNeverBroadenTheCallerPredicate() {
        var filter = EmployeeCandidateFilter.of(null, false, List.of(), "employee.id", "employee.department_id");
        assertTrue(filter.sql().isEmpty()); assertTrue(filter.parameters().isEmpty());
    }

    @Test void oversizedOrNullExclusionInputsAreRejectedRatherThanTruncated() {
        UUID id = UUID.randomUUID();
        assertThrows(ApiException.class, () -> EmployeeCandidateFilter.of(null, false,
                Collections.nCopies(1001, id), "employee.id", "employee.department_id"));
        assertThrows(ApiException.class, () -> EmployeeCandidateFilter.of(null, false,
                Arrays.asList(id, null), "employee.id", "employee.department_id"));
    }
}
