package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import java.time.OffsetDateTime;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class SystemPostingStyleServiceTest {
    private final OffsetDateTime time=OffsetDateTime.parse("2026-10-11T10:00:00.123456Z");
    private SystemPostingStyleService.Role role(UUID style,boolean usable) {
        return new SystemPostingStyleService.Role("INVENTORY_ASSET","库存科目","ACCOUNT",style,"原科目",usable,time);
    }
    @Test void retainedTimestampAcceptsSameInstantWithDifferentOffset() {
        assertDoesNotThrow(()->SystemPostingStyleService.requireCurrent(role(null,false),
                new SystemPostingStyleService.Configure(UUID.randomUUID(),time.withOffsetSameInstant(java.time.ZoneOffset.ofHours(8)))));
    }
    @Test void stalePanelCannotConfigureNewAccount() {
        var error=assertThrows(ApiException.class,()->SystemPostingStyleService.requireCurrent(role(null,false),
                new SystemPostingStyleService.Configure(UUID.randomUUID(),time.minusNanos(1000))));
        assertEquals(ErrorCode.CONFLICT,error.getCode());
    }
    @Test void alreadyConfiguredHistoricalRoleCannotBeRedirected() {
        UUID original=UUID.randomUUID();
        assertThrows(ApiException.class,()->SystemPostingStyleService.requireCurrent(role(original,true),
                new SystemPostingStyleService.Configure(UUID.randomUUID(),time)));
        assertDoesNotThrow(()->SystemPostingStyleService.requireCurrent(role(original,true),
                new SystemPostingStyleService.Configure(original,time)));
    }
}
