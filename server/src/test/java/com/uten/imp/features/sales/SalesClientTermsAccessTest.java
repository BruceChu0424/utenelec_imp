package com.uten.imp.features.sales;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.features.master.currency.CurrencyController;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.currency.dto.CurrencyListItem;
import com.uten.imp.features.master.currency.dto.CurrencySaveRequest;
import com.uten.imp.features.master.referencemethod.ReferenceMethodController;
import com.uten.imp.features.master.referencemethod.ReferenceMethodOption;
import com.uten.imp.features.master.referencemethod.ReferenceMethodService;
import com.uten.imp.features.master.referencemethod.SettlementMethodSaveRequest;
import com.uten.imp.features.sales.order.SalesOrderController;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.SalesOrderTimelineService;
import com.uten.imp.security.SalesClientTermsAccess;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.aop.support.AopUtils;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.AuthenticationCredentialsNotFoundException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

class SalesClientTermsAccessTest {
    private AnnotationConfigApplicationContext context;
    private SalesOrderController controller;
    private SalesOrderService service;
    private ReferenceMethodController referenceController;
    private ReferenceMethodService referenceService;
    private CurrencyController currencyController;
    private CurrencyService currencyService;

    @BeforeEach
    void openContext() {
        SecurityContextHolder.clearContext();
        context = new AnnotationConfigApplicationContext(SecurityConfig.class);
        controller = context.getBean(SalesOrderController.class);
        var dependencies = context.getBean(ControllerDependencies.class);
        service = dependencies.service;
        referenceService = dependencies.referenceService;
        currencyService = dependencies.currencyService;
        referenceController = context.getBean(ReferenceMethodController.class);
        currencyController = context.getBean(CurrencyController.class);
        assertThat(AopUtils.isAopProxy(controller)).isTrue();
        assertThat(AopUtils.isAopProxy(referenceController)).isTrue();
        assertThat(AopUtils.isAopProxy(currencyController)).isTrue();
    }

    @AfterEach
    void closeContext() {
        SecurityContextHolder.clearContext();
        if (context != null) {
            context.close();
        }
    }

    @ParameterizedTest(name = "quote form can read client defaults with only {0}")
    @ValueSource(strings = {"sales_quote:create", "sales_quote:edit"})
    void quoteFormDoesNotRequireSalesOrderView(String permission) {
        assertClientDefaultsReadableWithOnly(permission);
        assertSettlementOptionsReadable();
        assertCurrencyOptionsReadable();
    }

    @ParameterizedTest(name = "existing sales form can read client defaults with only {0}")
    @ValueSource(strings = {
            "sales_order:create", "sales_order:edit",
            "sales_shipment:create", "sales_shipment:edit",
            "sales_other_shipment:create", "sales_other_shipment:edit",
            "sales_return:create", "sales_return:edit"
    })
    void existingSalesFormsRetainClientDefaultAccess(String permission) {
        assertClientDefaultsReadableWithOnly(permission);
        assertSettlementOptionsReadable();
        assertCurrencyOptionsReadable();
    }

    @Test
    void orderViewerRetainsClientDefaultsWithoutAcquiringDictionaryAccess() {
        assertClientDefaultsReadableWithOnly("sales_order:view");

        assertThatThrownBy(referenceController::settlement).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(currencyController::dict).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(referenceService, currencyService);
    }

    @ParameterizedTest(name = "unrelated read permission {0} does not expose client defaults")
    @ValueSource(strings = {
            "sales_quote:view", "notice:read", "finance:view",
            "sales_quote_finance:view", "client:view"
    })
    void unrelatedReadersAreDeniedBeforeCallingService(String permission) {
        signIn(permission);

        assertThatThrownBy(() -> controller.masterDefaultTerms(UUID.randomUUID()))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(referenceController::settlement).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(currencyController::dict).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(service, referenceService, currencyService);
    }

    @Test
    void authenticatedUserWithoutPermissionsIsDeniedBeforeCallingService() {
        signIn();

        assertThatThrownBy(() -> controller.masterDefaultTerms(UUID.randomUUID()))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(referenceController::settlement).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(currencyController::dict).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(service, referenceService, currencyService);
    }

    @Test
    void missingAuthenticationIsDeniedBeforeCallingService() {
        assertThatThrownBy(() -> controller.masterDefaultTerms(UUID.randomUUID()))
                .isInstanceOf(AuthenticationCredentialsNotFoundException.class);
        assertThatThrownBy(referenceController::settlement)
                .isInstanceOf(AuthenticationCredentialsNotFoundException.class);
        assertThatThrownBy(currencyController::dict)
                .isInstanceOf(AuthenticationCredentialsNotFoundException.class);
        verifyNoInteractions(service, referenceService, currencyService);
    }

    @Test
    void paymentStyleViewerRetainsOnlyItsExistingDictionaryAccess() {
        signIn("payment_style:view");
        assertSettlementOptionsReadable();

        assertThatThrownBy(currencyController::dict).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> controller.masterDefaultTerms(UUID.randomUUID()))
                .isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(service, currencyService);
    }

    @Test
    void currencyViewerRetainsOnlyItsExistingDictionaryAccess() {
        signIn("currency:view");
        assertCurrencyOptionsReadable();

        assertThatThrownBy(referenceController::settlement).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> controller.masterDefaultTerms(UUID.randomUUID()))
                .isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(service, referenceService);
    }

    @ParameterizedTest(name = "dictionary access does not grant master management to {0}")
    @ValueSource(strings = {"sales_quote:create", "sales_quote:edit"})
    void quoteFormCannotReadManagementDataOrChangeMasters(String permission) {
        signIn(permission);
        UUID currencyId = UUID.randomUUID();
        UUID settlementId = UUID.randomUUID();
        var currencyRequest = new CurrencySaveRequest();
        currencyRequest.setName("Unauthorized currency");

        assertThatThrownBy(() -> currencyController.list(null, null, null, null, null, 1, 20, null, null))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(currencyController::facets).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> currencyController.detail(currencyId)).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> currencyController.create(currencyRequest)).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> currencyController.update(currencyId, currencyRequest))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> referenceController.settlementAdmin(null, null, null, null, null))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(referenceController::settlementAdminFacets).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> referenceController.createSettlement(
                new SettlementMethodSaveRequest("Unauthorized settlement", null)))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> referenceController.updateSettlementTerms(settlementId, null))
                .isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(() -> referenceController.finance("ANY")).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(service, referenceService, currencyService);
    }

    @ParameterizedTest(name = "client defaults access does not grant order statistics to {0}")
    @ValueSource(strings = {"sales_quote:create", "sales_quote:edit"})
    void quoteFormAccessDoesNotGrantSalesOrderReads(String permission) {
        signIn(permission);

        assertThatThrownBy(controller::stats).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(service);
    }

    @Test
    void clientTermsAndDictionariesUseSharedAuthorizationRules() throws NoSuchMethodException {
        var controllerRule = SalesOrderController.class
                .getMethod("masterDefaultTerms", UUID.class).getAnnotation(PreAuthorize.class);
        var serviceRule = SalesOrderService.class
                .getMethod("masterDefaultTermsForClient", UUID.class).getAnnotation(PreAuthorize.class);

        assertThat(controllerRule).as("client defaults endpoint authorization").isNotNull();
        assertThat(serviceRule).as("service authorization for callers bypassing the controller").isNotNull();
        assertThat(controllerRule.value()).isEqualTo(SalesClientTermsAccess.READ);
        assertThat(serviceRule.value()).isEqualTo(controllerRule.value());
        var settlementRule = ReferenceMethodController.class
                .getMethod("settlement").getAnnotation(PreAuthorize.class);
        var currencyRule = CurrencyController.class
                .getMethod("dict").getAnnotation(PreAuthorize.class);
        assertThat(settlementRule).as("settlement options authorization").isNotNull();
        assertThat(currencyRule).as("currency options authorization").isNotNull();
        assertThat(settlementRule.value()).isEqualTo(SalesClientTermsAccess.SETTLEMENT_OPTIONS);
        assertThat(currencyRule.value()).isEqualTo(SalesClientTermsAccess.CURRENCY_OPTIONS);
    }

    private void assertClientDefaultsReadableWithOnly(String permission) {
        signIn(permission);
        UUID clientId = UUID.randomUUID();
        var expected = new SalesOrderService.MasterDefaultTermsForClient(
                UUID.randomUUID(), "PARTIAL", UUID.randomUUID());
        when(service.masterDefaultTermsForClient(clientId)).thenReturn(expected);

        assertThat(controller.masterDefaultTerms(clientId)).isSameAs(expected);
        verify(service).masterDefaultTermsForClient(clientId);
        verifyNoMoreInteractions(service);
    }

    private void assertSettlementOptionsReadable() {
        var expected = List.of(new ReferenceMethodOption(UUID.randomUUID(), null,
                "JS001", null, "Cash", true));
        when(referenceService.settlementOptions()).thenReturn(expected);

        assertThat(referenceController.settlement()).containsExactlyElementsOf(expected);
        verify(referenceService).settlementOptions();
        verifyNoMoreInteractions(referenceService);
    }

    private void assertCurrencyOptionsReadable() {
        var expected = List.of(new CurrencyListItem(UUID.randomUUID(), "CNY", "人民币",
                BigDecimal.ONE, true, "使用", null));
        when(currencyService.dict()).thenReturn(expected);

        assertThat(currencyController.dict()).containsExactlyElementsOf(expected);
        verify(currencyService).dict();
        verifyNoMoreInteractions(currencyService);
    }

    private static void signIn(String... permissions) {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("client-terms-reader", "unused",
                        Arrays.stream(permissions).map(SimpleGrantedAuthority::new).toList()));
    }

    // Keep the mock outside Spring's service beans so these tests exercise the actual
    // controller interceptor; service protection is checked separately above.
    static class ControllerDependencies {
        final SalesOrderService service = mock(SalesOrderService.class);
        final ReferenceMethodService referenceService = mock(ReferenceMethodService.class);
        final CurrencyService currencyService = mock(CurrencyService.class);
    }

    @TestConfiguration
    @EnableMethodSecurity
    static class SecurityConfig {
        @Bean
        ControllerDependencies controllerDependencies() {
            return new ControllerDependencies();
        }

        @Bean
        SalesOrderController salesOrderController(ControllerDependencies dependencies) {
            return new SalesOrderController(dependencies.service,
                    mock(SalesOrderTimelineService.class), mock(AuditDetailViewRecorder.class));
        }

        @Bean
        ReferenceMethodController referenceMethodController(ControllerDependencies dependencies) {
            return new ReferenceMethodController(dependencies.referenceService,
                    mock(XlsxExportService.class), mock(WorkbookDownloadService.class),
                    mock(AuditService.class), mock(SecurityContextCurrentUser.class), mock(ExportLimitPort.class));
        }

        @Bean
        CurrencyController currencyController(ControllerDependencies dependencies) {
            return new CurrencyController(dependencies.currencyService,
                    mock(XlsxExportService.class), mock(WorkbookDownloadService.class),
                    mock(AuditService.class), mock(SecurityContextCurrentUser.class),
                    mock(AuditDetailViewRecorder.class), mock(ExportLimitPort.class));
        }
    }
}
