package com.uten.imp.features.org.hrtask;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class HrCelebrationHistoryServiceTest {
    @Test void birthdayHistoryNeverQueriesWithoutHrNoticeAndPiiAuthority() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        var service = new HrCelebrationHistoryService(jdbc, current);
        for (Set<String> permissions : java.util.List.of(Set.<String>of(), Set.of("employee:view"),
                Set.of("employee:view", "notice:read"), Set.of("employee:pii:view", "notice:read"))) {
            when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                    "reader", permissions, false, true, false)));
            assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class,
                    () -> service.list("birthday", 1, 20)).getCode());
        }
        when(current.get()).thenReturn(Optional.of(AuthUser.visitor(UUID.randomUUID(), "visitor", "V1",
                Set.of("employee:view", "notice:read", "employee:pii:view"))));
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class,
                () -> service.list("birthday", 1, 20)).getCode());
        verifyNoInteractions(jdbc);
    }
}
