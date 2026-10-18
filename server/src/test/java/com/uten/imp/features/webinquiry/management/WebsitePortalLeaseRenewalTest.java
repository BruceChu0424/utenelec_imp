package com.uten.imp.features.webinquiry.management;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.WebsiteActorAuthorityPort;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class WebsitePortalLeaseRenewalTest {
    private final ObjectMapper json=new ObjectMapper();
    private final WebsiteBridgeClient bridge=mock(WebsiteBridgeClient.class);
    private final WebsiteManagementService management=mock(WebsiteManagementService.class);
    private final WebsiteActorAuthorityPort actors=mock(WebsiteActorAuthorityPort.class);
    private final Instant now=Instant.parse("2026-10-17T12:00:00Z");
    private final Map<UUID,UUID> originSessions=new HashMap<>();
    private final WebsiteManagementService.Config config=new WebsiteManagementService.Config(2,"官网","https://site.example",true);
    private WebsitePortalLeaseRenewal service(){
        when(bridge.configured(config.publicOrigin())).thenReturn(true);
        when(management.config()).thenReturn(config);
        return new WebsitePortalLeaseRenewal(bridge,management,actors,Clock.fixed(now,ZoneOffset.UTC));
    }
    private UUID authSession(UUID actor){return originSessions.computeIfAbsent(actor,ignored->UUID.randomUUID());}
    private ObjectNode session(String session,UUID actor){return json.createObjectNode().put("sessionId",session).put("actorId",actor.toString()).put("authSessionId",authSession(actor).toString());}
    private ObjectNode receipt(int renewed,int revoked,int ignored){return json.createObjectNode().put("renewed",renewed).put("revoked",revoked).put("ignored",ignored);}

    @Test void refreshesOnlyCurrentWebsiteAuthorityAndRevokesUnknownOrRemovedActors(){
        var service=service();UUID active=UUID.randomUUID(),removed=UUID.randomUUID(),unknown=UUID.randomUUID();
        var page=json.createObjectNode();page.set("items",json.createArrayNode()
                .add(session("s-active",active)).add(session("s-removed",removed)).add(session("s-unknown",unknown)));page.putNull("nextCursor");
        when(bridge.get(anyString(),anyString())).thenReturn(page);
        when(actors.currentPermissions(active,authSession(active))).thenReturn(Set.of("website:view","website:content_edit","webinquiry:view","webinquiry:claim","goods:edit"));
        when(actors.currentPermissions(removed,authSession(removed))).thenReturn(Set.of("website:content_edit"));
        when(actors.currentPermissions(unknown,authSession(unknown))).thenReturn(Set.of());
        when(bridge.post(anyString(),anyString(),any())).thenReturn(receipt(1,2,0));
        assertThat(service.renew(config)).isTrue();
        ArgumentCaptor<Object> payload=ArgumentCaptor.forClass(Object.class);
        verify(bridge).post(eq(config.publicOrigin()),eq("/api/imp/bridge/sessions/renew"),payload.capture());
        var items=(List<?>)((Map<?,?>)payload.getValue()).get("items");
        var first=(Map<?,?>)items.get(0);
        assertThat(first.get("permissions")).isEqualTo(List.of("webinquiry:view","website:content_edit","website:view"));
        assertThat(first.get("expiresAt")).isEqualTo(now.plusSeconds(300).toString());
        assertThat(first.get("revoked")).isEqualTo(false);
        for(int i=1;i<3;i++){var revoked=(Map<?,?>)items.get(i);assertThat(revoked.get("revoked")).isEqualTo(true);assertThat(revoked.get("permissions")).isEqualTo(List.of());}
    }

    @Test void failedFirstPageDoesNotFakeSuccessOrPreventLaterPagesRenewing(){
        var service=service();UUID actor=UUID.randomUUID();
        ObjectNode one=json.createObjectNode().put("nextCursor","cursor-one");
        one.set("items",json.createArrayNode().add(session("session-one",actor)));
        ObjectNode two=json.createObjectNode().putNull("nextCursor");two.set("items",json.createArrayNode().add(session("session-two",actor)));
        when(bridge.get(config.publicOrigin(),"/api/imp/bridge/sessions?limit=100")).thenReturn(one);
        when(bridge.get(config.publicOrigin(),"/api/imp/bridge/sessions?after=cursor-one&limit=100")).thenReturn(two);
        when(actors.currentPermissions(actor,authSession(actor))).thenReturn(Set.of("website:view"));
        when(bridge.post(anyString(),anyString(),any())).thenThrow(new IllegalStateException("transport failed")).thenReturn(receipt(1,0,0));
        assertThat(service.renew(config)).isFalse();
        verify(bridge,times(2)).post(anyString(),eq("/api/imp/bridge/sessions/renew"),any());
    }

    @Test void accountLookupFailureDoesNotGrantOrFakeLeaseButOtherActorsStillProgress(){
        var service=service();UUID failed=UUID.randomUUID(),ok=UUID.randomUUID();
        ObjectNode page=json.createObjectNode().putNull("nextCursor");
        page.set("items",json.createArrayNode().add(session("failed",failed)).add(session("ok",ok)));
        when(bridge.get(anyString(),anyString())).thenReturn(page);
        when(actors.currentPermissions(failed,authSession(failed))).thenThrow(new IllegalStateException("database unavailable"));
        when(actors.currentPermissions(ok,authSession(ok))).thenReturn(Set.of("website:view"));
        when(bridge.post(anyString(),anyString(),any())).thenReturn(receipt(1,0,0));
        assertThat(service.renew(config)).isFalse();
        verify(bridge).post(anyString(),anyString(),argThat(payload->{
            var items=(List<?>)((Map<?,?>)payload).get("items");
            return items.size()==1 && "ok".equals(((Map<?,?>)items.getFirst()).get("sessionId"));
        }));
    }

    @Test void changedConfigurationAndUnconfirmedReceiptsCannotRenewSilently(){
        var service=service();UUID actor=UUID.randomUUID();
        var page=json.createObjectNode().putNull("nextCursor");page.set("items",json.createArrayNode().add(session("one",actor)));
        when(bridge.get(anyString(),anyString())).thenReturn(page);
        when(actors.currentPermissions(actor,authSession(actor))).thenReturn(Set.of("website:view"));
        when(management.config()).thenReturn(config,new WebsiteManagementService.Config(3,"官网",config.publicOrigin(),false));
        assertThat(service.renew(config)).isFalse();verify(bridge,never()).post(anyString(),anyString(),any());
        when(management.config()).thenReturn(config);
        when(bridge.post(anyString(),anyString(),any())).thenReturn(json.createObjectNode().put("ok",true));
        assertThat(service.renew(config)).isFalse();
    }

    @Test void cursorCannotAlterRouteQueryOrTargetOrigin(){
        assertThat(WebsiteBridgeClient.allowedPath(WebsitePortalLeaseRenewal.sessionsPath("cm-session_01"))).isTrue();
        for(String path:List.of("/api/imp/bridge/sessions?after=x&limit=100&host=evil",
                "/api/imp/bridge/sessions?after=../auth&limit=100","/api/imp/bridge/sessions?after=%2f&limit=100"))
            assertThat(WebsiteBridgeClient.allowedPath(path)).isFalse();
        assertThatThrownBy(()->WebsitePortalLeaseRenewal.sessionsPath("a&other=1")).isInstanceOf(IllegalArgumentException.class);
    }

    @Test void missingOrRevokedOriginSessionCannotReuseAnotherSessionAuthority(){
        var service=service();UUID actor=UUID.randomUUID(),oldSid=UUID.randomUUID();
        ObjectNode legacy=session("legacy",actor);legacy.remove("authSessionId");
        ObjectNode page=json.createObjectNode().putNull("nextCursor");
        page.set("items",json.createArrayNode().add(session("active",actor))
                .add(session("old",actor).put("authSessionId",oldSid.toString())).add(legacy));
        when(bridge.get(anyString(),anyString())).thenReturn(page);
        when(actors.currentPermissions(actor,authSession(actor))).thenReturn(Set.of("website:view"));
        when(actors.currentPermissions(actor,oldSid)).thenReturn(Set.of());
        when(bridge.post(anyString(),anyString(),any())).thenReturn(receipt(1,2,0));
        assertThat(service.renew(config)).isTrue();
        verify(bridge).post(anyString(),anyString(),argThat(payload->{
            var items=(List<?>)((Map<?,?>)payload).get("items");
            return Boolean.FALSE.equals(((Map<?,?>)items.get(0)).get("revoked"))
                    && Boolean.TRUE.equals(((Map<?,?>)items.get(1)).get("revoked"))
                    && Boolean.TRUE.equals(((Map<?,?>)items.get(2)).get("revoked"));
        }));
        verify(actors).currentPermissions(actor,authSession(actor));verify(actors).currentPermissions(actor,oldSid);
    }
}
