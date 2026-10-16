package com.uten.imp.features.visitor.sms;

import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.config.props.SmsProperties;
import com.uten.imp.security.SecretCipher;
import com.uten.imp.security.SecretCipherProperties;
import java.time.OffsetDateTime;
import java.util.Map;

/** Non-provider fixture credentials only; no test in this group sends SMS. */
public final class SmsRuntimeTestSupport {
    public static final String ID="fixtureAK00000000000001", SECRET="fixture-secret-000000000000001";
    private SmsRuntimeTestSupport() {}
    public static SecretCipher cipher(String version) {
        var props=new SecretCipherProperties();
        props.setSecretCipherKey("fixture-secret-cipher-key-"+version+"-01234567890123456789");
        props.setSecretCipherKeyVersion(version);
        if("2".equals(version))props.setSecretCipherLegacyKeys(Map.of("1","fixture-secret-cipher-key-1-01234567890123456789"));
        var crypto=new CryptoProperties();crypto.setHmacKey("fixture-hmac-012345678901234567890123456789");
        var jwt=new JwtProperties();jwt.setIssuer("fixture-company-sms");
        return new SecretCipher(props,crypto,jwt);
    }
    public static SmsProperties environment() {
        var props=new SmsProperties();props.setProvider("aliyun");props.setAccessKeyId(ID);props.setAccessKeySecret(SECRET);
        props.setSignName("测试签名");props.setTemplateCode("SMS_FIXTURE");return props;
    }
    public static SmsGatewaySettingsStore.Row row(SecretCipher cipher,long version,String provider) {
        return new SmsGatewaySettingsStore.Row(version,"OVERRIDE",provider,"dysmsapi.aliyuncs.com","测试签名","SMS_FIXTURE",
                cipher.encrypt(ID,SmsGatewaySettingsStore.idAad()),cipher.encrypt(SECRET,SmsGatewaySettingsStore.secretAad()),
                SmsGatewayRuntime.hint(ID),OffsetDateTime.now(),null);
    }
}
