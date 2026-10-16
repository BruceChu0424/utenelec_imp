package com.uten.imp.features.visitor.sms;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.uten.imp.config.props.SmsProperties;
import com.uten.imp.security.SecretCipher;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Optional;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Service;

/** Resolves a complete snapshot; a bad override never silently falls back to old credentials. */
@Service
public class SmsGatewayRuntime {
    private final SmsGatewaySettingsStore store;
    private final SmsProperties environment;
    private final SecretCipher cipher;
    private final Environment profiles;
    public SmsGatewayRuntime(SmsGatewaySettingsStore store, SmsProperties environment, SecretCipher cipher, Environment profiles) {
        this.store=store; this.environment=environment; this.cipher=cipher; this.profiles=profiles;
    }
    public record Snapshot(String revision,long version,String source,String provider,String effectiveProvider,
                           String endpoint,String signName,String templateCode,
                           @JsonIgnore String accessKeyId,@JsonIgnore String accessKeySecret,
                           boolean accessKeyConfigured,String accessKeyIdHint,boolean secretUnreadable,
                           String status,String detail,boolean developmentCodeAllowed) {
        @Override public String toString() { return "SmsSnapshot[version="+version+",source="+source+",provider="+provider+",status="+status+"]"; }
    }
    public Snapshot current() { return resolve(store.current()); }
    public boolean permitsLog() {
        return profiles.acceptsProfiles(Profiles.of("dev")) && !profiles.acceptsProfiles(Profiles.of("prod","cloud","internal-test"));
    }
    public Snapshot resolve(Optional<SmsGatewaySettingsStore.Row> stored) {
        var row=stored.orElse(null);
        boolean override=row!=null && "OVERRIDE".equals(row.mode());
        String source=override?"DATABASE":"ENV";
        String provider=normalized(override?row.provider():environment.getProvider());
        String endpoint=override?row.endpoint():environment.getEndpoint();
        String sign=override?row.signName():environment.getSignName();
        String template=override?row.templateCode():environment.getTemplateCode();
        String id=override?null:blank(environment.getAccessKeyId());
        String secret=override?null:blank(environment.getAccessKeySecret());
        boolean unreadable=false;
        boolean configured=override?row.accessKeyIdCipher()!=null && row.accessKeySecretCipher()!=null:id!=null&&secret!=null;
        if(override&&configured) {
            try { id=cipher.decrypt(row.accessKeyIdCipher(),SmsGatewaySettingsStore.idAad()); secret=cipher.decrypt(row.accessKeySecretCipher(),SmsGatewaySettingsStore.secretAad()); }
            catch(SecretCipher.SecretUnreadableException failure) { unreadable=true; }
        }
        String status="READY",detail="配置从下一次验证码签发起生效；尚未验证供应商账户可用性。",effective=provider;
        if(profiles.acceptsProfiles(Profiles.of("internal-test"))) {
            // Existing InternalTestRuntimeSafetyGate:100-101 forbids real SMS and exposed codes.
            status="BLOCKED";effective="DISABLED";detail="专用隔离测试运行环境按已有安全策略禁用短信发送。";
        } else if("LOG".equals(provider)&&!permitsLog()) {
            status="BLOCKED";effective="DISABLED";detail="此运行环境禁止模拟短信和验证码回显。";
        } else if(!java.util.Set.of("DISABLED","LOG","ALIYUN").contains(provider)) {
            status="INVALID";effective="DISABLED";detail="短信服务商配置无效，请由超级管理员修正。";
        } else if("DISABLED".equals(provider)) {
            status="DISABLED";detail="短信发送已停用。";
        } else if(unreadable) {
            status="KEY_UNREADABLE";effective="DISABLED";detail="已存短信凭据无法解密，请重新填写凭据。";
        } else if("ALIYUN".equals(provider)&&(!configured||blank(sign)==null||blank(template)==null||blank(endpoint)==null)) {
            status="INVALID";effective="DISABLED";detail="阿里云短信配置尚不完整。";
        } else if("ALIYUN".equals(provider)&&!SmsEndpointPolicy.allowed(SmsEndpointPolicy.normalize(endpoint))) {
            // Deployment fallback is preserved verbatim for correction, but cannot
            // bypass the same destination boundary enforced for UI overrides.
            status="INVALID";effective="DISABLED";detail="短信服务地址不在阿里云官方服务列表内，请由超级管理员在短信设置中修正。";
        }
        long version=row==null?0:row.version();
        boolean expose="LOG".equals(effective)&&permitsLog()&&environment.isExposeCode();
        String fingerprint=version+"|"+source+"|"+provider+"|"+endpoint+"|"+sign+"|"+template+"|"
                +(override?row.accessKeyIdCipher():id)+"|"+(override?row.accessKeySecretCipher():secret)+"|"
                +effective+"|"+status+"|"+unreadable+"|"+expose;
        return new Snapshot(hash(fingerprint),version,source,provider,effective,endpoint,sign,template,id,secret,configured,
                override?row.accessKeyIdHint():hint(id),unreadable,status,detail,expose);
    }
    public static String hint(String value) { return value==null?null:value.length()>=12?"****"+value.substring(value.length()-4):"已配置"; }
    public static String blank(String value) { return value==null||value.isBlank()?null:value.trim(); }
    public static String normalized(String provider) { return provider==null?"DISABLED":provider.trim().toUpperCase(Locale.ROOT); }
    private static String hash(String value) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8))); }
        catch(java.security.NoSuchAlgorithmException impossible) { throw new IllegalStateException("Digest unavailable"); }
    }
}
