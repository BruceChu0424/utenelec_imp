package com.uten.imp.features.ai.provider;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecretCipher;
import com.uten.imp.security.SecretCipherProperties;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.time.Clock;
import java.time.OffsetDateTime;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 服务商配置规则: 密钥只写不读、改地址必须重填密钥、境外与出网开关、默认服务商与审计文字(ADR-133)。 */
class AiProviderServiceTest {

    private static final String KEY = "sk-live-0123456789abcdefghijklmnopQRST";
    private static final String NEW_KEY = "sk-live-9876543210zyxwvutsrqponmlkWXYZ";

    private final List<AiProvider> rows = new ArrayList<>();
    private AiProviderRepository repository;
    private SecretCipher cipher;
    private AiProperties properties;
    private AuditService audit;
    private AiProviderService service;
    private AuthUser admin;

    @BeforeEach
    void setUp() {
        rows.clear();
        repository = mock(AiProviderRepository.class);
        cipher = new SecretCipherForTest().cipher();
        properties = new AiProperties();
        audit = mock(AuditService.class);
        NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
        service = new AiProviderService(repository, cipher, properties, audit, jdbc,
                Clock.fixed(Instant.parse("2026-09-27T08:00:00Z"), ZoneOffset.UTC));
        admin = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "admin", Set.of("authorization:manage"),
                false, true, true);
        when(repository.lockAll()).thenAnswer(invocation -> rows.stream().filter(row->!row.isDeleted()).toList());
        when(repository.findAllOrdered()).thenAnswer(invocation -> rows.stream().filter(row->!row.isDeleted()).toList());
        when(repository.findById(any())).thenAnswer(invocation ->
                rows.stream().filter(row -> row.getId().equals(invocation.getArgument(0))).findFirst());
        when(repository.findDefault()).thenAnswer(invocation -> rows.stream().filter(row->!row.isDeleted()).filter(AiProvider::isDefault).findFirst());
        when(repository.existsByNameIgnoreCaseExcluding(anyString(), any())).thenAnswer(invocation ->
                rows.stream().anyMatch(row -> !row.isDeleted()&&row.getName().equalsIgnoreCase(invocation.getArgument(0))
                        && !row.getId().equals(invocation.getArgument(1))));
        when(repository.saveAndFlush(any())).thenAnswer(invocation -> {
            AiProvider row = invocation.getArgument(0);
            row.setVersion(row.getVersion() == null ? 0L : row.getVersion() + 1);
            if (!rows.contains(row)) {
                rows.add(row);
            }
            return row;
        });
    }

    /** 与生产同一套 SecretCipher(未配置专用密钥, 由 HMAC 密钥派生)。 */
    private static final class SecretCipherForTest {
        SecretCipher cipher() {
            CryptoProperties crypto = new CryptoProperties();
            crypto.setHmacKey("hmac-key-for-provider-service-test-0123456789");
            JwtProperties jwt = new JwtProperties();
            jwt.setIssuer("uten-imp-test");
            return new SecretCipher(new SecretCipherProperties(), crypto, jwt);
        }
    }

    /** 显式审计事件: 结果记 success, 名称与说明在变更快照里。 */
    @SuppressWarnings({"unchecked", "rawtypes"})
    private Map<String, Object> auditChange(String action, UUID id) {
        ArgumentCaptor<Map> change = ArgumentCaptor.forClass(Map.class);
        verify(audit, org.mockito.Mockito.atLeastOnce()).logCommittedChange(any(), any(), eq(action),
                eq("ai_providers"), eq(id.toString()), eq("success"), change.capture());
        return (Map<String, Object>) change.getValue();
    }

    private static AiProviderDtos.ProviderRequest deepSeek(String name, String apiKey, Long version) {
        return new AiProviderDtos.ProviderRequest(name, "DEEPSEEK", null, "OPENAI_CHAT", "https://api.deepseek.com",
                "deepseek-flash", apiKey, null, null, null, null, null, null, null, true, null, version);
    }

    private static AiProviderDtos.ProviderRequest custom(String name, String region, String baseUrl, String apiKey,
                                                         Boolean clearKey, Boolean overseasAck, Long version) {
        return new AiProviderDtos.ProviderRequest(name, "CUSTOM", region, "OPENAI_CHAT", baseUrl, "local-model",
                apiKey, clearKey, null, null, null, null, null, null, true, overseasAck, version);
    }

    private static void assertValidation(Runnable action, String messagePart) {
        assertThatThrownBy(action::run)
                .isInstanceOf(ApiException.class)
                .satisfies(error -> {
                    assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
                    assertThat(error.getMessage()).contains(messagePart);
                });
    }

    @Test
    void firstProviderBecomesDefaultKeyIsEncryptedAndNeverReturnedOrAudited() throws Exception {
        AiProviderDtos.ProviderView view = service.create(deepSeek("DeepSeek 主力", KEY, null), admin);

        AiProvider saved = rows.get(0);
        assertThat(saved.isDefault()).isTrue();
        assertThat(saved.getSecret()).startsWith("gh1:").doesNotContain(KEY);
        assertThat(cipher.decrypt(saved.getSecret(), AiProvider.secretAad(saved.getId()))).isEqualTo(KEY);
        assertThat(saved.getApiKeyLast4()).isEqualTo("QRST");
        assertThat(saved.getBaseUrl()).isEqualTo("https://api.deepseek.com");
        assertThat(saved.getRegion()).isEqualTo(AiRegion.MAINLAND);
        assertThat(saved.getThinkingControl()).isEqualTo(AiThinkingControl.DEEPSEEK);

        assertThat(view.apiKeyConfigured()).isTrue();
        assertThat(view.apiKeyMasked()).isEqualTo("••••QRST");
        assertThat(view.apiKeyUnreadable()).isFalse();
        assertThat(view.isDefault()).isTrue();
        String json = new ObjectMapper().registerModule(new JavaTimeModule()).writeValueAsString(view);
        assertThat(json).doesNotContain(KEY).doesNotContain(saved.getSecret()).contains("\"isDefault\":true");

        Map<String, Object> change = auditChange("ai_provider.create", saved.getId());
        assertThat(change.get("name")).isEqualTo("DeepSeek 主力");
        assertThat(String.valueOf(change.get("detail"))).contains("DeepSeek 主力").contains("密钥已更换(尾号 QRST)")
                .doesNotContain(KEY).doesNotContain(saved.getSecret());
        assertThat(change.toString()).doesNotContain(KEY).doesNotContain(saved.getSecret());
    }

    @Test
    void shortKeysKeepNoTailAndSecondProviderIsNotDefault() {
        service.create(deepSeek("A", KEY, null), admin);
        AiProviderDtos.ProviderView second = service.create(deepSeek("B", "sk-short-key", null), admin);

        assertThat(second.isDefault()).isFalse();
        assertThat(second.apiKeyMasked()).isEqualTo("已配置");
        assertThat(rows.get(1).getApiKeyLast4()).isNull();
        assertThatThrownBy(() -> service.create(deepSeek("a", KEY, null), admin))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    @Test
    void cloudPresetsNeedAKeyButLocalDeploymentsDoNot() {
        assertValidation(() -> service.create(deepSeek("A", null, null), admin), "请填写密钥");
        assertValidation(() -> service.create(deepSeek("A", "has space", null), admin), "密钥里有空格");

        AiProviderDtos.ProviderView ollama = service.create(new AiProviderDtos.ProviderRequest("本机", "OLLAMA", null,
                null, "http://127.0.0.1:11434/v1", "qwen3:8b", null, null, null, null, null, null, null, null,
                true, null, null), admin);
        assertThat(ollama.apiKeyConfigured()).isFalse();
        assertThat(ollama.region()).isEqualTo("LOCAL");
    }

    @Test
    void presetsOnlyAcceptTheirRegisteredDomainAndFixedRegion() {
        assertValidation(() -> service.create(new AiProviderDtos.ProviderRequest("X", "DEEPSEEK", "LOCAL", null,
                "https://api.openai.com/v1", "m", KEY, null, null, null, null, null, null, null, true, null, null),
                admin), "自定义");
        assertValidation(() -> service.create(custom("Y", "MAINLAND", "http://127.0.0.1:8000/v1", KEY, null, null,
                null), admin), "http");
    }

    @Test
    void dashScopeInternationalEndpointsCannotBeFiledUnderTheMainlandPreset() {
        for (String url : List.of("https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                "https://dashscope-us.aliyuncs.com/compatible-mode/v1",
                "https://ws1.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
                "https://fc.aliyuncs.com/v1")) {
            assertValidation(() -> service.create(dashScope("通义", url), admin), "自定义");
        }
        assertThat(rows).isEmpty();

        service.create(dashScope("通义", "https://dashscope.aliyuncs.com/compatible-mode/v1"), admin);
        service.create(dashScope("通义业务空间", "https://ws1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"), admin);
        assertThat(rows).extracting(AiProvider::getRegion).containsOnly(AiRegion.MAINLAND);

        // 国际版只能走「自定义 + 境外」, 受境外开关与出境确认约束。
        assertValidation(() -> service.create(custom("通义国际", "OVERSEAS",
                "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", KEY, null, true, null), admin), "境外");
    }

    private static AiProviderDtos.ProviderRequest dashScope(String name, String baseUrl) {
        return new AiProviderDtos.ProviderRequest(name, "DASHSCOPE", null, null, baseUrl, "qwen3.8-flash", KEY,
                null, null, null, null, null, null, null, true, null, null);
    }

    @Test
    void overseasProvidersNeedTheServerSwitchAndAnAcknowledgement() {
        AiProviderDtos.ProviderRequest openAi = new AiProviderDtos.ProviderRequest("OpenAI", "OPENAI", null, null,
                "https://api.openai.com/v1", "gpt-5.6-luna", KEY, null, null, null, null, null, null, null, true,
                null, null);
        assertValidation(() -> service.create(openAi, admin), "境外");

        properties.setAllowOverseasProviders(true);
        assertValidation(() -> service.create(openAi, admin), "数据出境确认");

        AiProviderDtos.ProviderView view = service.create(new AiProviderDtos.ProviderRequest("OpenAI", "OPENAI",
                null, null, "https://api.openai.com/v1", "gpt-5.6-luna", KEY, null, null, null, null, null, null,
                null, true, true, null), admin);
        assertThat(view.overseasAcknowledged()).isTrue();
        assertThat(rows.get(0).getOverseasAckBy()).isEqualTo(admin.getId());
    }

    @Test
    void outboundSwitchBlocksCloudProvidersButNotLocalOnes() {
        properties.setOutboundEnabled(false);

        assertValidation(() -> service.create(deepSeek("A", KEY, null), admin), "关闭了对外 AI 调用");
        AiProviderDtos.ProviderView local = service.create(custom("本机 vLLM", "LOCAL", "http://127.0.0.1:8000/v1",
                null, null, null, null), admin);
        assertThat(local.region()).isEqualTo("LOCAL");
    }

    @Test
    void changingTheAddressOrProtocolRequiresANewKeyOrExplicitClear() {
        service.create(deepSeek("DeepSeek", KEY, null), admin);
        AiProvider row = rows.get(0);
        String originalSecret = row.getSecret();

        AiProviderDtos.ProviderRequest moved = new AiProviderDtos.ProviderRequest("DeepSeek", "DEEPSEEK", null,
                "OPENAI_CHAT", "https://api.deepseek.com/anthropic", "deepseek-flash", null, null, null, null, null,
                null, null, null, true, null, row.getVersion());
        assertValidation(() -> service.update(row.getId(), moved, admin), "接口地址已修改, 请重新填写密钥");
        AiProviderDtos.ProviderRequest protocol = new AiProviderDtos.ProviderRequest("DeepSeek", "DEEPSEEK", null,
                "ANTHROPIC_MESSAGES", "https://api.deepseek.com", "deepseek-flash", null, null, null, null, null,
                null, null, null, true, null, row.getVersion());
        assertValidation(() -> service.update(row.getId(), protocol, admin), "请重新填写密钥");
        assertThat(row.getSecret()).isEqualTo(originalSecret);

        AiProviderDtos.ProviderRequest withKey = new AiProviderDtos.ProviderRequest("DeepSeek", "DEEPSEEK", null,
                "OPENAI_CHAT", "https://api.deepseek.com/anthropic", "deepseek-flash", NEW_KEY, null, null, null,
                null, null, null, null, true, null, row.getVersion());
        service.update(row.getId(), withKey, admin);
        assertThat(row.getSecret()).isNotEqualTo(originalSecret);
        assertThat(cipher.decrypt(row.getSecret(), AiProvider.secretAad(row.getId()))).isEqualTo(NEW_KEY);
        assertThat(String.valueOf(auditChange("ai_provider.update", row.getId()).get("detail")))
                .contains("接口地址").contains("密钥已更换(尾号 WXYZ)")
                .doesNotContain(NEW_KEY).doesNotContain(KEY);
    }

    @Test
    void keepingTheAddressKeepsTheKeyAndStaleVersionsConflict() {
        service.create(deepSeek("DeepSeek", KEY, null), admin);
        AiProvider row = rows.get(0);
        String secret = row.getSecret();

        service.update(row.getId(), new AiProviderDtos.ProviderRequest("DeepSeek", "DEEPSEEK", null, "OPENAI_CHAT",
                "https://api.deepseek.com/", "deepseek-v4-pro", "", null, null, null, null, null, null, null, true,
                null, row.getVersion()), admin);

        assertThat(row.getSecret()).isEqualTo(secret);
        assertThat(row.getModel()).isEqualTo("deepseek-v4-pro");
        assertThatThrownBy(() -> service.update(row.getId(), deepSeek("DeepSeek", null, row.getVersion() - 1), admin))
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertValidation(() -> service.update(row.getId(), deepSeek("DeepSeek", null, null), admin), "刷新页面");
    }

    @Test
    void clearingTheKeyIsExplicitAndRejectedWhereAKeyIsRequired() {
        service.create(custom("vLLM", "LOCAL", "http://127.0.0.1:8000/v1", KEY, null, null, null), admin);
        AiProvider row = rows.get(0);
        assertValidation(() -> service.update(row.getId(), custom("vLLM", "LOCAL", "http://127.0.0.1:8000/v1",
                NEW_KEY, true, null, row.getVersion()), admin), "不能同时");

        service.update(row.getId(), custom("vLLM", "LOCAL", "http://127.0.0.1:9000/v1", null, true, null,
                row.getVersion()), admin);
        assertThat(row.getSecret()).isNull();
        assertThat(row.getApiKeyLast4()).isNull();

        service.create(deepSeek("DeepSeek", KEY, null), admin);
        AiProvider deepSeek = rows.get(1);
        assertValidation(() -> service.update(deepSeek.getId(), new AiProviderDtos.ProviderRequest("DeepSeek",
                "DEEPSEEK", null, null, "https://api.deepseek.com", "deepseek-flash", null, true, null, null, null,
                null, null, null, true, null, deepSeek.getVersion()), admin), "请填写密钥");
    }

    @Test
    void defaultProviderCanOnlyBeDeletedWhenItIsTheLastOne() {
        service.create(deepSeek("A", KEY, null), admin);
        service.create(deepSeek("B", KEY, null), admin);
        AiProvider first = rows.get(0);

        assertValidation(() -> service.delete(first.getId(), null, admin), "默认");
        AiProvider second = rows.get(1);
        service.delete(second.getId(), second.getVersion(), admin);
        verify(repository).save(second);assertThat(second.isDeleted()).isTrue();assertThat(second.isEnabled()).isFalse();
        assertThat(second.getDeletedBy()).isEqualTo(admin.getId());assertThat(second.getDeletedAt()).isEqualTo(OffsetDateTime.now(Clock.fixed(Instant.parse("2026-09-27T08:00:00Z"),ZoneOffset.UTC)));
        service.delete(first.getId(), null, admin);
        verify(repository).save(first);assertThat(first.isDeleted()).isTrue();assertThat(rows).hasSize(2);
        verify(repository,never()).delete(any());assertThat(service.list()).isEmpty();
        assertThat(String.valueOf(auditChange("ai_provider.delete", first.getId()).get("detail"))).contains("删除");
    }

    @Test
    void settingTheDefaultClearsTheOldOneFirstAndRequiresAnEnabledTarget() {
        service.create(deepSeek("A", KEY, null), admin);
        service.create(deepSeek("B", KEY, null), admin);
        AiProvider first = rows.get(0);
        AiProvider second = rows.get(1);
        second.setEnabled(false);
        assertValidation(() -> service.setDefault(second.getId(), null, admin), "先启用");

        second.setEnabled(true);
        org.mockito.Mockito.clearInvocations(repository);
        InOrder order = inOrder(repository);
        service.setDefault(second.getId(), null, admin);

        assertThat(first.isDefault()).isFalse();
        assertThat(second.isDefault()).isTrue();
        order.verify(repository).lockAll();
        order.verify(repository, org.mockito.Mockito.times(2)).flush();
        assertThat(String.valueOf(auditChange("ai_provider.set_default", second.getId()).get("detail")))
                .contains("原默认「A」");
    }

    @Test
    void storedKeyIsOnlyUsedWithTheStoredAddress() {
        service.create(deepSeek("A", KEY, null), admin);
        AiProvider row = rows.get(0);

        assertValidation(() -> service.storedRuntime(row.getId(),
                new AiProviderDtos.StoredProbeRequest("OPENAI_CHAT", "https://attacker.example/v1", null)),
                "接口地址已修改, 请重新填写密钥");
        assertValidation(() -> service.storedRuntime(row.getId(),
                new AiProviderDtos.StoredProbeRequest("ANTHROPIC_MESSAGES", null, null)), "请重新填写密钥");

        AiProviderRuntime runtime = service.storedRuntime(row.getId(),
                new AiProviderDtos.StoredProbeRequest("openai_chat", "https://API.deepseek.com/", "deepseek-flash"));
        assertThat(runtime.apiKey()).isEqualTo(KEY);
        assertThat(runtime.endpoint().normalized()).isEqualTo("https://api.deepseek.com");
        assertThat(runtime.toString()).doesNotContain(KEY);
    }

    @Test
    void unreadableKeysAreFlaggedAndMakeTheServiceUnavailable() {
        service.create(deepSeek("A", KEY, null), admin);
        AiProvider row = rows.get(0);
        row.setSecret(cipher.encrypt(KEY, AiProvider.secretAad(UUID.randomUUID())));

        assertThat(service.list().get(0).apiKeyUnreadable()).isTrue();
        AiProviderService.Resolution resolution = service.resolveDefault();
        assertThat(resolution.available()).isFalse();
        assertThat(resolution.unavailableReason()).contains("密钥无法解密");
        assertValidation(() -> service.storedRuntime(row.getId(), null), "密钥无法解密");
    }

    @Test
    void resolveDefaultHonoursEnabledOverseasAndOutboundSwitches() {
        assertThat(service.resolveDefault().unavailableReason()).contains("还没有配置");

        service.create(deepSeek("A", KEY, null), admin);
        AiProviderService.Resolution ok = service.resolveDefault();
        assertThat(ok.available()).isTrue();
        assertThat(ok.runtime().apiKey()).isEqualTo(KEY);

        properties.setOutboundEnabled(false);
        assertThat(service.resolveDefault().unavailableReason()).contains("关闭了对外 AI 调用");
        properties.setOutboundEnabled(true);

        rows.get(0).setEnabled(false);
        assertThat(service.resolveDefault().unavailableReason()).contains("已停用");
        rows.get(0).setEnabled(true);

        rows.get(0).setRegion(AiRegion.OVERSEAS);
        assertThat(service.resolveDefault().unavailableReason()).contains("境外");
    }

    @Test
    void probeWithATypedKeyNeverTouchesStoredRows() {
        assertValidation(() -> service.probeRuntime(new AiProviderDtos.ProbeRequest("DEEPSEEK", null, null,
                "https://api.deepseek.com", "deepseek-flash", "", null, null, null, null, null)), "请填写密钥");

        AiProviderRuntime runtime = service.probeRuntime(new AiProviderDtos.ProbeRequest("DEEPSEEK", null, null,
                "https://api.deepseek.com", "deepseek-flash", KEY, null, null, null, 30, null));
        assertThat(runtime.id()).isNull();
        assertThat(runtime.apiKey()).isEqualTo(KEY);
        assertThat(runtime.timeoutSeconds()).isEqualTo(30);
        verify(repository, never()).findById(any());
        verify(repository, never()).findDefault();
    }

    @Test
    void setEnabledAuditsAndLastTestRecordingIsSeparate() {
        service.create(deepSeek("A", KEY, null), admin);
        AiProvider row = rows.get(0);

        AiProviderDtos.ProviderView view = service.setEnabled(row.getId(), false, row.getVersion(), admin);

        assertThat(view.enabled()).isFalse();
        assertThat(String.valueOf(auditChange("ai_provider.set_enabled", row.getId()).get("detail")))
                .contains("停用");
        assertThat(row.getLastTestAt()).isNull();
    }

    @Test void knownZhipuEndpointsRejectMismatchedNewConfigurationAndTypedProbes() {
        assertValidation(() -> service.create(zhipu("OPENAI_CHAT", "/api/anthropic", null), admin), "Anthropic Messages");
        assertValidation(() -> service.create(zhipu("ANTHROPIC_MESSAGES", "/api/paas/v4", null), admin), "OpenAI 兼容");
        assertValidation(() -> service.probeRuntime(new AiProviderDtos.ProbeRequest("ZHIPU", null, "OPENAI_CHAT",
                "https://open.bigmodel.cn/api/anthropic", "glm-5.3", KEY, null, null, null, 30, null)), "Anthropic Messages");
        assertThat(rows).isEmpty();
        service.create(zhipu("ANTHROPIC_MESSAGES", "/api/anthropic", null), admin);
        AiProvider row = rows.getFirst();
        assertValidation(() -> service.update(row.getId(), zhipu("OPENAI_CHAT", "/api/anthropic", row.getVersion()), admin), "Anthropic Messages");
        assertThat(row.getProtocol()).isEqualTo(AiProtocol.ANTHROPIC_MESSAGES);
    }

    @Test void legacyZhipuProtocolMismatchUsesOnlyTheCanonicalProtocolInMemory() {
        service.create(zhipu("ANTHROPIC_MESSAGES", "/api/anthropic", null), admin);
        AiProvider row = rows.getFirst();
        row.setProtocol(AiProtocol.OPENAI_CHAT); // Existing persisted configuration before this validation.
        String secret = row.getSecret(); long version = row.getVersion();
        AiProviderRuntime runtime = service.resolveDefault().runtime();
        assertThat(runtime.protocol()).isEqualTo(AiProtocol.ANTHROPIC_MESSAGES);
        assertThat(runtime.endpoint().normalized()).isEqualTo(row.getBaseUrl());
        assertThat(runtime.apiKey()).isEqualTo(KEY);
        assertThat(service.storedRuntime(row.getId(), new AiProviderDtos.StoredProbeRequest("OPENAI_CHAT", row.getBaseUrl(), row.getModel())).protocol())
                .isEqualTo(AiProtocol.ANTHROPIC_MESSAGES);
        assertThat(row.getProtocol()).isEqualTo(AiProtocol.OPENAI_CHAT);
        assertThat(row.getSecret()).isEqualTo(secret);
        assertThat(row.getVersion()).isEqualTo(version);

        var openAi = mock(com.uten.imp.features.ai.client.AiProtocolClient.class);
        var anthropic = mock(com.uten.imp.features.ai.client.AiProtocolClient.class);
        when(openAi.protocol()).thenReturn(AiProtocol.OPENAI_CHAT);
        when(anthropic.protocol()).thenReturn(AiProtocol.ANTHROPIC_MESSAGES);
        when(anthropic.chat(any(), any())).thenReturn(new com.uten.imp.features.ai.client.AiProtocolClient.ChatResponse("{\"ok\":true}", 1, 1, 200, false, 1));
        var gateway = new com.uten.imp.features.ai.gateway.AiGateway(service, List.of(openAi, anthropic),
                mock(com.uten.imp.features.ai.gateway.AiCallLogService.class), properties, mock(com.uten.imp.security.SecurityContextCurrentUser.class),
                mock(com.uten.imp.features.ai.usage.AiUserLimitsService.class));
        assertThat(gateway.completeJson(new com.uten.imp.application.port.AiCompletionPort.AiCompletionRequest("CONFIGURATION_TEST", "Return JSON.",
                List.of(new com.uten.imp.application.port.AiCompletionPort.AiText("hello", true)), null, null, 256, null)).json()).isEqualTo("{\"ok\":true}");
        verify(openAi, never()).chat(any(), any());
        verify(anthropic).chat(any(), any());
    }

    @Test void customAndUnknownProxyPathsAreNeverInferredFromTheirNames() {
        assertThat(AiEndpointProtocolCompatibility.effectiveProtocol(AiProviderPreset.CUSTOM, AiProtocol.OPENAI_CHAT,
                AiEndpointPolicy.parse("https://open.bigmodel.cn/api/anthropic"))).isEqualTo(AiProtocol.OPENAI_CHAT);
        assertThat(AiEndpointProtocolCompatibility.effectiveProtocol(AiProviderPreset.ZHIPU, AiProtocol.OPENAI_CHAT,
                AiEndpointPolicy.parse("https://proxy.bigmodel.cn/api/anthropic"))).isEqualTo(AiProtocol.OPENAI_CHAT);
        assertThat(AiEndpointProtocolCompatibility.effectiveProtocol(AiProviderPreset.ZHIPU, AiProtocol.OPENAI_CHAT,
                AiEndpointPolicy.parse("https://open.bigmodel.cn/custom/anthropic"))).isEqualTo(AiProtocol.OPENAI_CHAT);
        assertThat(AiEndpointProtocolCompatibility.effectiveProtocol(AiProviderPreset.ZHIPU, AiProtocol.OPENAI_CHAT,
                AiEndpointPolicy.parse("https://open.bigmodel.cn/api/anthropic/v1"))).isEqualTo(AiProtocol.ANTHROPIC_MESSAGES);
        assertThat(AiEndpointProtocolCompatibility.effectiveProtocol(AiProviderPreset.ZHIPU, AiProtocol.ANTHROPIC_MESSAGES,
                AiEndpointPolicy.parse("https://open.bigmodel.cn/api/paas/v4"))).isEqualTo(AiProtocol.OPENAI_CHAT);
    }

    private static AiProviderDtos.ProviderRequest zhipu(String protocol, String path, Long version) {
        return new AiProviderDtos.ProviderRequest("智谱测试", "ZHIPU", null, protocol,
                "https://open.bigmodel.cn" + path, "glm-5.3", KEY, null, null, null, null, null, null, null, true, null, version);
    }
}
