package com.uten.imp.features.master.client;

import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.master.dto.MasterStatusChangeRequest;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.aopalliance.intercept.MethodInvocation;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.authorization.AuthorizationResult;
import org.springframework.security.authorization.method.PreAuthorizeAuthorizationManager;
import org.springframework.security.core.context.SecurityContextHolder;

import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.nullable;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/** The shared request's required fields depend on the actual service write mode. */
class ClientSaveRequestServiceBoundaryTest {
    private static final UUID CLIENT_ID = UUID.fromString("00000000-0000-0000-0000-000000000101");
    private static final UUID CATEGORY_ID = UUID.fromString("00000000-0000-0000-0000-000000000102");
    private static final UUID OWNER_ID = UUID.fromString("00000000-0000-0000-0000-000000000103");
    private static final String ORIGINAL_NAME = "客户原名称";
    private static final String ORIGINAL_BANK = "原银行";

    private ClientRepository repository;
    private ClientCategoryRepository categories;
    private CategoryDrivenCodeService codes;
    private EntityManager entityManager;
    private ClientCategory category;
    private Client existing;
    private ClientAccessPolicy policy;
    private ClientAccessPolicy.ClientScope scope;
    private ClientService service;

    @BeforeEach void setUp() {
        repository = mock(ClientRepository.class);
        categories = mock(ClientCategoryRepository.class);
        codes = mock(CategoryDrivenCodeService.class);
        entityManager = mock(EntityManager.class);
        policy = mock(ClientAccessPolicy.class);
        var employees = mock(EmployeeRepository.class);
        var names = mock(EmployeeNameResolver.class);
        scope = new ClientAccessPolicy.ClientScope(
                new OwnerVisibility.OwnerScope(true, Set.of(), Set.of()), Set.of(), OWNER_ID, false);
        when(policy.evaluate()).thenReturn(scope);
        when(policy.canWrite(any(Client.class), any())).thenReturn(true);
        when(policy.requireCurrentEmployeeId()).thenReturn(OWNER_ID);

        category = new ClientCategory();
        category.setId(CATEGORY_ID);
        category.setName("现有分类");
        existing = new Client();
        existing.setId(CLIENT_ID);
        existing.setCategory(category);
        existing.setOwnerEmployeeId(OWNER_ID);
        existing.setName(ORIGINAL_NAME);
        existing.setFullName("客户原全称");
        existing.setPhone("原联系电话");
        existing.setCode("KH000001");
        existing.setCodeSequence(1L);
        existing.setCodeManaged(true);
        existing.setStatus("使用");
        existing.setBank(ORIGINAL_BANK);
        existing.setCreditFloor(new BigDecimal("100.00"));
        when(repository.findById(CLIENT_ID)).thenReturn(Optional.of(existing));
        when(entityManager.find(Client.class, CLIENT_ID, LockModeType.PESSIMISTIC_WRITE)).thenReturn(existing);
        when(categories.findById(CATEGORY_ID)).thenReturn(Optional.of(category));

        var employee = new Employee();
        employee.setId(OWNER_ID);
        employee.setStatus("active");
        when(employees.findById(OWNER_ID)).thenReturn(Optional.of(employee));
        when(names.nameOf(OWNER_ID)).thenReturn("负责人");
        when(names.namesOf(any())).thenReturn(Map.of(OWNER_ID, "负责人"));
        when(codes.allocate(CategoryDrivenCodeService.MasterType.CLIENT, CATEGORY_ID, null))
                .thenReturn(new CategoryCodeAllocation("KH000002", 2L, CATEGORY_ID, true));
        when(codes.allocateForUpdate(any(), any(), any(), nullable(String.class), any()))
                .thenAnswer(invocation -> invocation.getArgument(4, CategoryCodeAllocation.class));
        var owners = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(owners);
        when(owners.setParameter(anyString(), any())).thenReturn(owners);
        when(owners.getResultList()).thenReturn(List.of());
        service = new ClientService(repository, categories, mock(TxSessionVars.class), entityManager,
                codes, policy, employees, names);
    }

    @AfterEach void clearAuthentication() {
        SecurityContextHolder.clearContext();
    }

    @Test void createRejectsAnOmittedCategoryBeforeSaving() {
        authenticate("client:create");
        var request = new ClientSaveRequest();
        request.setName("客户名称");
        assertCoreFieldsRejected(() -> service.create(request));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {" ", "\t\r\n"})
    void createRejectsMissingEmptyOrBlankNamesBeforeSaving(String name) {
        authenticate("client:create");
        var request = new ClientSaveRequest();
        request.setCategoryId(CATEGORY_ID);
        request.setName(name);
        assertCoreFieldsRejected(() -> service.create(request));
    }

    @Test void createAcceptsTheCompleteOrdinaryCore() {
        authenticate("client:create");
        var request = new ClientSaveRequest();
        request.setCategoryId(CATEGORY_ID);
        request.setName("新客户名称");
        var saved = service.create(request);
        assertEquals(CATEGORY_ID, saved.getCategoryId());
        assertEquals("新客户名称", saved.getName());
        verify(repository).save(any(Client.class));
        verify(entityManager).flush();
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void ordinaryUpdateRequiresCategoryEvenWhenTheCallerAlsoHasFinancePermission(boolean alsoFinance) {
        authenticateOrdinaryEditor(alsoFinance);
        var request = new ClientSaveRequest();
        request.setName(ORIGINAL_NAME);
        assertCoreFieldsRejected(() -> service.update(CLIENT_ID, request));
    }

    @ParameterizedTest
    @MethodSource("ordinaryInvalidNames")
    void ordinaryUpdateRequiresNameEvenWhenTheCallerAlsoHasFinancePermission(boolean alsoFinance, String name) {
        authenticateOrdinaryEditor(alsoFinance);
        var request = new ClientSaveRequest();
        request.setCategoryId(CATEGORY_ID);
        request.setName(name);
        assertCoreFieldsRejected(() -> service.update(CLIENT_ID, request));
    }

    @Test void financeOnlyPatchMayOmitNameAndCategoryWhileKeepingOrdinaryFacts() {
        authenticate("client:finance");
        var request = financialPatch();
        var saved = service.update(CLIENT_ID, request);
        assertEquals(CATEGORY_ID, saved.getCategoryId());
        assertEquals(ORIGINAL_NAME, saved.getName());
        assertOrdinaryFactsPreserved();
        assertEquals("新银行", existing.getBank());
        assertEquals(new BigDecimal("350.25"), existing.getCreditFloor());
        assertTrue(saved.isFinancialWritable());
        verify(repository).save(existing);
        verify(entityManager).flush();
        verifyNoInteractions(categories, codes);
    }

    @ParameterizedTest
    @ValueSource(strings = {"其他客户名称", "", " \t"})
    void financeOnlyPatchCannotChangeOrClearTheOrdinaryName(String name) {
        authenticate("client:finance");
        var request = financialPatch();
        request.setName(name);
        assertFinanceOnlyChangeRejected(request);
    }

    @ParameterizedTest
    @ValueSource(strings = {"categoryId", "fullName", "phone"})
    void financeOnlyPatchCannotChangeOtherOrdinaryFacts(String field) {
        authenticate("client:finance");
        var request = financialPatch();
        switch (field) {
            case "categoryId" -> request.setCategoryId(UUID.fromString("00000000-0000-0000-0000-000000000104"));
            case "fullName" -> request.setFullName("其他客户全称");
            case "phone" -> request.setPhone("其他联系电话");
            default -> throw new AssertionError(field);
        }
        assertFinanceOnlyChangeRejected(request);
    }

    @Test void combinedOrdinaryAndFinancePermissionsKeepTheOrdinaryCompleteSaveMode() {
        authenticate("client:edit", "client:finance");
        var request = ordinaryRequest("使用");
        request.setBank("新银行");
        request.setCreditFloor(new BigDecimal("350.25"));
        request.setName("普通完整保存的新名称");
        var saved = service.update(CLIENT_ID, request);
        assertEquals("普通完整保存的新名称", saved.getName());
        assertEquals(CATEGORY_ID, saved.getCategoryId());
        assertEquals("新银行", existing.getBank());
        assertEquals(new BigDecimal("350.25"), existing.getCreditFloor());
        verify(repository).save(existing);
        verify(codes).allocateForUpdate(CategoryDrivenCodeService.MasterType.CLIENT, CLIENT_ID,
                CATEGORY_ID, "KH000001", new CategoryCodeAllocation("KH000001", 1L, null, true));
    }

    @Test void genericUpdateAuthorizesEitherEditingModeOnBothLayersAndRejectsStatusOnly() throws Exception {
        for (Class<?> type : List.of(ClientController.class, ClientService.class)) {
            Method update = type.getMethod("update", UUID.class, ClientSaveRequest.class);
            assertTrue(authorize(update, ordinaryRequest("使用"), "client:edit").isGranted());
            assertTrue(authorize(update, financialPatch(), "client:finance").isGranted());
            assertTrue(authorize(update, ordinaryRequest("使用"), "client:edit", "client:finance").isGranted());
            assertFalse(authorize(update, ordinaryRequest("禁用"), "client:status").isGranted());
        }
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void unchangedStatusDoesNotRequireAdditionalStatusPermissionForOrdinarySaving(boolean alsoFinance) {
        authenticateOrdinaryEditor(alsoFinance);
        var saved = service.update(CLIENT_ID, ordinaryRequest("使用"));
        assertEquals("使用", saved.getStatus());
        assertOrdinaryFactsPreserved();
        verify(repository).save(existing);
        verify(entityManager).flush();
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void aChangedStatusRequiresStatusPermissionInAdditionToEitherOrdinaryEditingCombination(boolean alsoFinance) {
        authenticateOrdinaryEditor(alsoFinance);
        ApiException denied = assertThrows(ApiException.class,
                () -> service.update(CLIENT_ID, ordinaryRequest("禁用")));
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        assertOrdinaryFactsPreserved();
        verify(repository, never()).save(any(Client.class));
        verify(entityManager, never()).flush();
        verifyNoInteractions(categories, codes);
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void ordinaryEditingWithStatusPermissionCanChangeStatusWithoutChangingTheFinancialFacts(boolean alsoFinance) {
        if (alsoFinance) authenticate("client:edit", "client:finance", "client:status");
        else authenticate("client:edit", "client:status");
        var saved = service.update(CLIENT_ID, ordinaryRequest("禁用"));
        assertEquals("禁用", saved.getStatus());
        assertEquals(ORIGINAL_NAME, saved.getName());
        assertEquals(CATEGORY_ID, saved.getCategoryId());
        assertEquals(ORIGINAL_BANK, existing.getBank());
        assertEquals(new BigDecimal("100.00"), existing.getCreditFloor());
        verify(repository).save(existing);
        verify(entityManager).flush();
    }

    @Test void statusOnlyCannotUseTheGenericSaveEvenForTrustedInProcessCalls() {
        authenticate("client:status");
        ApiException denied = assertThrows(ApiException.class,
                () -> service.update(CLIENT_ID, ordinaryRequest("禁用")));
        assertEquals(ErrorCode.NOT_FOUND, denied.getCode());
        assertOrdinaryFactsPreserved();
        verify(repository, never()).save(any(Client.class));
        verify(entityManager, never()).flush();
        verifyNoInteractions(categories, codes);
    }

    @ParameterizedTest
    @ValueSource(booleans = {false, true})
    void financeOnlyPatchCannotChangeStatusEvenWithTheSeparateStatusPermission(boolean alsoStatus) {
        if (alsoStatus) authenticate("client:finance", "client:status");
        else authenticate("client:finance");
        var request = financialPatch();
        request.setStatus("禁用");
        assertFinanceOnlyChangeRejected(request);
    }

    @Test void explicitStatusAuthorizationStillRequiresItsDedicatedPermissionOnBothLayers() throws Exception {
        var request = new MasterStatusChangeRequest("禁用", 0L);
        for (Class<?> type : List.of(ClientController.class, ClientService.class)) {
            Method status = type.getMethod("changeStatus", UUID.class, MasterStatusChangeRequest.class);
            assertTrue(authorize(status, request, "client:status").isGranted());
            assertFalse(authorize(status, request, "client:edit").isGranted());
            assertFalse(authorize(status, request, "client:finance").isGranted());
            assertFalse(authorize(status, request, "client:edit", "client:finance").isGranted());
        }
    }

    @Test void explicitStatusStillUsesTheLockedEntityAndObjectWriteScope() {
        authenticate("client:status");
        var saved = service.changeStatus(CLIENT_ID, new MasterStatusChangeRequest("禁用", 0L));
        assertEquals("禁用", saved.getStatus());
        assertEquals(ORIGINAL_NAME, saved.getName());
        assertEquals(CATEGORY_ID, saved.getCategoryId());
        var order = inOrder(entityManager, policy, repository);
        order.verify(entityManager).find(Client.class, CLIENT_ID, LockModeType.PESSIMISTIC_WRITE);
        order.verify(policy).evaluate();
        order.verify(policy).requireWritable(existing, scope);
        order.verify(repository).save(existing);
        verifyNoInteractions(categories, codes);
    }

    @Test void explicitStatusCannotBypassTheLockedObjectsWriteScope() {
        authenticate("client:status");
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "客户不存在"))
                .when(policy).requireWritable(existing, scope);
        ApiException denied = assertThrows(ApiException.class,
                () -> service.changeStatus(CLIENT_ID, new MasterStatusChangeRequest("禁用", 0L)));
        assertEquals(ErrorCode.NOT_FOUND, denied.getCode());
        assertOrdinaryFactsPreserved();
        verify(entityManager).find(Client.class, CLIENT_ID, LockModeType.PESSIMISTIC_WRITE);
        verify(policy).requireWritable(existing, scope);
        verify(repository, never()).save(any(Client.class));
    }

    @Test void explicitStatusStillRejectsAStaleVersionAfterTheScopeCheck() {
        authenticate("client:status");
        ApiException denied = assertThrows(ApiException.class,
                () -> service.changeStatus(CLIENT_ID, new MasterStatusChangeRequest("禁用", 1L)));
        assertEquals(ErrorCode.CONFLICT, denied.getCode());
        assertOrdinaryFactsPreserved();
        verify(policy).requireWritable(existing, scope);
        verify(repository, never()).save(any(Client.class));
    }

    private void assertCoreFieldsRejected(org.junit.jupiter.api.function.Executable save) {
        ApiException failure = assertThrows(ApiException.class, save);
        assertEquals(ErrorCode.VALIDATION_FAILED, failure.getCode());
        verify(repository, never()).save(any(Client.class));
        verify(entityManager, never()).flush();
        verifyNoInteractions(categories, codes);
        assertOrdinaryFactsPreserved();
    }

    private void assertFinanceOnlyChangeRejected(ClientSaveRequest request) {
        ApiException failure = assertThrows(ApiException.class, () -> service.update(CLIENT_ID, request));
        assertEquals(ErrorCode.FORBIDDEN, failure.getCode());
        assertOrdinaryFactsPreserved();
        assertEquals(ORIGINAL_BANK, existing.getBank());
        assertEquals(new BigDecimal("100.00"), existing.getCreditFloor());
        verify(repository, never()).save(any(Client.class));
        verify(entityManager, never()).flush();
        verifyNoInteractions(categories, codes);
    }

    private void assertOrdinaryFactsPreserved() {
        assertSame(category, existing.getCategory());
        assertEquals(ORIGINAL_NAME, existing.getName());
        assertEquals("客户原全称", existing.getFullName());
        assertEquals("原联系电话", existing.getPhone());
        assertEquals("KH000001", existing.getCode());
        assertEquals(OWNER_ID, existing.getOwnerEmployeeId());
        assertEquals("使用", existing.getStatus());
    }

    private static ClientSaveRequest financialPatch() {
        var request = new ClientSaveRequest();
        request.setVersion(0L);
        request.setBank("新银行");
        request.setCreditFloor(new BigDecimal("350.25"));
        return request;
    }

    private static ClientSaveRequest ordinaryRequest(String status) {
        var request = new ClientSaveRequest();
        request.setVersion(0L);
        request.setCategoryId(CATEGORY_ID);
        request.setName(ORIGINAL_NAME);
        request.setFullName("客户原全称");
        request.setPhone("原联系电话");
        request.setCode("KH000001");
        request.setStatus(status);
        return request;
    }

    private static AuthorizationResult authorize(Method method, Object request, String... authorities) {
        var authentication = new TestingAuthenticationToken("synthetic-client-operator", "n/a", authorities);
        authentication.setAuthenticated(true);
        MethodInvocation invocation = mock(MethodInvocation.class);
        when(invocation.getMethod()).thenReturn(method);
        when(invocation.getThis()).thenReturn(mock(method.getDeclaringClass()));
        when(invocation.getArguments()).thenReturn(new Object[]{CLIENT_ID, request});
        AuthorizationResult result = new PreAuthorizeAuthorizationManager().authorize(() -> authentication, invocation);
        assertNotNull(result, "The real method must keep an explicit authorization gate");
        return result;
    }

    private static void authenticateOrdinaryEditor(boolean alsoFinance) {
        if (alsoFinance) authenticate("client:edit", "client:finance");
        else authenticate("client:edit");
    }

    private static void authenticate(String... authorities) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("synthetic-client-operator", "n/a", authorities));
    }

    private static Stream<Arguments> ordinaryInvalidNames() {
        return Stream.of(false, true).flatMap(alsoFinance ->
                Stream.of(null, "", " ", "\t\r\n").map(name -> Arguments.of(alsoFinance, name)));
    }
}
