package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.visitor.dto.VisitorScanDto.EmployeeDirectoryItem;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullSource;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * 访客搜索接待人(security-08 / permissions-13)：只对访客主体、关键字 2~20 个字、最多 5 人、
 * 只列可对外接待的员工、结果不带部门；按访客账号与来源地址限流，每次查询(含被拦下的)都写审计。
 */
class VisitorDirectoryServiceTest {

    private final UUID visitorId = UUID.randomUUID();
    private VisitorHostEligibility eligibility;
    private AuditService audit;
    private SecurityContextCurrentUser currentUser;
    private VisitorDirectoryService service;

    @BeforeEach
    void setUp() {
        eligibility = mock(VisitorHostEligibility.class);
        audit = mock(AuditService.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.of(
                AuthUser.visitor(visitorId, "13800000000", "V0001", VisitorAuthorities.ALL)));
        service = new VisitorDirectoryService(eligibility, new VisitorDirectoryRateLimiter(), audit, currentUser);
    }

    @Test
    void returnsOnlyWhitelistedHostsWithIdAndNameAndAuditsTheQuery() {
        UUID host = UUID.randomUUID();
        when(eligibility.searchByNamePrefix("张三", VisitorDirectoryService.MAX_RESULTS))
                .thenReturn(List.of(new VisitorHostEligibility.Host(host, "张三丰")));

        List<EmployeeDirectoryItem> result = service.searchHosts(" 张三 ", "10.0.0.8");

        assertThat(result).containsExactly(new EmployeeDirectoryItem(host, "张三丰"));
        assertThat(EmployeeDirectoryItem.class.getRecordComponents())
                .extracting(component -> component.getName())
                .containsExactly("id", "name");
        verify(audit).logExplicit(eq(visitorId), eq("V0001"), eq(VisitorDirectoryService.AUDIT_ACTION),
                eq("visitor_directory"), isNull(), contains("张三"));
    }

    @ParameterizedTest
    @NullSource
    @ValueSource(strings = {"", " ", "张", " 张 ", "一二三四五六七八九十一二三四五六七八九十一"})
    void keywordOutsideTwoToTwentyCharactersIsRejectedBeforeAnyQuery(String keyword) {
        ApiException error = assertThrows(ApiException.class, () -> service.searchHosts(keyword, "10.0.0.8"));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        verifyNoInteractions(eligibility);
    }

    @Test
    void staffTokensCannotUseTheVisitorDirectory() {
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(
                UUID.randomUUID(), UUID.randomUUID(), "staff", Set.of(), false, true, false)));

        ApiException error = assertThrows(ApiException.class, () -> service.searchHosts("张三", "10.0.0.8"));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        verifyNoInteractions(eligibility);
    }

    @Test
    void eleventhSearchInAMinuteIsRateLimitedAndStillAudited() {
        when(eligibility.searchByNamePrefix(anyString(), anyInt())).thenReturn(List.of());
        for (int i = 0; i < VisitorDirectoryRateLimiter.PER_ACCOUNT_PER_MINUTE; i++) {
            service.searchHosts("王五" + i, "10.0.0.8");
        }

        ApiException limited = assertThrows(ApiException.class, () -> service.searchHosts("王五x", "10.0.0.8"));

        assertEquals(ErrorCode.RATE_LIMITED, limited.getCode());
        verify(eligibility, times(VisitorDirectoryRateLimiter.PER_ACCOUNT_PER_MINUTE))
                .searchByNamePrefix(anyString(), anyInt());
        verify(audit).logExplicit(eq(visitorId), eq("V0001"), eq(VisitorDirectoryService.AUDIT_ACTION_LIMITED),
                eq("visitor_directory"), isNull(), contains("王五x"));
    }

    @Test
    void oneAddressCannotRotateAccountsPastThePerAddressLimit() {
        VisitorDirectoryRateLimiter limiter = new VisitorDirectoryRateLimiter();
        for (int i = 0; i < VisitorDirectoryRateLimiter.PER_IP_PER_MINUTE; i++) {
            limiter.check(UUID.randomUUID(), "203.0.113.9");
        }

        ApiException limited = assertThrows(ApiException.class,
                () -> limiter.check(UUID.randomUUID(), "203.0.113.9"));

        assertEquals(ErrorCode.RATE_LIMITED, limited.getCode());
        verify(audit, never()).logExplicit(any(), any(), any(), any(), any(), any());
    }
}
