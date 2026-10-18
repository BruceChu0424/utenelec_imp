package com.uten.imp.features.webinquiry.management;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.WebsiteActorAuthorityPort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import java.time.Clock;
import java.util.*;

/** Outbound-only reauthorization. Website storage remains the lease/revocation authority. */
@Service
@RequiredArgsConstructor
public class WebsitePortalLeaseRenewal {
    private static final int MAX_PAGES=100;
    private final WebsiteBridgeClient bridge;
    private final WebsiteManagementService management;
    private final WebsiteActorAuthorityPort actors;
    private final Clock clock;

    public boolean renew(WebsiteManagementService.Config expected){
        if(!expected.enabled() || !bridge.configured(expected.publicOrigin()))return false;
        String after=null;
        Set<String> cursors=new HashSet<>();
        boolean complete=true;
        for(int page=0;page<MAX_PAGES;page++){
            if(!expected.equals(management.config()))return false;
            JsonNode response=bridge.get(expected.publicOrigin(),sessionsPath(after));
            JsonNode items=response.path("items");
            if(!items.isArray() || items.size()>100)return false;
            Map<String,Optional<Set<String>>> permissions=new HashMap<>();
            List<Map<String,Object>> updates=new ArrayList<>();
            Set<String> sessions=new HashSet<>();
            for(JsonNode item:items){
                String session=item.path("sessionId").asText(""),actor=item.path("actorId").asText("");
                String authSession=item.path("authSessionId").asText("");
                if(!safeId(session) || actor.isBlank() || actor.length()>128 || !sessions.add(session)){
                    complete=false;continue;
                }
                String identity=actor+"|"+authSession;
                Optional<Set<String>> resolved=permissions.get(identity);
                if(resolved==null){
                    try{
                        UUID id=parseUuid(actor),sid=parseUuid(authSession);
                        Set<String> current=id==null || sid==null?Set.of():actors.currentPermissions(id,sid);
                        resolved=Optional.of(current==null?Set.of():current);
                    }catch(RuntimeException unavailable){resolved=Optional.empty();complete=false;}
                    permissions.put(identity,resolved);
                }
                // Failed account/permission reads never grant or fake a renewed lease.
                if(resolved.isEmpty())continue;
                Set<String> granted=resolved.get();
                boolean revoke=!granted.contains("website:view");
                Map<String,Object> update=new LinkedHashMap<>();
                update.put("sessionId",session);update.put("actorId",actor);
                update.put("permissions",revoke?List.of():granted.stream()
                        .filter(WebsiteActorAuthorityPort.WEBSITE_PERMISSIONS::contains).sorted().toList());
                update.put("expiresAt",clock.instant().plusSeconds(revoke?0:300).toString());
                update.put("revoked",revoke);updates.add(update);
            }
            if(!updates.isEmpty()){
                if(!expected.equals(management.config()))return false;
                try{
                    JsonNode receipt=bridge.post(expected.publicOrigin(),"/api/imp/bridge/sessions/renew",Map.of("items",updates));
                    if(!confirmed(receipt,updates.size()))complete=false;
                }catch(RuntimeException failure){complete=false;}
            }
            JsonNode next=response.path("nextCursor");
            if(next.isNull() || next.isMissingNode())return complete;
            String cursor=next.asText("");
            if(!safeId(cursor) || !cursors.add(cursor))return false;
            after=cursor;
        }
        return false;
    }

    static String sessionsPath(String after){
        if(after==null)return "/api/imp/bridge/sessions?limit=100";
        if(!safeId(after))throw new IllegalArgumentException("Invalid session cursor");
        return "/api/imp/bridge/sessions?after="+after+"&limit=100";
    }
    private static boolean safeId(String value){return value.matches("[A-Za-z0-9_-]{1,128}");}
    private static UUID parseUuid(String value){try{return UUID.fromString(value);}catch(IllegalArgumentException invalid){return null;}}
    private static boolean confirmed(JsonNode receipt,int expected){
        long total=0;
        for(String field:List.of("renewed","revoked","ignored")){
            JsonNode count=receipt.path(field);
            if(!count.isIntegralNumber() || !count.canConvertToInt() || count.intValue()<0)return false;
            total+=count.intValue();
        }
        // Ignored expired/revoked identities are not revived; no local success state is invented.
        return total==expected;
    }
}
