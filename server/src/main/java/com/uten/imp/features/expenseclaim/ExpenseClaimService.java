package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.finance.EmployeeClaimPostingPort;
import com.uten.imp.common.finance.EmployeeClaimPostingPort.EmployeeClaimPosting;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimCreateRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimItemDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimItemInput;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimPaymentRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class ExpenseClaimService {

    private static final Set<String> STATUSES =
            Set.of("DRAFT", "SUBMITTED", "REVIEWING", "APPROVED", "REJECTED", "PAID");
    private static final Set<String> CATEGORIES = Set.of(
            "TRANSPORT", "TRAVEL", "MEAL", "OFFICE",
            "COMMUNICATION", "ENTERTAINMENT", "TRAINING", "OTHER");

    private final ExpenseClaimRepository claimRepository;
    private final ExpenseClaimItemRepository itemRepository;
    private final ExpenseApplicantQuery applicantQuery;
    private final EmployeeClaimPostingPort postingPort;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listMine(
            String rawStatuses,
            Integer year,
            Integer month,
            UUID departmentId,
            int page,
            int size) {
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        return listClaims(
                user.getEmployeeId(),
                normalizeStatuses(rawStatuses),
                year,
                month,
                departmentId,
                page,
                size,
                true);
    }

    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listPending(
            Integer year,
            Integer month,
            UUID departmentId,
            int page,
            int size) {
        AuthUser user = requireStaff();
        require(user, "expense:approve");
        return listClaims(
                null,
                Set.of("SUBMITTED", "REVIEWING"),
                year,
                month,
                departmentId,
                page,
                size,
                false);
    }

    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listPayable(
            Integer year,
            Integer month,
            UUID departmentId,
            int page,
            int size) {
        AuthUser user = requireStaff();
        require(user, "expense:pay");
        return listClaims(
                null,
                Set.of("APPROVED"),
                year,
                month,
                departmentId,
                page,
                size,
                false);
    }

    private PageResponse<ExpenseClaimDto> listClaims(
            UUID applicantId,
            Set<String> statuses,
            Integer year,
            Integer month,
            UUID departmentId,
            int page,
            int size,
            boolean newestFirst) {
        DateRange dateRange = createdAtRange(year, month);
        Specification<ExpenseClaim> spec = (root, query, cb) -> {
            List<Predicate> predicates = new ArrayList<>();
            if (applicantId != null) {
                predicates.add(cb.equal(root.get("applicantId"), applicantId));
            }
            if (!statuses.isEmpty()) {
                predicates.add(root.get("status").in(statuses));
            }
            if (departmentId != null) {
                predicates.add(cb.equal(root.get("applicantDepartmentId"), departmentId));
            }
            if (dateRange != null) {
                predicates.add(cb.greaterThanOrEqualTo(
                        root.get("createdAt"), dateRange.fromInclusive()));
                predicates.add(cb.lessThan(root.get("createdAt"), dateRange.toExclusive()));
            }
            return cb.and(predicates.toArray(new Predicate[0]));
        };
        Sort.Direction direction = newestFirst ? Sort.Direction.DESC : Sort.Direction.ASC;
        Pageable pageable = Pageables.of(page, size, Sort.by(
                new Sort.Order(direction, "createdAt"),
                new Sort.Order(direction, "id")));
        Page<ExpenseClaim> result = claimRepository.findAll(spec, pageable);
        return new PageResponse<>(
                mapClaims(result.getContent()),
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                result.getTotalElements(),
                result.getTotalPages());
    }

    @Transactional(readOnly = true)
    public ExpenseClaimDto detail(UUID id) {
        ExpenseClaim claim = requireClaim(id);
        assertCanRead(claim);
        return mapClaim(claim, itemsFor(List.of(claim)).getOrDefault(id, List.of()));
    }

    @Transactional
    public ExpenseClaimDto create(ExpenseClaimCreateRequest request) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        ExpenseApplicantQuery.ApplicantSnapshot applicant = applicantQuery
                .findEligible(user.getEmployeeId())
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "当前员工档案不可申请报销"));

        List<ValidatedItem> validated = request.items().stream()
                .map(this::validateItem)
                .toList();
        BigDecimal total = validated.stream()
                .map(ValidatedItem::amount)
                .reduce(BigDecimal.ZERO.setScale(2), BigDecimal::add);
        if (total.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报销合计必须大于零");
        }

        ExpenseClaim claim = new ExpenseClaim();
        claim.setApplicantId(user.getEmployeeId());
        claim.setApplicantNameSnapshot(applicant.name());
        claim.setApplicantDepartmentId(applicant.departmentId());
        claim.setTitle(request.title().trim());
        claim.setTotalAmount(total);
        claim.setStatus("DRAFT");
        claim.setRemark(trimToNull(request.remark()));
        claimRepository.save(claim);

        int lineNo = 1;
        List<ExpenseClaimItem> items = new java.util.ArrayList<>(validated.size());
        for (ValidatedItem value : validated) {
            ExpenseClaimItem item = new ExpenseClaimItem();
            item.setClaimId(claim.getId());
            item.setLineNo(lineNo++);
            item.setCategory(value.category());
            item.setAmount(value.amount());
            item.setExpenseDate(value.date());
            item.setDescription(value.description());
            items.add(item);
        }
        itemRepository.saveAll(items);
        return mapClaim(claim, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        ExpenseClaim claim = requireClaimForUpdate(id);
        assertOwner(claim, user);
        assertStatus(claim, "DRAFT");
        itemRepository.deleteByClaimId(id);
        itemRepository.flush();
        claimRepository.delete(claim);
    }

    @Transactional
    public ExpenseClaimDto submit(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        ExpenseClaim claim = requireClaimForUpdate(id);
        assertOwner(claim, user);
        assertStatus(claim, "DRAFT");
        Instant now = Instant.now();
        claim.setStatus("SUBMITTED");
        claim.setSubmittedBy(user.getEmployeeId());
        claim.setSubmittedAt(now);
        claim.setRejectReason(null);
        claim.setRejectedBy(null);
        claim.setRejectedAt(null);
        claimRepository.save(claim);
        return mapClaimWithItems(claim);
    }

    @Transactional
    public ExpenseClaimDto withdraw(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        ExpenseClaim claim = requireClaimForUpdate(id);
        assertOwner(claim, user);
        if (!Set.of("SUBMITTED", "REVIEWING").contains(claim.getStatus())) {
            throw stateConflict(claim);
        }
        claim.setStatus("DRAFT");
        claim.setSubmittedBy(null);
        claim.setSubmittedAt(null);
        claimRepository.save(claim);
        return mapClaimWithItems(claim);
    }

    @Transactional
    public ExpenseClaimDto approve(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:approve");
        ExpenseClaim claim = requireClaimForUpdate(id);
        if (claim.getApplicantId().equals(user.getEmployeeId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "申请人不能审批自己的报销单");
        }
        if (!Set.of("SUBMITTED", "REVIEWING").contains(claim.getStatus())) {
            throw stateConflict(claim);
        }
        claim.setStatus("APPROVED");
        claim.setApprovedBy(user.getEmployeeId());
        claim.setApprovedAt(Instant.now());
        claimRepository.save(claim);
        return mapClaimWithItems(claim);
    }

    @Transactional
    public ExpenseClaimDto reject(UUID id, String reason) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:approve");
        ExpenseClaim claim = requireClaimForUpdate(id);
        if (claim.getApplicantId().equals(user.getEmployeeId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "申请人不能驳回自己的报销单");
        }
        if (!Set.of("SUBMITTED", "REVIEWING").contains(claim.getStatus())) {
            throw stateConflict(claim);
        }
        claim.setStatus("REJECTED");
        claim.setRejectReason(reason.trim());
        claim.setRejectedBy(user.getEmployeeId());
        claim.setRejectedAt(Instant.now());
        claim.setApprovedBy(null);
        claim.setApprovedAt(null);
        claimRepository.save(claim);
        return mapClaimWithItems(claim);
    }

    @Transactional
    public ExpenseClaimDto pay(UUID id, ExpenseClaimPaymentRequest request) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:pay");
        ExpenseClaim claim = requireClaimForUpdate(id);
        if (claim.getApplicantId().equals(user.getEmployeeId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "申请人不能给自己的报销单打款");
        }
        if ("PAID".equals(claim.getStatus())) {
            if (request.accountId().equals(claim.getPaymentAccountId())
                    && request.expenseStyleId().equals(claim.getPaymentExpenseStyleId())
                    && request.paymentDate().equals(claim.getPaymentDate())
                    && claim.getFinanceExpenseId() != null) {
                return mapClaimWithItems(claim);
            }
            throw new ApiException(ErrorCode.CONFLICT, "报销单已使用其他打款参数完成支付");
        }
        assertStatus(claim, "APPROVED");

        UUID financeExpenseId = postingPort.postEmployeeClaim(
                new EmployeeClaimPosting(
                        claim.getId(),
                        request.paymentDate(),
                        request.accountId(),
                        request.expenseStyleId(),
                        claim.getApplicantDepartmentId(),
                        claim.getTotalAmount()));

        claim.setStatus("PAID");
        claim.setPaidBy(user.getEmployeeId());
        claim.setPaidAt(Instant.now());
        claim.setPaymentDate(request.paymentDate());
        claim.setPaymentAccountId(request.accountId());
        claim.setPaymentExpenseStyleId(request.expenseStyleId());
        claim.setFinanceExpenseId(financeExpenseId);
        claimRepository.save(claim);
        return mapClaimWithItems(claim);
    }

    private ValidatedItem validateItem(ExpenseClaimItemInput input) {
        String category = input.category().trim().toUpperCase(Locale.ROOT);
        if (!CATEGORIES.contains(category)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知报销类别");
        }
        BigDecimal amount;
        try {
            amount = input.amount().setScale(2, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException exception) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报销金额最多保留两位小数");
        }
        if (amount.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报销金额必须大于零");
        }
        return new ValidatedItem(
                category, amount, input.date(), trimToNull(input.description()));
    }

    private void assertCanRead(ExpenseClaim claim) {
        AuthUser user = requireStaff();
        if (claim.getApplicantId().equals(user.getEmployeeId()) && has(user, "expense:apply")) {
            return;
        }
        if (Set.of("SUBMITTED", "REVIEWING").contains(claim.getStatus())
                && has(user, "expense:approve")) {
            return;
        }
        if (Set.of("APPROVED", "PAID").contains(claim.getStatus())
                && has(user, "expense:pay")) {
            return;
        }
        throw new ApiException(ErrorCode.NOT_FOUND, "报销单不存在");
    }

    private static void assertOwner(ExpenseClaim claim, AuthUser user) {
        if (!claim.getApplicantId().equals(user.getEmployeeId())) {
            throw new ApiException(ErrorCode.NOT_FOUND, "报销单不存在");
        }
    }

    private static void assertStatus(ExpenseClaim claim, String expected) {
        if (!expected.equals(claim.getStatus())) {
            throw stateConflict(claim);
        }
    }

    private static ApiException stateConflict(ExpenseClaim claim) {
        return new ApiException(ErrorCode.CONFLICT,
                "报销单当前为 " + claim.getStatus() + "，不能执行此操作");
    }

    private ExpenseClaimDto mapClaimWithItems(ExpenseClaim claim) {
        return mapClaim(
                claim, itemsFor(List.of(claim)).getOrDefault(claim.getId(), List.of()));
    }

    private List<ExpenseClaimDto> mapClaims(List<ExpenseClaim> claims) {
        Map<UUID, List<ExpenseClaimItem>> items = itemsFor(claims);
        return claims.stream()
                .map(claim -> mapClaim(
                        claim, items.getOrDefault(claim.getId(), List.of())))
                .toList();
    }

    private Map<UUID, List<ExpenseClaimItem>> itemsFor(List<ExpenseClaim> claims) {
        if (claims.isEmpty()) {
            return Map.of();
        }
        return itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(
                        claims.stream().map(ExpenseClaim::getId).toList())
                .stream()
                .collect(Collectors.groupingBy(
                        ExpenseClaimItem::getClaimId,
                        LinkedHashMap::new,
                        Collectors.toList()));
    }

    private static ExpenseClaimDto mapClaim(
            ExpenseClaim claim, List<ExpenseClaimItem> items) {
        return new ExpenseClaimDto(
                claim.getId(),
                claim.getApplicantId(),
                claim.getApplicantNameSnapshot(),
                claim.getTitle(),
                items.stream().map(item -> new ExpenseClaimItemDto(
                        item.getId(),
                        item.getCategory(),
                        item.getAmount(),
                        item.getExpenseDate(),
                        item.getDescription())).toList(),
                claim.getTotalAmount(),
                claim.getStatus(),
                claim.getCreatedAt(),
                claim.getSubmittedAt(),
                claim.getApprovedAt(),
                claim.getPaidAt(),
                claim.getRemark(),
                claim.getRejectReason());
    }

    private ExpenseClaim requireClaim(UUID id) {
        return claimRepository.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "报销单不存在"));
    }

    private ExpenseClaim requireClaimForUpdate(UUID id) {
        return claimRepository.findByIdForUpdate(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "报销单不存在"));
    }

    private static Set<String> normalizeStatuses(String raw) {
        if (raw == null || raw.isBlank()) {
            return Set.of();
        }
        Set<String> normalized = new LinkedHashSet<>();
        for (String token : raw.split(",", -1)) {
            String status = token.trim().toUpperCase(Locale.ROOT);
            if (status.isEmpty() || !STATUSES.contains(status)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知报销状态");
            }
            normalized.add(status);
        }
        return normalized;
    }

    private static DateRange createdAtRange(Integer year, Integer month) {
        if (year == null && month == null) {
            return null;
        }
        if (year == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "按月份筛选时必须同时提供年份");
        }
        if (year < 2000 || year > 2200) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报销年份必须在 2000 至 2200 之间");
        }
        if (month != null && (month < 1 || month > 12)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报销月份必须在 1 至 12 之间");
        }
        LocalDate from = month == null
                ? LocalDate.of(year, 1, 1)
                : LocalDate.of(year, month, 1);
        LocalDate to = month == null ? from.plusYears(1) : from.plusMonths(1);
        return new DateRange(
                from.atStartOfDay(BusinessTime.ZONE).toInstant(),
                to.atStartOfDay(BusinessTime.ZONE).toInstant());
    }

    private AuthUser requireStaff() {
        AuthUser user = currentUser.get()
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor() || user.getEmployeeId() == null) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        return user;
    }

    private static boolean has(AuthUser user, String permission) {
        return user.isSuperAdmin() || user.getPermissions().contains(permission);
    }

    private static void require(AuthUser user, String permission) {
        if (!has(user, permission)) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
    }

    private static String trimToNull(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }

    private record ValidatedItem(
            String category,
            BigDecimal amount,
            java.time.LocalDate date,
            String description
    ) {
    }

    private record DateRange(Instant fromInclusive, Instant toExclusive) {
    }
}
