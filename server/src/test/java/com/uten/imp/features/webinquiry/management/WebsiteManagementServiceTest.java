package com.uten.imp.features.webinquiry.management;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class WebsiteManagementServiceTest {
    private final JdbcTemplate jdbc=mock(JdbcTemplate.class);
    private final WebsiteBridgeClient bridge=mock(WebsiteBridgeClient.class);
    private final SecurityContextCurrentUser current=mock(SecurityContextCurrentUser.class);
    private final AuditService audit=mock(AuditService.class);
    private final Instant now=Instant.parse("2026-10-17T12:00:00Z");
    private WebsiteManagementService service;
    @BeforeEach @SuppressWarnings("unchecked") void setup(){
        service=new WebsiteManagementService(jdbc,bridge,current,audit,Clock.fixed(now,ZoneOffset.UTC));
        when(jdbc.queryForObject(anyString(),any(RowMapper.class))).thenReturn(new WebsiteManagementService.Config(1,"官网","https://site.example",true));
        when(bridge.configured("https://site.example")).thenReturn(true);
        when(current.get()).thenReturn(Optional.of(actor(false,Set.of("website:view","website:content_edit","goods:edit"))));
    }
    private AuthUser actor(boolean admin,Set<String> permissions){
        return new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"editor",permissions,false,true,admin,false,null,UUID.randomUUID());
    }
    @Test void ssoUsesFixedEntryAndLeastPrivilegeServerBackchannel() throws Exception {
        String code="a".repeat(43);
        when(bridge.post(eq("https://site.example"),eq("/api/imp/bridge/authorizations"),any())).thenReturn(
                new ObjectMapper().createObjectNode().put("code",code).put("expiresAt",now.plusSeconds(60).toString()));
        var result=service.open(new WebsiteManagementService.OpenRequest("home","b".repeat(43)));
        assertThat(result.entryUrl()).isEqualTo("https://site.example/admin/imp-entry");
        assertThat(result.code()).isEqualTo(code);
        verify(bridge).post(anyString(),anyString(),argThat(payload->{
            var map=(Map<?,?>)payload;
            return map.get("permissions").equals(List.of("website:content_edit","website:view"))
                    && map.get("expiresAt").equals(now.plusSeconds(300).toString())
                    && map.get("authSessionId").equals(current.get().orElseThrow().getSessionId().toString());
        }));
        verify(audit).logExplicit(any(),eq("editor"),eq("website_management_open"),eq("website_management"),eq("home"),eq("success"));
    }
    @Test void rejectsInvalidChallengesArbitrarySectionAndUnexpectedCodeExpiry() throws Exception {
        assertThatThrownBy(()->service.open(new WebsiteManagementService.OpenRequest("//evil.test","b".repeat(43)))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.open(new WebsiteManagementService.OpenRequest("home","raw-verifier"))).isInstanceOf(ApiException.class);
        when(bridge.post(anyString(),anyString(),any())).thenReturn(new ObjectMapper().createObjectNode()
                .put("code","a".repeat(43)).put("expiresAt",now.plusSeconds(600).toString()));
        assertThatThrownBy(()->service.open(new WebsiteManagementService.OpenRequest("home","b".repeat(43)))).isInstanceOf(ApiException.class);
        verifyNoInteractions(audit);
    }
    @Test void onlySuperAdminCanChangeConfigurationAndStaleVersionConflicts(){
        var update=new WebsiteManagementService.ConfigUpdate(1,"官网",null,false);
        assertThatThrownBy(()->service.update(update)).isInstanceOf(ApiException.class);
        when(current.get()).thenReturn(Optional.of(actor(true,Set.of("website:view","authorization:manage"))));
        assertThatThrownBy(()->service.update(update)).isInstanceOf(ApiException.class).hasMessageContaining("已变更");
        verifyNoInteractions(audit);
    }

    @Test void staleConnectivityResponseCannotMarkAChangedConfigurationReady(){
        when(bridge.siteId()).thenReturn("uten");
        when(bridge.get("https://site.example","/api/imp/bridge/status")).thenReturn(
                new ObjectMapper().createObjectNode().put("siteId","uten").put("ready",true).put("pendingInquiries",0));
        // Atomic version predicate no longer matches after a concurrent configuration edit.
        var response=service.check();
        assertThat(response.ready()).isFalse();
        assertThat(response.message()).contains("配置已变化");
    }

    @Test void cannotRegisterPortalAuthorizationWithoutOriginalServerSession(){
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"legacy",
                Set.of("website:view"),false,true,false)));
        assertThatThrownBy(()->service.open(new WebsiteManagementService.OpenRequest("home","b".repeat(43))))
                .isInstanceOf(ApiException.class).hasMessageContaining("登录会话");
        verifyNoInteractions(bridge,audit);
    }

    @Test void inquiryReadScopeIsForwardedOnlyWhenTheCurrentEmployeeActuallyHasIt() throws Exception {
        when(bridge.post(anyString(),anyString(),any())).thenReturn(new ObjectMapper().createObjectNode()
                .put("code","a".repeat(43)).put("expiresAt",now.plusSeconds(60).toString()));
        when(current.get()).thenReturn(Optional.of(actor(false,Set.of("website:view","website:media_manage"))));
        service.open(new WebsiteManagementService.OpenRequest("overview","b".repeat(43)));
        when(current.get()).thenReturn(Optional.of(actor(false,Set.of("website:view","webinquiry:view","webinquiry:claim"))));
        service.open(new WebsiteManagementService.OpenRequest("overview","b".repeat(43)));
        var payload=org.mockito.ArgumentCaptor.forClass(Object.class);
        verify(bridge,times(2)).post(anyString(),anyString(),payload.capture());
        assertThat(((Map<?,?>)payload.getAllValues().get(0)).get("permissions")).isEqualTo(List.of("website:media_manage","website:view"));
        assertThat(((Map<?,?>)payload.getAllValues().get(1)).get("permissions")).isEqualTo(List.of("webinquiry:view","website:view"));
    }
}
