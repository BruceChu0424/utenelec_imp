package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiCompletionPort;
import com.uten.imp.application.port.AiJobHandler.AiJobInput;
import com.uten.imp.application.port.AiJobUsagePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.time.Clock;
import java.time.ZoneId;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import org.assertj.core.api.InstanceOfAssertFactories;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class SalesDocumentIntakeJobHandlerTest {

    private final IntakeFixture fixture = IntakeFixture.load();
    private final FixtureLookup lookup = new FixtureLookup(fixture);
    private final AiCompletionPort aiPort = mock(AiCompletionPort.class);
    private final SalesDocumentIntakeJobHandler handler = new SalesDocumentIntakeJobHandler(lookup, new FakeReferenceData(),
            new ObjectMapper(), aiPort, new SecurityContextCurrentUser(),
            Clock.fixed(fixture.asOf.atStartOfDay(ZoneId.of("Asia/Shanghai")).toInstant(), ZoneId.of("Asia/Shanghai")));

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    private static void login(String... permissions) {
        AuthUser user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "sales01", Set.of(permissions), false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    private static Map<String, String> params(String docType) {
        Map<String, String> p = new LinkedHashMap<>();
        p.put("docType", docType);
        return p;
    }

    @Test
    void submitNeedsCreateOrEditPermissionOfTheDocumentType() {
        login("sales_quote:create");
        handler.authorizeSubmit(params("quote"));
        assertThatThrownBy(() -> handler.authorizeSubmit(params("order")))
                .isInstanceOf(ApiException.class)
                .satisfies(e -> assertThat(((ApiException) e).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        login("sales_order:edit");
        handler.authorizeSubmit(params("order"));
        handler.authorizeRead(params("order"));
        assertThatThrownBy(() -> handler.authorizeRead(params("quote"))).isInstanceOf(ApiException.class);
    }

    @Test
    void visitorsAndAnonymousCallersAreRejected() {
        assertThatThrownBy(() -> handler.authorizeSubmit(params("quote"))).isInstanceOf(ApiException.class);
        AuthUser visitor = AuthUser.visitor(UUID.randomUUID(), "v1", "V0001", Set.of("sales_quote:create"));
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(visitor, null, visitor.getAuthorities()));
        assertThatThrownBy(() -> handler.authorizeSubmit(params("quote"))).isInstanceOf(ApiException.class)
                .satisfies(e -> assertThat(((ApiException) e).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }

    @Test
    void parametersAreStrictlyValidated() {
        login("sales_quote:create");
        assertThatThrownBy(() -> handler.authorizeSubmit(params("invoice"))).isInstanceOf(ApiException.class);
        Map<String, String> unknown = params("quote");
        unknown.put("sql", "1");
        assertThatThrownBy(() -> handler.authorizeSubmit(unknown)).isInstanceOf(ApiException.class);
        Map<String, String> badUuid = params("quote");
        badUuid.put("clientId", "not-a-uuid");
        assertThatThrownBy(() -> handler.authorizeSubmit(badUuid)).isInstanceOf(ApiException.class);
        Map<String, String> sheet = params("quote");
        sheet.put("sheet", "2");
        handler.authorizeSubmit(sheet);
        assertThat(handler.kind()).isEqualTo("SALES_DOCUMENT_INTAKE");
        assertThat(handler.maxInputBytes()).isEqualTo(15L * 1024 * 1024);
        assertThat(handler.acceptedKinds()).containsExactlyInAnyOrder("XLSX", "XLS", "CSV", "PDF", "PNG", "JPEG", "WEBP");
    }

    @Test
    void templateLearningRequiresExportPriceAndDocumentPermissionsAndAnExcelFile() {
        Map<String, String> template = new LinkedHashMap<>(Map.of("docType", "quote", "templateOnly", "true",
                "clientId", fixture.client("CLIENT_A").id().toString(), "docId", java.util.UUID.randomUUID().toString()));
        login("sales_quote:create");
        assertThatThrownBy(() -> handler.authorizeSubmit(template)).hasMessageContaining("权限");
        login("sales_quote:create", "sales_quote:view", "sales_quote:export", "sales_order:price:view");
        handler.authorizeSubmit(template);
        handler.authorizeRead(template);
        byte[] bytes = new byte[]{1};
        assertThatThrownBy(() -> handler.validateInput(template, new AiJobInput("template.csv", "text/csv", "CSV", 1, bytes, "0".repeat(64))))
                .hasMessageContaining("xlsx/xls");
        handler.validateInput(template, new AiJobInput("template.xlsx", "x", "XLSX", 1, bytes, "0".repeat(64)));
    }

    @Test
    void inputMustBeASupportedKindAndThePreselectedClientMustBeVisible() {
        login("sales_quote:create");
        byte[] bytes = new byte[]{1, 2, 3};
        AiJobInput unsupported = new AiJobInput("a.exe", "application/octet-stream", "UNSUPPORTED", 3, bytes, "0".repeat(64));
        assertThatThrownBy(() -> handler.validateInput(params("quote"), unsupported)).isInstanceOf(ApiException.class);
        AiJobInput xlsx = new AiJobInput("a.xlsx", "x", "XLSX", 3, bytes, "0".repeat(64));
        Map<String, String> withClient = params("quote");
        withClient.put("clientId", fixture.client("CLIENT_A").id().toString());
        handler.validateInput(withClient, xlsx);
        java.util.UUID clientA = fixture.client("CLIENT_A").id();
        for (String status : new String[]{"停用", null}) {
            lookup.profileOverrides.put(clientA, new com.uten.imp.application.port.MasterIntakeLookupPort.ClientProfile(clientA,
                    "C-A", "Alpha", null, null, null, null, null, null, null, null, null, null, null, null, null, status,
                    List.of(), List.of(), true));
            assertThatThrownBy(() -> handler.validateInput(withClient, xlsx)).as("status %s", status)
                    .isInstanceOf(ApiException.class).hasMessageContaining("客户");
        }
        lookup.profileOverrides.clear();
        lookup.hiddenClients.add(clientA);
        assertThatThrownBy(() -> handler.validateInput(withClient, xlsx)).isInstanceOf(ApiException.class)
                .hasMessageContaining("客户");
    }

    @Test
    void resultIsMaskedForReadersWithoutPriceView() {
        Map<String, Object> candidate = new LinkedHashMap<>();
        candidate.put("goodsId", fixture.goods.stream().filter(g -> !fixture.invisibleGoods.contains(g.id())).findFirst().orElseThrow().id().toString());
        candidate.put("listPrice", 21);
        candidate.put("discount", 1);
        candidate.put("rateUsed", 1);
        candidate.put("pricingFlag", "OK");
        candidate.put("pricingNote", "n");
        candidate.put("orderBlocked", true);
        candidate.put("reasons", List.of("型号一致", "单价与标价一致"));
        Map<String, Object> line = new LinkedHashMap<>();
        line.put("candidates", List.of(candidate));
        line.put("customerUnitPrice", 21);
        line.put("bundleParts", List.of(Map.of("partNo", "A", "candidates", List.of(Map.of("goodsId", candidate.get("goodsId"), "listPrice", 3)))));
        Map<String, Object> summary = new LinkedHashMap<>();
        summary.put("priceMasked", false);
        Map<String, Object> currency = new LinkedHashMap<>();
        currency.put("financeRate", 7.1);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("lines", List.of(line));
        result.put("summary", summary);
        result.put("currency", currency);

        login("sales_quote:create");
        Map<String, Object> masked = handler.filterResultForReader(result);
        @SuppressWarnings("unchecked")
        Map<String, Object> maskedCandidate = ((List<Map<String, Object>>) ((List<Map<String, Object>>) masked.get("lines")).getFirst()
                .get("candidates")).getFirst();
        assertThat(maskedCandidate).as("「订货单不能直接导入」不是价格, 看不到价格的人也要知道")
                .containsOnlyKeys("goodsId", "reasons", "orderBlocked");
        assertThat(maskedCandidate.get("orderBlocked")).isEqualTo(true);
        assertThat(maskedCandidate.get("reasons")).isEqualTo(List.of("型号一致"));
        assertThat(((Map<?, ?>) masked.get("summary")).get("priceMasked")).isEqualTo(true);
        assertThat(((Map<?, ?>) masked.get("currency")).get("financeRate")).isNull();
        assertThat(masked.toString()).doesNotContain("listPrice");
        assertThat(candidate).containsKey("listPrice");
        assertThat(summary.get("priceMasked")).isEqualTo(false);

        login("sales_quote:create", "sales_order:price:view");
        assertThat(handler.filterResultForReader(result)).isSameAs(result);
        login("sales_quote:create", "goods:price:view");
        assertThat(handler.filterResultForReader(result)).isSameAs(result);
    }

    @Test
    void newClientProposalIsOnlyOfferedToReadersWhoMayCreateClients() {
        Map<String, Object> client = new LinkedHashMap<>();
        client.put("status", "UNMATCHED");
        client.put("newClientProposal", Map.of("name", "ACME FZE"));
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("client", client);

        login("sales_quote:create", "sales_order:price:view");
        Map<String, Object> filtered = handler.filterResultForReader(result);
        @SuppressWarnings("unchecked")
        Map<String, Object> filteredClient = (Map<String, Object>) filtered.get("client");
        assertThat(filteredClient).containsEntry("status", "UNMATCHED").containsEntry("newClientProposal", null);
        assertThat(client.get("newClientProposal")).as("入参不被修改").isNotNull();

        login("sales_quote:create", "sales_order:price:view", "client:create");
        assertThat(handler.filterResultForReader(result)).isSameAs(result);
        login("sales_quote:create", "client:create");
        assertThat(((Map<?, ?>) handler.filterResultForReader(result).get("client")).get("newClientProposal"))
                .as("看不到价格也照常提议新建客户").isNotNull();
    }

    @Test
    void processRunsRulesOnlyWhenAiIsOff() {
        login("sales_quote:create");
        IntakeFixture.FixtureDocument doc = fixture.document("SUNAS");
        FakeJobContext ctx = FakeJobContext.of("SUNAS.xlsx", "XLSX", IntakeFixture.toXlsx(doc), "quote");
        Map<String, Object> result = handler.process(ctx);
        assertThat(result.get("schemaVersion")).isEqualTo(2);
        assertThat(result.get("notices")).asInstanceOf(InstanceOfAssertFactories.LIST)
                .contains(IntakeTexts.NOTICE_AI_OFF);
        assertThat(ctx.stages).containsSubsequence("READING:10", "LAYOUT:25", "EXTRACTING:40", "MATCHING_GOODS:60",
                "MATCHING_CLIENT:75", "PRICING:90", "DONE:100");
        assertThat(ctx.aiRequests).isEmpty();
        assertThat(((Map<?, ?>) result.get("extraction")).get("layoutSource")).isEqualTo("RULES");
        assertThat(((Map<?, ?>) result.get("extraction")).get("aiUsed")).isEqualTo(false);
    }

    private static SalesIntakeLayoutLearnerOrderingTest.NoOpTransactionManager noTx() {
        return new SalesIntakeLayoutLearnerOrderingTest.NoOpTransactionManager();
    }

    @Test
    void layoutLearnerStoresTheLayoutFromTheServerSideResultOnly() {
        AiJobUsagePort usage = mock(AiJobUsagePort.class);
        IntakeReferenceData store = mock(IntakeReferenceData.class);
        SalesIntakeLayoutLearner learner = new SalesIntakeLayoutLearner(usage, store, noTx());
        UUID job = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        UUID client = UUID.randomUUID();
        Map<String, Object> extraction = new LinkedHashMap<>();
        extraction.put("layoutSource", "RULES");
        extraction.put("layoutFingerprint", "a".repeat(64));
        extraction.put("headerTexts", "A=s/n|B=part no.\nA=序号");
        extraction.put("columnRoles", Map.of("A", "LINE_NO", "B", "PART_NO"));
        when(usage.resultFor(job, user)).thenReturn(Optional.of(Map.of("extraction", extraction)));
        learner.onIntakeUsed(new SalesIntakeUsedEvent(job, user, "quote", UUID.randomUUID(), client));
        verify(store).upsertLayout(eq("a".repeat(64)), eq(client), eq("A=s/n|B=part no.\nA=序号"),
                eq(Map.of("A", "LINE_NO", "B", "PART_NO")), eq(1));

        IntakeReferenceData store2 = mock(IntakeReferenceData.class);
        AiJobUsagePort usage2 = mock(AiJobUsagePort.class);
        when(usage2.resultFor(any(), any())).thenReturn(Optional.empty());
        new SalesIntakeLayoutLearner(usage2, store2, noTx())
                .onIntakeUsed(new SalesIntakeUsedEvent(job, user, "order", UUID.randomUUID(), null));
        verify(store2, never()).upsertLayout(anyString(), any(), anyString(), any(), anyInt());

        // 保存时用的就是学习到的版式: 只刷新使用时间, 不当新证据(不加确认次数)。
        IntakeReferenceData store3 = mock(IntakeReferenceData.class);
        AiJobUsagePort usage3 = mock(AiJobUsagePort.class);
        Map<String, Object> learnedExtraction = new LinkedHashMap<>(extraction);
        learnedExtraction.put("layoutSource", "LEARNED");
        when(usage3.resultFor(job, user)).thenReturn(Optional.of(Map.of("extraction", learnedExtraction)));
        new SalesIntakeLayoutLearner(usage3, store3, noTx())
                .onIntakeUsed(new SalesIntakeUsedEvent(job, user, "quote", UUID.randomUUID(), client));
        verify(store3).touchLayout("a".repeat(64), client);
        verify(store3, never()).upsertLayout(anyString(), any(), anyString(), any(), anyInt());

        Map<String, Object> pdfExtraction = new LinkedHashMap<>();
        pdfExtraction.put("layoutSource", "AI");
        pdfExtraction.put("layoutFingerprint", null);
        assertThat(SalesIntakeLayoutLearner.layoutFacts(Map.of("extraction", pdfExtraction))).isNull();
    }

    @Test
    void layoutLearnerFailureNeverPropagates() {
        AiJobUsagePort usage = mock(AiJobUsagePort.class);
        when(usage.resultFor(any(), any())).thenThrow(new IllegalStateException("db down"));
        new SalesIntakeLayoutLearner(usage, mock(IntakeReferenceData.class), noTx())
                .onIntakeUsed(new SalesIntakeUsedEvent(UUID.randomUUID(), UUID.randomUUID(), "quote", UUID.randomUUID(), null));
    }

    @Test
    void dedicatedTemplateAdoptionUsesIdempotentLayoutLearningWithoutAnyMasterDataEvent() {
        AiJobUsagePort usage = mock(AiJobUsagePort.class);
        IntakeReferenceData store = mock(IntakeReferenceData.class);
        UUID job = UUID.randomUUID(), actor = UUID.randomUUID(), quote = UUID.randomUUID(), client = UUID.randomUUID();
        Map<String, String> roles = Map.of("A", "PART_NO", "B", "QTY");
        when(usage.resultFor(job, actor)).thenReturn(Optional.of(Map.of("templateOnly", true, "extraction", Map.of(
                "layoutSource", "AI", "layoutFingerprint", "a".repeat(64), "headerTexts", "A=model|B=qty", "columnRoles", roles))));
        var event = new com.uten.imp.features.sales.template.SalesQuoteTemplateAdoptedEvent(job, actor, quote, client);
        new SalesIntakeLayoutLearner(usage, store, noTx()).onTemplateAdopted(event);
        verify(store).learnLayoutOnce(new SalesIntakeUsedEvent(job, actor, "quote", quote, client), "a".repeat(64),
                "A=model|B=qty", roles, 0, false);
        org.mockito.Mockito.verifyNoMoreInteractions(store);
        verify(usage, never()).markUsed(any(), any(), any(), any());
    }
}
