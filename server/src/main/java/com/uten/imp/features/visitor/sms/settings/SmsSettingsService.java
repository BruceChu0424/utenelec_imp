package com.uten.imp.features.visitor.sms.settings;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.visitor.sms.SmsGatewayFactory;
import com.uten.imp.features.visitor.sms.SmsGatewayRuntime;
import com.uten.imp.features.visitor.sms.SmsGatewaySettingsStore;
import com.uten.imp.features.visitor.sms.SmsEndpointPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecretCipher;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.time.OffsetDateTime;
import java.util.Optional;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class SmsSettingsService {
    private final SmsGatewaySettingsStore store;
    private final SmsGatewayRuntime runtime;
    private final SmsGatewayFactory factory;
    private final SecretCipher cipher;
    private final SecurityContextCurrentUser currentUser;
    private final JdbcTemplate jdbc;
    private final AuditService audit;
    public SmsSettingsService(SmsGatewaySettingsStore store,SmsGatewayRuntime runtime,SmsGatewayFactory factory,
            SecretCipher cipher,SecurityContextCurrentUser currentUser,JdbcTemplate jdbc,AuditService audit) {
        this.store=store;this.runtime=runtime;this.factory=factory;this.cipher=cipher;
        this.currentUser=currentUser;this.jdbc=jdbc;this.audit=audit;
    }
    public SmsSettingsDto.View current() { requireAdmin(false);return view(runtime.current()); }

    @Transactional
    public SmsSettingsDto.View save(SmsSettingsDto.Save request) {
        AuthUser actor=requireAdmin(true);
        Optional<SmsGatewaySettingsStore.Row> stored=store.lockCurrent();
        SmsGatewayRuntime.Snapshot before=runtime.resolve(stored);
        if(request==null||request.expectedRevision()==null||!request.expectedRevision().equals(before.revision()))
            throw new ApiException(ErrorCode.CONFLICT,"短信配置已变化，请刷新后重新填写并确认。");
        long next=Math.addExact(before.version(),1);
        SmsGatewaySettingsStore.Row row;
        if(request.useEnvironment()) {
            if(request.clearCredentials()||SmsGatewayRuntime.blank(request.accessKeyId())!=null||SmsGatewayRuntime.blank(request.accessKeySecret())!=null)
                throw invalid("恢复部署配置时不能同时更换或清除凭据。");
            // Keep the row and monotonic version. Never resurrect an earlier override
            // by deleting the singleton and accepting a stale version-zero form.
            row=new SmsGatewaySettingsStore.Row(next,"ENV","DISABLED",null,null,null,null,null,null,OffsetDateTime.now(),actor.getId());
        } else {
            String provider=SmsGatewayRuntime.normalized(request.provider());
            if(!java.util.Set.of("DISABLED","ALIYUN","LOG").contains(provider)||"LOG".equals(provider)&&!runtime.permitsLog())
                throw invalid("此环境不允许所选短信服务商。");
            String endpoint=SmsEndpointPolicy.normalize(request.endpoint());
            if(endpoint!=null&&!SmsEndpointPolicy.allowed(endpoint)||"ALIYUN".equals(provider)&&endpoint==null)
                throw invalid("请选择阿里云公布的短信服务地址，不能使用自定义域名、OSS Bucket、网址或端口。");
            String sign=text(request.signName(),64),template=text(request.templateCode(),64);
            String id=credential(request.accessKeyId()),secret=credential(request.accessKeySecret());
            if((id==null)!=(secret==null))throw invalid("更换短信凭据时须同时填写 AccessKey ID 和 Secret。");
            if(request.clearCredentials()&&id!=null)throw invalid("不能同时填写新凭据并清除凭据。");
            if(!java.util.Objects.equals(endpoint,SmsEndpointPolicy.normalize(before.endpoint()))&&before.accessKeyConfigured()&&id==null&&!request.clearCredentials())
                throw invalid("更换短信服务地址时须重新填写凭据，或清除凭据并停用短信。");
            boolean replacement=id!=null;
            if(request.clearCredentials()) { id=null;secret=null; }
            else if(!replacement) {
                if(before.secretUnreadable())throw invalid("已存凭据无法解密，请重新填写两项凭据或明确清除。");
                id=before.accessKeyId();secret=before.accessKeySecret();
            }
            if("ALIYUN".equals(provider)&&(id==null||secret==null||sign==null||template==null))
                throw invalid("启用阿里云短信前须填写签名、模板和完整凭据。");
            if(template!=null&&!template.matches("SMS_[A-Za-z0-9_]{1,59}"))throw invalid("短信验证码模板编号应以 SMS_ 开头。");
            String idCipher=null,secretCipher=null;
            if(id!=null) {
                if(!cipher.available())throw invalid("服务器尚未配置第三方凭据加密，请先完成服务器密钥初始化。");
                // Explicit save may preserve effective ENV credentials, but startup
                // and reads never silently copy environment secrets into the database.
                if(!replacement&&stored.isPresent()&&"OVERRIDE".equals(stored.get().mode())) {
                    idCipher=stored.get().accessKeyIdCipher();secretCipher=stored.get().accessKeySecretCipher();
                } else {
                    idCipher=cipher.encrypt(id,SmsGatewaySettingsStore.idAad());
                    secretCipher=cipher.encrypt(secret,SmsGatewaySettingsStore.secretAad());
                }
            }
            row=new SmsGatewaySettingsStore.Row(next,"OVERRIDE",provider,endpoint,sign,template,idCipher,secretCipher,
                    SmsGatewayRuntime.hint(id),OffsetDateTime.now(),actor.getId());
        }
        SmsGatewayRuntime.Snapshot candidate=runtime.resolve(Optional.of(row));
        if("INVALID".equals(candidate.status())||"KEY_UNREADABLE".equals(candidate.status()))throw invalid(candidate.detail());
        try { factory.create(candidate); }
        catch(RuntimeException failed) { throw invalid("短信客户端配置未通过本机校验，请核对填写内容。"); }
        if(!store.save(row,before.version(),stored.isPresent()))throw new ApiException(ErrorCode.CONFLICT,"短信配置已变化，请刷新后重试。");
        audit.logCommitted(actor.getId(),actor.getLoginAccount(),"sms_settings.update","sms_gateway_settings",
                SmsGatewaySettingsStore.ID.toString(),"success");
        return view(candidate);
    }
    private AuthUser requireAdmin(boolean write) {
        AuthUser actor=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(actor.isVisitor()||actor.isMustChangePassword()||actor.getImpersonatedBy()!=null
                ||!actor.isSuperAdmin()||!actor.getPermissions().contains("authorization:manage"))throw new ApiException(ErrorCode.FORBIDDEN);
        // Lock the authoritative account through commit; a stale JWT cannot save
        // configuration after this account has been disabled or demoted.
        var allowed=jdbc.query("""
                SELECT id FROM users WHERE id=? AND is_super_admin AND NOT is_deleted
                    AND status='active' AND NOT must_change_password
                """+(write?" FOR SHARE":""),(rs,n)->rs.getObject(1,java.util.UUID.class),actor.getId());
        if(allowed.isEmpty())throw new ApiException(ErrorCode.FORBIDDEN);
        return actor;
    }
    private SmsSettingsDto.View view(SmsGatewayRuntime.Snapshot value) {
        return new SmsSettingsDto.View(value.revision(),value.version(),value.source(),value.provider(),value.effectiveProvider(),
                value.endpoint(),value.signName(),value.templateCode(),value.accessKeyConfigured(),value.accessKeyIdHint(),value.secretUnreadable(),
                new SmsSettingsDto.Capabilities(true,runtime.permitsLog(),value.developmentCodeAllowed()),value.status(),value.detail(),"NEXT_ISSUANCE",SmsEndpointPolicy.ALLOWED);
    }
    private static String credential(String value) {
        String text=SmsGatewayRuntime.blank(value);
        if(text!=null&&(text.length()>256||!text.matches("[!-~]+")))throw invalid("短信凭据格式不正确。");
        return text;
    }
    private static String text(String value,int max) {
        String text=SmsGatewayRuntime.blank(value);
        if(text!=null&&(text.length()>max||text.chars().anyMatch(Character::isISOControl)))throw invalid("短信签名或模板格式不正确。");
        return text;
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED,message); }
}
