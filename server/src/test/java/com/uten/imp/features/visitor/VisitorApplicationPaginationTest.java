package com.uten.imp.features.visitor;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorListItem;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Path;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@SuppressWarnings({"unchecked", "rawtypes"})
class VisitorApplicationPaginationTest {

    private VisitorApplicationRepository repository;
    private VisitorApplicationMapper mapper;
    private SecurityContextCurrentUser currentUser;
    private VisitorApplicationService applicationService;

    @BeforeEach
    void setUp() {
        repository = mock(VisitorApplicationRepository.class);
        mapper = mock(VisitorApplicationMapper.class);
        currentUser = mock(SecurityContextCurrentUser.class);
        applicationService = new VisitorApplicationService(
                repository,
                mock(VisitorApprovalStepRepository.class),
                mock(VisitorAccountRepository.class),
                mock(EmployeeRepository.class),
                mapper,
                mock(TxSessionVars.class),
                currentUser);
    }

    @Test
    void mineClampsPageAndSizeAndUsesStableNewestFirstSort() {
        UUID visitorId = UUID.randomUUID();
        when(currentUser.id()).thenReturn(Optional.of(visitorId));
        stubPage(501);

        var response = applicationService.listMine("approved", 0, 999);

        Pageable pageable = capturedPageable();
        assertEquals(0, pageable.getPageNumber());
        assertEquals(100, pageable.getPageSize());
        assertEquals(List.of("createdAt", "id"),
                pageable.getSort().stream().map(Sort.Order::getProperty).toList());
        assertFalse(pageable.getSort().stream().anyMatch(Sort.Order::isAscending));
        assertEquals(1, response.getPage());
        assertEquals(100, response.getSize());
        assertEquals(501, response.getTotal());
    }

    @Test
    void mineSpecificationKeepsVisitorOwnershipAndStatusFilters() {
        UUID visitorId = UUID.randomUUID();
        when(currentUser.id()).thenReturn(Optional.of(visitorId));
        stubPage(0);

        applicationService.listMine("approved", 1, 20);

        Specification<VisitorApplication> specification = capturedSpecification();
        CriteriaFixture criteria = new CriteriaFixture();
        specification.toPredicate(criteria.root, criteria.query, criteria.builder);

        verify(criteria.builder).equal(criteria.visitorAccountId, visitorId);
        verify(criteria.builder).equal(criteria.deleted, false);
        verify(criteria.builder).equal(criteria.status, "approved");
    }

    @Test
    void approvalDefaultsToPendingStatesAndUsesServerPage() {
        AuthUser staff = mock(AuthUser.class);
        when(staff.isVisitor()).thenReturn(false);
        when(staff.getId()).thenReturn(UUID.randomUUID());
        when(currentUser.get()).thenReturn(Optional.of(staff));
        stubPage(42);
        VisitorHrApprovalService service = new VisitorHrApprovalService(
                repository,
                applicationService,
                mock(VisitorGateService.class),
                new VisitorGuard(currentUser),
                mock(TxSessionVars.class));

        var response = service.listForApproval(null, 2, 20);

        Pageable pageable = capturedPageable();
        assertEquals(1, pageable.getPageNumber());
        assertEquals(2, response.getPage());

        Specification<VisitorApplication> specification = capturedSpecification();
        CriteriaFixture criteria = new CriteriaFixture();
        specification.toPredicate(criteria.root, criteria.query, criteria.builder);
        verify(criteria.status).in("pending", "hostReviewing");
        verify(criteria.builder).equal(criteria.deleted, false);
    }

    @Test
    void hostListAlwaysKeepsEmployeeOwnershipWhenFilteringHistory() {
        UUID employeeId = UUID.randomUUID();
        AuthUser staff = mock(AuthUser.class);
        when(staff.getEmployeeId()).thenReturn(employeeId);
        when(currentUser.get()).thenReturn(Optional.of(staff));
        stubPage(3);
        VisitorHostConfirmService service = new VisitorHostConfirmService(
                repository,
                applicationService,
                currentUser,
                mock(TxSessionVars.class));

        service.myAsHost("approved", 1, 20);

        Specification<VisitorApplication> specification = capturedSpecification();
        CriteriaFixture criteria = new CriteriaFixture();
        specification.toPredicate(criteria.root, criteria.query, criteria.builder);
        verify(criteria.builder).equal(criteria.hostEmployeeId, employeeId);
        verify(criteria.builder).equal(criteria.deleted, false);
        verify(criteria.builder).equal(criteria.status, "approved");
    }

    @Test
    void hostCannotReadAnotherEmployeesApplicationById() {
        UUID employeeId = UUID.randomUUID();
        AuthUser staff = mock(AuthUser.class);
        when(staff.isVisitor()).thenReturn(false);
        when(staff.getEmployeeId()).thenReturn(employeeId);
        when(staff.getPermissions()).thenReturn(java.util.Set.of("visitor:host-confirm"));
        when(currentUser.get()).thenReturn(Optional.of(staff));

        VisitorApplication anotherHostsApplication = new VisitorApplication();
        anotherHostsApplication.setHostEmployeeId(UUID.randomUUID());
        VisitorApplicationService appService = mock(VisitorApplicationService.class);
        when(appService.load(anotherHostsApplication.getId()))
                .thenReturn(anotherHostsApplication);
        VisitorHrApprovalService service = new VisitorHrApprovalService(
                repository,
                appService,
                mock(VisitorGateService.class),
                new VisitorGuard(currentUser),
                mock(TxSessionVars.class));

        ApiException error = assertThrows(
                ApiException.class,
                () -> service.getDetailForStaff(anotherHostsApplication.getId()));

        assertEquals(ErrorCode.VISITOR_NOT_FOUND, error.getCode());
    }

    @Test
    void approverCanReadAnyApplication() {
        AuthUser approver = mock(AuthUser.class);
        when(approver.isVisitor()).thenReturn(false);
        when(approver.getPermissions()).thenReturn(java.util.Set.of("visitor:approve"));
        when(currentUser.get()).thenReturn(Optional.of(approver));

        VisitorApplication application = new VisitorApplication();
        VisitorApplicationService appService = mock(VisitorApplicationService.class);
        when(appService.load(application.getId())).thenReturn(application);
        VisitorHrApprovalService service = new VisitorHrApprovalService(
                repository,
                appService,
                mock(VisitorGateService.class),
                new VisitorGuard(currentUser),
                mock(TxSessionVars.class));

        service.getDetailForStaff(application.getId());

        verify(appService).toDetail(application, null);
    }

    private void stubPage(long total) {
        VisitorApplication application = new VisitorApplication();
        Page<VisitorApplication> page = new PageImpl<>(
                total == 0 ? List.of() : List.of(application),
                PageRequest.of(0, 100),
                total);
        when(repository.findAll(
                any(Specification.class),
                any(Pageable.class))).thenReturn(page);
        when(mapper.toListItems(any())).thenReturn(List.of(listItem()));
    }

    private Pageable capturedPageable() {
        ArgumentCaptor<Pageable> captor = ArgumentCaptor.forClass(Pageable.class);
        verify(repository).findAll(any(Specification.class), captor.capture());
        return captor.getValue();
    }

    @SuppressWarnings("unchecked")
    private Specification<VisitorApplication> capturedSpecification() {
        ArgumentCaptor<Specification<VisitorApplication>> captor =
                ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        return captor.getValue();
    }

    private static VisitorListItem listItem() {
        return new VisitorListItem(
                UUID.randomUUID(),
                "访客",
                "公司",
                "来访",
                "接待人",
                "部门",
                null,
                null,
                "pending",
                null,
                null,
                false,
                null);
    }

    private static final class CriteriaFixture {
        private final Root<VisitorApplication> root = mock(Root.class);
        private final CriteriaQuery<?> query = mock(CriteriaQuery.class);
        private final CriteriaBuilder builder = mock(CriteriaBuilder.class);
        private final Path<UUID> visitorAccountId = mock(Path.class);
        private final Path<UUID> hostEmployeeId = mock(Path.class);
        private final Path<Boolean> deleted = mock(Path.class);
        private final Path<String> status = mock(Path.class);

        private CriteriaFixture() {
            when(root.<UUID>get("visitorAccountId")).thenReturn(visitorAccountId);
            when(root.<UUID>get("hostEmployeeId")).thenReturn(hostEmployeeId);
            when(root.<Boolean>get("deleted")).thenReturn(deleted);
            when(root.<String>get("status")).thenReturn(status);
            when(builder.equal(any(), any())).thenReturn(mock(Predicate.class));
            when(builder.and(any(Predicate[].class))).thenReturn(mock(Predicate.class));
            when(status.in(any(Object[].class))).thenReturn(mock(Predicate.class));
        }
    }
}
