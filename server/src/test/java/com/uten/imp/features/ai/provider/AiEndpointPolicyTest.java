package com.uten.imp.features.ai.provider;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.net.InetAddress;
import java.net.UnknownHostException;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** 防 SSRF 规则的表格化测试(ADR-133)。 */
class AiEndpointPolicyTest {

    @ParameterizedTest(name = "[{index}] {0} as {1} (lan http {2})")
    @CsvSource(delimiter = '|', value = {
            // 境内/境外: 只允许 https 公网
            "https://api.deepseek.com                               | MAINLAND | false",
            "https://dashscope.aliyuncs.com/compatible-mode/v1/     | MAINLAND | false",
            "https://api.openai.com/v1                              | OVERSEAS | false",
            "https://8.8.8.8/v1                                     | MAINLAND | false",
            "https://[2001:4860:4860::8888]/v1                      | OVERSEAS | false",
            // 本机部署: 字面回环 http, https 回环/内网
            "http://127.0.0.1:11434/v1                              | LOCAL    | false",
            "http://[::1]:8000/v1                                   | LOCAL    | false",
            "https://10.1.2.3/v1                                    | LOCAL    | false",
            "https://[fd00::1]/v1                                   | LOCAL    | false",
            // 运维开启内网明文后才允许 http 访问内网
            "http://192.168.1.20:8000/v1                            | LOCAL    | true",
            "http://172.16.0.5/v1                                   | LOCAL    | true",
    })
    void acceptsEndpointsThePolicyAllows(String url, AiRegion region, boolean allowLanHttp) {
        assertThatCode(() -> AiEndpointPolicy.validateConfigured(url, region, allowLanHttp))
                .doesNotThrowAnyException();
    }

    @ParameterizedTest(name = "[{index}] {0} as {1} (lan http {2})")
    @CsvSource(delimiter = '|', value = {
            // 协议
            "ftp://api.deepseek.com                                 | MAINLAND | false",
            "http://api.deepseek.com                                | MAINLAND | false",
            "http://8.8.8.8/v1                                      | LOCAL    | true",
            "javascript:alert(1)                                    | MAINLAND | false",
            // 用户信息、查询串、片段
            "https://user:pass@api.deepseek.com                     | MAINLAND | false",
            "https://api.deepseek.com/v1?key=abc                    | MAINLAND | false",
            "https://api.deepseek.com/v1#frag                       | MAINLAND | false",
            // 路径: 点段、百分号、分号
            "https://api.deepseek.com/v1/../admin                   | MAINLAND | false",
            "https://api.deepseek.com/./v1                          | MAINLAND | false",
            "https://api.deepseek.com/%2e%2e/v1                     | MAINLAND | false",
            "https://api.deepseek.com/v1;jsessionid=1               | MAINLAND | false",
            // 元数据与特殊地址(含阿里云 100.100.100.200)
            "https://169.254.169.254/latest                         | LOCAL    | false",
            "http://169.254.169.254/latest                          | LOCAL    | true",
            "https://100.100.100.200/latest                         | LOCAL    | false",
            "https://100.64.0.1/v1                                  | MAINLAND | false",
            "https://0.0.0.0/v1                                     | LOCAL    | false",
            "https://224.0.0.1/v1                                   | MAINLAND | false",
            "https://255.255.255.255/v1                             | MAINLAND | false",
            "https://[fe80::1]/v1                                   | LOCAL    | false",
            "https://[::ffff:169.254.169.254]/v1                    | LOCAL    | false",
            "https://[::ffff:100.100.100.200]/v1                    | LOCAL    | false",
            "https://[64:ff9b::a9fe:a9fe]/v1                        | OVERSEAS | false",
            "https://metadata.google.internal/computeMetadata       | MAINLAND | false",
            "https://metadata/v1                                    | LOCAL    | false",
            // 非标准 IP 写法
            "https://127.1/v1                                       | LOCAL    | false",
            "https://2130706433/v1                                  | LOCAL    | false",
            "https://0x7f.0.0.1/v1                                  | LOCAL    | false",
            // 境内/境外不能指向本机或内网
            "https://127.0.0.1/v1                                   | MAINLAND | false",
            "https://10.0.0.8/v1                                    | OVERSEAS | false",
            "https://[::ffff:127.0.0.1]/v1                          | MAINLAND | false",
            "https://[fd00::1]/v1                                   | MAINLAND | false",
            // 本机部署不能指向公网(否则绕过出网开关)
            "https://8.8.8.8/v1                                     | LOCAL    | false",
            // 明文 http 只允许字面回环, 内网需运维开关
            "http://localhost:11434/v1                              | LOCAL    | false",
            "http://192.168.1.20:8000/v1                            | LOCAL    | false",
            "http://[fd00::1]:8000/v1                               | LOCAL    | false",
    })
    void rejectsEndpointsThePolicyDenies(String url, AiRegion region, boolean allowLanHttp) {
        assertThatThrownBy(() -> AiEndpointPolicy.validateConfigured(url, region, allowLanHttp))
                .isInstanceOf(AiEndpointPolicy.PolicyViolation.class)
                .satisfies(error -> assertThat(error.getMessage()).isNotBlank());
    }

    @Test
    void normalizesTrailingSlashesDefaultPortsAndCase() {
        assertThat(AiEndpointPolicy.parse("HTTPS://API.DeepSeek.com:443/v1/").normalized())
                .isEqualTo("https://api.deepseek.com/v1");
        assertThat(AiEndpointPolicy.parse("http://127.0.0.1:11434/v1").normalized())
                .isEqualTo("http://127.0.0.1:11434/v1");
        assertThat(AiEndpointPolicy.parse("https://[::1]:8443/").normalized())
                .isEqualTo("https://[::1]:8443");
        assertThat(AiEndpointPolicy.normalizeOrNull("not a url")).isNull();
        assertThat(AiEndpointPolicy.normalizeOrNull("https://api.deepseek.com"))
                .isEqualTo(AiEndpointPolicy.normalizeOrNull("https://API.deepseek.com/"));
    }

    @Test
    void checksEveryResolvedAddressAtCallTime() {
        AiEndpointPolicy.Endpoint endpoint = AiEndpointPolicy.parse("https://ai.example.com/v1");
        AiEndpointPolicy.HostResolver rebinding = host -> new InetAddress[]{
                InetAddress.getByName("93.184.216.34"), InetAddress.getByName("169.254.169.254")};
        AiEndpointPolicy.HostResolver privateOnly = host -> new InetAddress[]{InetAddress.getByName("10.0.0.5")};
        AiEndpointPolicy.HostResolver publicOnly = host -> new InetAddress[]{InetAddress.getByName("93.184.216.34")};
        AiEndpointPolicy.HostResolver missing = host -> {
            throw new UnknownHostException(host);
        };

        assertThatThrownBy(() -> AiEndpointPolicy.checkResolved(endpoint, AiRegion.MAINLAND, false, rebinding))
                .isInstanceOf(AiEndpointPolicy.PolicyViolation.class);
        assertThatThrownBy(() -> AiEndpointPolicy.checkResolved(endpoint, AiRegion.MAINLAND, false, privateOnly))
                .isInstanceOf(AiEndpointPolicy.PolicyViolation.class);
        assertThatCode(() -> AiEndpointPolicy.checkResolved(endpoint, AiRegion.MAINLAND, false, publicOnly))
                .doesNotThrowAnyException();
        assertThatCode(() -> AiEndpointPolicy.checkResolved(endpoint, AiRegion.LOCAL, false, privateOnly))
                .doesNotThrowAnyException();
        assertThatThrownBy(() -> AiEndpointPolicy.checkResolved(endpoint, AiRegion.LOCAL, false, publicOnly))
                .isInstanceOf(AiEndpointPolicy.PolicyViolation.class);
        assertThatThrownBy(() -> AiEndpointPolicy.checkResolved(endpoint, AiRegion.MAINLAND, false, missing))
                .isInstanceOf(AiEndpointPolicy.UnresolvableHost.class);

        AiEndpointPolicy.Endpoint lanHttp = AiEndpointPolicy.parse("http://ollama.lan:11434/v1");
        AiEndpointPolicy.HostResolver loopback = host -> new InetAddress[]{InetAddress.getByName("127.0.0.1")};
        assertThatCode(() -> AiEndpointPolicy.checkResolved(lanHttp, AiRegion.LOCAL, true, privateOnly))
                .doesNotThrowAnyException();
        assertThatThrownBy(() -> AiEndpointPolicy.checkResolved(lanHttp, AiRegion.LOCAL, true, loopback))
                .isInstanceOf(AiEndpointPolicy.PolicyViolation.class);
        assertThatThrownBy(() -> AiEndpointPolicy.checkResolved(lanHttp, AiRegion.LOCAL, false, privateOnly))
                .isInstanceOf(AiEndpointPolicy.PolicyViolation.class);
    }

    @Test
    void classifiesMappedAndTunnelledForms() throws Exception {
        assertThat(AiEndpointPolicy.classify(InetAddress.getByName("::ffff:10.0.0.1")))
                .isEqualTo(AiEndpointPolicy.AddressClass.PRIVATE);
        assertThat(AiEndpointPolicy.classify(InetAddress.getByName("2002:a9fe:a9fe::1")))
                .isEqualTo(AiEndpointPolicy.AddressClass.DENIED);
        assertThat(AiEndpointPolicy.classify(InetAddress.getByName("2002:5db8:d822::1")))
                .isEqualTo(AiEndpointPolicy.AddressClass.PUBLIC);
        assertThat(AiEndpointPolicy.classify(InetAddress.getByName("2001:0:4136:e378::1")))
                .isEqualTo(AiEndpointPolicy.AddressClass.DENIED);
        assertThat(AiEndpointPolicy.classify(InetAddress.getByName("::")))
                .isEqualTo(AiEndpointPolicy.AddressClass.DENIED);
        assertThat(AiEndpointPolicy.classify(InetAddress.getByName("192.0.0.8")))
                .isEqualTo(AiEndpointPolicy.AddressClass.DENIED);
        assertThat(AiEndpointPolicy.classify(InetAddress.getByName("100.128.0.1")))
                .isEqualTo(AiEndpointPolicy.AddressClass.PUBLIC);
    }

    @Test
    void presetsOnlyAcceptTheirRegisteredDomains() {
        assertThat(AiProviderPreset.DEEPSEEK.acceptsHost("api.deepseek.com")).isTrue();
        assertThat(AiProviderPreset.DEEPSEEK.acceptsHost("deepseek.com")).isTrue();
        assertThat(AiProviderPreset.DEEPSEEK.acceptsHost("api.deepseek.com.evil.example")).isFalse();
        assertThat(AiProviderPreset.DEEPSEEK.acceptsHost("notdeepseek.com")).isFalse();
        assertThat(AiProviderPreset.DASHSCOPE.acceptsHost("dashscope.aliyuncs.com")).isTrue();
        assertThat(AiProviderPreset.DASHSCOPE.acceptsHost("ws123.cn-beijing.maas.aliyuncs.com")).isTrue();
        // 百炼国际版/美国节点与其他阿里云产品也在 aliyuncs.com 下: 不能挂在境内预设下。
        assertThat(AiProviderPreset.DASHSCOPE.acceptsHost("dashscope-intl.aliyuncs.com")).isFalse();
        assertThat(AiProviderPreset.DASHSCOPE.acceptsHost("dashscope-us.aliyuncs.com")).isFalse();
        assertThat(AiProviderPreset.DASHSCOPE.acceptsHost("ws123.ap-southeast-1.maas.aliyuncs.com")).isFalse();
        assertThat(AiProviderPreset.DASHSCOPE.acceptsHost("oss-cn-hangzhou.aliyuncs.com")).isFalse();
        assertThat(AiProviderPreset.DASHSCOPE.acceptsHost("aliyuncs.com")).isFalse();
        assertThat(AiProviderPreset.MOONSHOT.acceptsHost("api.moonshot.ai")).isFalse();
        assertThat(AiProviderPreset.CUSTOM.acceptsHost("anything.example.com")).isTrue();
        assertThat(AiProviderPreset.OLLAMA.acceptsHost("127.0.0.1")).isTrue();
        for (AiProviderPreset preset : AiProviderPreset.values()) {
            if (!preset.defaultBaseUrl().isEmpty()) {
                AiRegion region = preset.region();
                assertThatCode(() -> AiEndpointPolicy.validateConfigured(preset.defaultBaseUrl(), region, false))
                        .as(preset.name()).doesNotThrowAnyException();
                assertThat(preset.acceptsHost(AiEndpointPolicy.parse(preset.defaultBaseUrl()).host()))
                        .as(preset.name()).isTrue();
            }
        }
    }
}
