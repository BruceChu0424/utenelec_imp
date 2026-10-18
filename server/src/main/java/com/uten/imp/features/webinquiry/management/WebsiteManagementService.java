package com.uten.imp.features.webinquiry.management;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Pattern;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.time.Clock;
import java.time.Instant;
import java.sql.Timestamp;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.Map;
import java.util.LinkedHashMap;

@Service
@RequiredArgsConstructor
public class WebsiteManagementService {
    public static final String ENTRY_PATH="/admin/imp-entry";
    private static final Set<String> WEB_PERMISSIONS=com.uten.imp.application.port.WebsiteActorAuthorityPort.WEBSITE_PERMISSIONS;
    private static final Set<String> SECTIONS=Set.of("overview","home","products","resources","news","settings","releases");
    private final JdbcTemplate jdbc;
    private final WebsiteBridgeClient bridge;
    private final SecurityContextCurrentUser current;
    private final AuditService audit;
    private final Clock clock;

    public record Config(long version,String displayName,String publicOrigin,boolean enabled){}
    public record ConfigUpdate(@Min(0) long expectedVersion,@NotBlank @Size(max=80) String displayName,
                               @Size(max=300) String publicOrigin,boolean enabled){}
    public record OpenRequest(@NotBlank String section,@NotBlank @Pattern(regexp="[A-Za-z0-9_-]{43}") String codeChallenge){}
    public record OpenResult(String entryUrl,String code,Instant expiresAt){}
    public record Status(Instant checkedAt,boolean reachable,boolean ready,String siteId,String publishedRevision,
                         Integer pendingInquiries,Instant oldestPendingAt,Instant lastDeliveryAt,String message){}

    public Config config(){
        return jdbc.queryForObject("SELECT version,display_name,public_origin,enabled FROM website_management_settings WHERE id=1",
                (rs,n)->new Config(rs.getLong(1),rs.getString(2),rs.getString(3),rs.getBoolean(4)));
    }
    public Map<String,Object> current(){
        var actor=requireStaff();Config c=config();boolean admin=canConfigure(actor);
        Map<String,Object> result=new LinkedHashMap<>();
        result.put("version",c.version());result.put("displayName",c.displayName());result.put("publicOrigin",c.publicOrigin());
        result.put("adminOrigin",c.publicOrigin());result.put("adminEntryPath",ENTRY_PATH);
        result.put("enabled",c.enabled());result.put("configured",bridge.configured(c.publicOrigin()));
        result.put("tokenConfigured",bridge.tokenConfigured());result.put("siteId",bridge.siteId());
        result.put("canConfigure",admin);result.put("allowedOrigins",admin?bridge.allowedOrigins():List.of());
        result.put("permissions",actor.getPermissions().stream().filter(WEB_PERMISSIONS::contains).sorted().toList());
        jdbc.query("SELECT * FROM website_bridge_status WHERE id=1",rs->{
            result.put("lastCheckedAt",instant(rs.getTimestamp("last_checked_at")));
            result.put("lastSyncAt",instant(rs.getTimestamp("last_sync_at")));
            result.put("lastError",rs.getString("last_error"));result.put("pendingInquiries",rs.getObject("pending_inquiries"));
            result.put("oldestPendingAt",instant(rs.getTimestamp("oldest_pending_at")));
            result.put("lastDeliveryAt",instant(rs.getTimestamp("last_delivery_at")));
            result.put("publishedRevision",rs.getString("published_revision"));result.put("ready",rs.getBoolean("ready"));
        });
        return result;
    }
    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin and !principal.visitor")
    public Map<String,Object> update(ConfigUpdate request){
        var actor=requireStaff();if(!canConfigure(actor))throw new ApiException(ErrorCode.FORBIDDEN);
        String origin=request.publicOrigin()==null || request.publicOrigin().isBlank()?null:bridge.validateOrigin(request.publicOrigin().trim());
        if(request.enabled() && !bridge.configured(origin))throw new ApiException(ErrorCode.VALIDATION_FAILED,"启用前须配置受信官网地址与服务器服务身份");
        int changed=jdbc.update("""
                UPDATE website_management_settings SET display_name=?,public_origin=?,enabled=?,version=version+1,
                updated_at=now(),updated_by=? WHERE id=1 AND version=?
                """,request.displayName().trim(),origin,request.enabled(),actor.getId(),request.expectedVersion());
        if(changed!=1)throw new ApiException(ErrorCode.CONFLICT,"官网连接配置已变更，请刷新后重试");
        jdbc.update("UPDATE website_bridge_status SET ready=false,last_error=NULL,last_checked_at=NULL,pending_inquiries=NULL,published_revision=NULL WHERE id=1");
        audit.logCommittedChange(actor.getId(),actor.getLoginAccount(),"website_config_update","website_management_settings","1","success",
                Map.of("enabled",request.enabled(),"version",request.expectedVersion()+1,"originConfigured",origin!=null));
        return current();
    }
    public Status check(){
        requireStaff();Config c=config();Instant now=clock.instant();
        if(!c.enabled() || !bridge.configured(c.publicOrigin()))
            return new Status(now,false,false,bridge.siteId(),null,null,null,null,"官网连接尚未启用或服务身份未配置");
        try {
            JsonNode value=bridge.get(c.publicOrigin(),"/api/imp/bridge/status");
            if(!bridge.siteId().equals(value.path("siteId").asText()))throw new ApiException(ErrorCode.BUSINESS,"官网站点身份不匹配");
            boolean ready=value.path("ready").asBoolean(false);
            Integer pending=value.path("pendingInquiries").isIntegralNumber()?value.path("pendingInquiries").intValue():null;
            String revision=value.path("publishedRevision").isNull()?null:value.path("publishedRevision").asText(null);
            if(pending!=null && pending<0 || revision!=null && revision.length()>120)throw new ApiException(ErrorCode.BUSINESS,"官网状态响应格式不正确");
            Instant oldest=parseInstant(value,"oldestPendingAt"),delivered=parseInstant(value,"lastDeliveryAt");
            int saved=jdbc.update("""
                    UPDATE website_bridge_status SET last_checked_at=?,ready=?,last_error=NULL,pending_inquiries=?,
                    oldest_pending_at=?,last_delivery_at=?,published_revision=? WHERE id=1
                    AND EXISTS(SELECT 1 FROM website_management_settings WHERE id=1 AND version=?)
                    """,Timestamp.from(now),ready,pending,timestamp(oldest),timestamp(delivered),revision,c.version());
            if(saved!=1)return new Status(now,false,false,bridge.siteId(),null,null,null,null,"官网连接配置已变化，请重新检查");
            return new Status(now,true,ready,bridge.siteId(),revision,pending,oldest,delivered,ready?"官网服务与管理接口就绪":"官网已响应，部分服务尚未就绪");
        }catch(ApiException error){
            jdbc.update("""
                    UPDATE website_bridge_status SET last_checked_at=?,ready=false,last_error=? WHERE id=1
                    AND EXISTS(SELECT 1 FROM website_management_settings WHERE id=1 AND version=?)
                    """,Timestamp.from(now),error.getMessage(),c.version());
            return new Status(now,false,false,bridge.siteId(),null,null,null,null,error.getMessage());
        }
    }
    public OpenResult open(OpenRequest request){
        var actor=requireStaff();Config c=config();
        if(actor.getSessionId()==null)throw new ApiException(ErrorCode.UNAUTHORIZED,"当前登录会话不可用于官网授权，请重新登录");
        if(!SECTIONS.contains(request.section()) || request.codeChallenge()==null || !request.codeChallenge().matches("[A-Za-z0-9_-]{43}"))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"官网栏目或登录校验信息不正确");
        if(!c.enabled() || !bridge.configured(c.publicOrigin()))throw new ApiException(ErrorCode.BUSINESS,"官网连接尚未启用");
        Instant lease=clock.instant().plusSeconds(300);
        Map<String,Object> payload=new LinkedHashMap<>();
        payload.put("requestId",UUID.randomUUID().toString());payload.put("actorId",actor.getId().toString());
        payload.put("authSessionId",actor.getSessionId().toString());
        payload.put("employeeId",actor.getEmployeeId()==null?null:actor.getEmployeeId().toString());
        payload.put("displayName",actor.getLoginAccount());payload.put("permissions",actor.getPermissions().stream().filter(WEB_PERMISSIONS::contains).sorted().toList());
        payload.put("section",request.section());payload.put("expiresAt",lease.toString());payload.put("codeChallenge",request.codeChallenge());
        JsonNode result=bridge.post(c.publicOrigin(),"/api/imp/bridge/authorizations",payload);
        String code=result.path("code").asText("");Instant expiry=parseInstant(result,"expiresAt");
        if(!code.matches("[A-Za-z0-9_-]{32,160}") || expiry==null || !expiry.isAfter(clock.instant()) || expiry.isAfter(clock.instant().plusSeconds(65)))
            throw new ApiException(ErrorCode.BUSINESS,"官网登录授权回执不符合约定，请重新进入");
        if(!c.equals(config()))throw new ApiException(ErrorCode.CONFLICT,"官网连接配置已变更，请重新进入管理后台");
        // Do not include a code, challenge, token, or URL fragment in audit.
        audit.logExplicit(actor.getId(),actor.getLoginAccount(),"website_management_open","website_management",request.section(),"success");
        return new OpenResult(c.publicOrigin()+ENTRY_PATH,code,expiry);
    }
    void recordFailure(String message){jdbc.update("UPDATE website_bridge_status SET last_error=? WHERE id=1",message==null?"官网同步失败":message.substring(0,Math.min(240,message.length())));}
    void recordSync(){jdbc.update("UPDATE website_bridge_status SET last_sync_at=now(),last_error=NULL WHERE id=1");}
    private AuthUser requireStaff(){
        return current.get().filter(a->!a.isVisitor() && !a.isMustChangePassword() && a.getImpersonatedBy()==null
                && a.getPermissions().contains("website:view")).orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN));
    }
    private boolean canConfigure(AuthUser a){return a.isSuperAdmin() && a.getPermissions().contains("authorization:manage");}
    private static Instant instant(Timestamp t){return t==null?null:t.toInstant();}
    private static Timestamp timestamp(Instant t){return t==null?null:Timestamp.from(t);}
    private static Instant parseInstant(JsonNode value,String field){
        if(value.path(field).isMissingNode() || value.path(field).isNull())return null;
        try{return Instant.parse(value.path(field).asText());}catch(RuntimeException invalid){throw new ApiException(ErrorCode.BUSINESS,"官网时间响应格式不正确");}
    }
}
