package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.finance.EmployeeClaimPostingPort;
import com.uten.imp.common.finance.EmployeeClaimPostingPort.EmployeeClaimPosting;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.attachment.AttachmentLifecycleState;
import com.uten.imp.features.attachment.AttachmentRepository;
import com.uten.imp.features.attachment.AttachmentService;
import com.uten.imp.features.attachment.dto.AttachmentDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimBatchRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimBatchResultDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimCreateRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimEventDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceCheckDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceInput;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimItemDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimItemInput;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimPaymentRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimSummaryDto;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.application.port.PaymentReferenceLabelsPort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 费用报销单服务：申请人 CRUD + 审核状态机 + 发票登记 + 流转事件。
 *
 * <p>状态：草稿（DRAFT）→ 提交（SUBMITTED）→ 审核（REVIEWING）→ 通过（APPROVED）/
 * 驳回（REJECTED，修订后可再次 submit 重提）→ 付款（PAID）。
 * 审批走 {@code EXPENSE_APPROVE} 并发认领（{@link TaskClaimService}）+ 行悲观锁；
 * 付款加 {@link PaymentStyleHierarchyLock} 并经 {@link EmployeeClaimPostingPort} 过账到财务费用。
 *
 * <p>V608：单号 BX（{@link DocNumberService}）；发票登记「代码+号码」查重
 * （财会〔2020〕6 号防重复入账）；每次流转写 {@code expense_claim_events}
 * （操作人姓名快照），详情审批轨迹不再前端合成。
 */
@Service
@RequiredArgsConstructor
public class ExpenseClaimService {
    private com.uten.imp.common.history.RetainedRecordReader retainedRecords;
    @org.springframework.beans.factory.annotation.Autowired
    public void setRetainedRecords(com.uten.imp.common.history.RetainedRecordReader reader) { retainedRecords = reader; }


    private static final Set<String> STATUSES =
            Set.of("DRAFT", "SUBMITTED", "REVIEWING", "APPROVED", "REJECTED", "PAID");
    /** 并发认领目标类型（与 TaskClaimPolicy 登记的 EXPENSE_APPROVE 对齐）。 */
    private static final String TASK_TYPE_APPROVE = "EXPENSE_APPROVE";
    private static final Set<String> CATEGORIES = Set.of(
            "TRANSPORT", "TRAVEL", "MEAL", "OFFICE",
            "COMMUNICATION", "ENTERTAINMENT", "TRAINING", "OTHER");
    private static final Set<String> INVOICE_TYPES = Set.of(
            "GENERAL", "SPECIAL", "DIGITAL", "PAPER_GENERAL", "PAPER_SPECIAL", "OTHER");
    private static final Set<String> EDITABLE_STATUSES = Set.of("DRAFT", "REJECTED");

    private final ExpenseClaimRepository claimRepository;
    private final ExpenseClaimItemRepository itemRepository;
    private final ExpenseClaimInvoiceRepository invoiceRepository;
    private final ExpenseClaimEventRepository eventRepository;
    private final ExpenseApplicantQuery applicantQuery;
    private final EmployeeClaimPostingPort postingPort;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final TaskClaimService taskClaim;
    private final AttachmentRepository attachmentRepository;
    private final AttachmentService attachmentService;
    private final HrNoticePort hrNotice;
    private final DocNumberService docNumber;
    private final PaymentReferenceLabelsPort paymentLabels;
    private final ExpenseClaimSettingsService settings;
    @org.springframework.beans.factory.annotation.Autowired
    private org.springframework.beans.factory.ObjectProvider<com.uten.imp.common.platformcolumns.PlatformColumnService> platformColumns;

    @org.springframework.beans.factory.annotation.Autowired
    private ExpenseClaimReadPolicy readAccess;
    @org.springframework.beans.factory.annotation.Autowired
    private ExpenseApprovalPolicy approvalPolicy;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.application.policy.DepartmentApprovalRouting departmentRouting;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private com.uten.imp.application.port.FinanceApplicationControlPort applicationControl;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private com.uten.imp.application.port.NativeApplicationOriginPort nativeOrigins;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private com.uten.imp.application.port.TaskAudiencePort taskAudience;

    private com.uten.imp.security.OwnerVisibility.OwnerScope observerScope(AuthUser user) {
        return user.getPermissions().contains("expense:view") ? readAccess.scope(user)
                : new com.uten.imp.security.OwnerVisibility.OwnerScope(false, Set.of(), Set.of());
    }

    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listBrowse(Integer year, Integer month, UUID departmentId,
            String category, int page, int size, String sort, String order, String claimNo) {
        require(requireStaff(), "expense:view");
        return listClaims(null, Set.of(), year, month, departmentId, normalizeCategory(category),
                page, size, true, false, sort, order, claimNo);
    }

    // ---- 查询 -----------------------------------------------------------------

    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listMine(
            String rawStatuses,
            Integer year,
            Integer month,
            UUID departmentId,
            String rawCategory,
            int page,
            int size) {
        return listMine(rawStatuses, year, month, departmentId, rawCategory,
                page, size, null, null, null);
    }

    /** 2026-09-25 单号列统一：报销单号表头排序（claimNo 白名单）+ 值筛选（精确匹配）。 */
    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listMine(
            String rawStatuses,
            Integer year,
            Integer month,
            UUID departmentId,
            String rawCategory,
            int page,
            int size,
            String sort,
            String order,
            String claimNo) { return listMine(rawStatuses, year, month, departmentId, rawCategory, page, size, sort, order, claimNo, false, false); }

    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listMine(
            String rawStatuses,
            Integer year,
            Integer month,
            UUID departmentId,
            String rawCategory,
            int page,
            int size,
            String sort,
            String order,
            String claimNo, boolean includeDeleted, boolean onlyDeleted) {
        return listMine(rawStatuses,year,month,departmentId,rawCategory,page,size,sort,order,claimNo,includeDeleted,onlyDeleted,false);
    }

    @Transactional(readOnly=true)
    public PageResponse<ExpenseClaimDto> listMine(String rawStatuses,Integer year,Integer month,UUID departmentId,String rawCategory,
            int page,int size,String sort,String order,String claimNo,boolean includeDeleted,boolean onlyDeleted,boolean includeAbandoned) {
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        var statuses=includeAbandoned&&(rawStatuses==null||rawStatuses.isBlank())?Set.of("PAID"):normalizeStatuses(rawStatuses);
        if(includeAbandoned&&!statuses.equals(Set.of("PAID")))throw new ApiException(ErrorCode.VALIDATION_FAILED,"已放弃报销仅可在历史单据中查看");
        return listClaims(
                user.getEmployeeId(),
                statuses,
                year,
                month,
                departmentId,
                normalizeCategory(rawCategory),
                page,
                size,
                true,
                false,
                sort,
                order,
                claimNo, includeDeleted || onlyDeleted, onlyDeleted,null,null,includeAbandoned);
    }

    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listPending(
            Integer year,
            Integer month,
            UUID departmentId,
            String rawCategory,
            int page,
            int size) {
        return listPending(year, month, departmentId, rawCategory, page, size,
                null, null, null);
    }

    /** 2026-09-25 单号列统一：报销单号表头排序（claimNo 白名单）+ 值筛选（精确匹配）。 */
    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listPending(
            Integer year,
            Integer month,
            UUID departmentId,
            String rawCategory,
            int page,
            int size,
            String sort,
            String order,
            String claimNo) {
        AuthUser user = requireStaff();
        if (!has(user,"expense:view")) requireApprover(user);
        return listClaims(
                null,
                Set.of("SUBMITTED", "REVIEWING"),
                year,
                month,
                departmentId,
                normalizeCategory(rawCategory),
                page,
                size,
                false,
                false,
                sort,
                order,
                claimNo);
    }

    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listPayable(
            Integer year,
            Integer month,
            UUID departmentId,
            String rawCategory,
            int page,
            int size) {
        return listPayable(year, month, departmentId, rawCategory, page, size,
                null, null, null);
    }

    /** 2026-09-25 单号列统一：报销单号表头排序（claimNo 白名单）+ 值筛选（精确匹配）。 */
    @Transactional(readOnly = true)
    public PageResponse<ExpenseClaimDto> listPayable(
            Integer year,
            Integer month,
            UUID departmentId,
            String rawCategory,
            int page,
            int size,
            String sort,
            String order,
            String claimNo) {
        AuthUser user = requireStaff();
        if (!has(user,"expense:view")) require(user, "expense:pay");
        return listClaims(
                null,
                Set.of("APPROVED"),
                year,
                month,
                departmentId,
                normalizeCategory(rawCategory),
                page,
                size,
                false,
                false,
                sort,
                order,
                claimNo);
    }

    /** 表头「类别」筛选（2026-09-16）：报销类别挂在明细项上，筛类别=存在任一命中类别的明细行；
     *  空白 → null（不过滤），非法值 fail-closed（与 CATEGORIES 白名单一致）。 */
    private static String normalizeCategory(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        String normalized = raw.trim().toUpperCase(Locale.ROOT);
        if (!CATEGORIES.contains(normalized)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报销类别无效");
        }
        return normalized;
    }

    @Transactional(readOnly=true)
    public PageResponse<ExpenseClaimDto> listHistory(Integer year,Integer month,UUID departmentId,String rawCategory,int page,int size) {
        return listHistory(year,month,departmentId,rawCategory,page,size,null,null,null);
    }

    /** 2026-09-25 单号列统一：报销单号表头排序（claimNo 白名单）+ 值筛选（精确匹配）。 */
    @Transactional(readOnly=true)
    public PageResponse<ExpenseClaimDto> listHistory(Integer year,Integer month,UUID departmentId,String rawCategory,int page,int size,
            String sort,String order,String claimNo) {
        AuthUser user=requireStaff();
        if(!has(user,"expense:view") && !ExpenseApprovalPolicy.hasAny(user) && !has(user,"expense:pay")) throw new ApiException(ErrorCode.FORBIDDEN);
        return listClaims(null,Set.of("SUBMITTED","REVIEWING","APPROVED","REJECTED","PAID"),year,month,departmentId,normalizeCategory(rawCategory),page,size,true,true,sort,order,claimNo);
    }

    @Transactional(readOnly=true)
    public PageResponse<ExpenseClaimDto> listScoped(String queue,Integer year,Integer month,UUID departmentId,String category,
            int page,int size,String sort,String order,String claimNo,String stage,String departmentCode) {
        AuthUser user=requireStaff();
        if(!has(user,"expense:view") && !ExpenseApprovalPolicy.hasAny(user) && !("history".equals(queue)&&has(user,"expense:pay"))) throw new ApiException(ErrorCode.FORBIDDEN);
        return listClaims(null,"history".equals(queue)?Set.of("SUBMITTED","REVIEWING","APPROVED","REJECTED","PAID"):Set.of("SUBMITTED","REVIEWING"),year,month,departmentId,normalizeCategory(category),
                page,size,true,"history".equals(queue),sort,order,claimNo,false,false,stage,departmentCode);
    }

    private PageResponse<ExpenseClaimDto> listClaims(
            UUID applicantId,
            Set<String> statuses,
            Integer year,
            Integer month,
            UUID departmentId,
            String category,
            int page,
            int size,
            boolean newestFirst) {
        return listClaims(applicantId,statuses,year,month,departmentId,category,page,size,newestFirst,false,null,null,null);
    }
    private PageResponse<ExpenseClaimDto> listClaims(UUID applicantId,Set<String> statuses,Integer year,Integer month,
            UUID departmentId,String category,int page,int size,boolean newestFirst,boolean history,
            String sort,String order,String claimNo) { return listClaims(applicantId,statuses,year,month,departmentId,category,page,size,newestFirst,history,sort,order,claimNo,false,false); }

    private PageResponse<ExpenseClaimDto> listClaims(UUID applicantId,Set<String> statuses,Integer year,Integer month,
            UUID departmentId,String category,int page,int size,boolean newestFirst,boolean history,
            String sort,String order,String claimNo,boolean includeDeleted,boolean onlyDeleted) {
        return listClaims(applicantId,statuses,year,month,departmentId,category,page,size,newestFirst,history,sort,order,claimNo,includeDeleted,onlyDeleted,null,null);
    }

    private PageResponse<ExpenseClaimDto> listClaims(UUID applicantId,Set<String> statuses,Integer year,Integer month,
            UUID departmentId,String category,int page,int size,boolean newestFirst,boolean history,
            String sort,String order,String claimNo,boolean includeDeleted,boolean onlyDeleted,String stage,String departmentCode) {
        return listClaims(applicantId,statuses,year,month,departmentId,category,page,size,newestFirst,history,sort,order,claimNo,includeDeleted,onlyDeleted,stage,departmentCode,false);
    }

    private PageResponse<ExpenseClaimDto> listClaims(UUID applicantId,Set<String> statuses,Integer year,Integer month,
            UUID departmentId,String category,int page,int size,boolean newestFirst,boolean history,String sort,String order,String claimNo,
            boolean includeDeleted,boolean onlyDeleted,String stage,String departmentCode,boolean includeAbandoned) {
        DateRange dateRange = createdAtRange(year, month);
        AuthUser reader = requireStaff();
        var observers = applicantId == null ? observerScope(reader) : null;
        Specification<ExpenseClaim> spec = (root, query, cb) -> {
            List<Predicate> predicates = new ArrayList<>();
            Predicate abandoned=cb.and(cb.isTrue(root.get("deleted")),cb.isNotNull(root.get("abandonedAt")),cb.equal(root.get("status"),"REJECTED"));
            if (onlyDeleted) predicates.add(cb.isTrue(root.get("deleted")));
            else if (!includeDeleted) predicates.add(includeAbandoned?cb.or(cb.isFalse(root.get("deleted")),abandoned):cb.isFalse(root.get("deleted")));
            if (applicantId == null) {
                UUID actor=reader.getEmployeeId();
                List<Predicate> visible=new ArrayList<>();
                if (observers.seeAll()) visible.add(cb.conjunction());
                else if (!observers.visibleOwners().isEmpty()) visible.add(root.get("applicantId").in(observers.visibleOwners()));
                if (history) {
                    if(ExpenseApprovalPolicy.hasAny(reader)) {
                        var events = query.subquery(UUID.class);
                        var event = events.from(ExpenseClaimEvent.class);
                        events.select(event.get("claimId")).where(cb.equal(event.get("actorEmployeeId"),actor),
                                event.get("eventType").in(Set.of("STAGE_APPROVED","APPROVED","REJECTED")));
                        visible.add(cb.and(cb.isFalse(cb.function("fn_finance_expense_is_application_managed",Boolean.class,root.get("id"))),root.get("id").in(events)));
                    }
                    if(has(reader,"expense:pay")) visible.add(cb.and(cb.isFalse(cb.function("fn_finance_expense_is_application_managed",Boolean.class,root.get("id"))),cb.equal(root.get("status"),"PAID")));
                } else if (statuses.contains("SUBMITTED") && ExpenseApprovalPolicy.hasAny(reader)) {
                    visible.add(cb.and(cb.isFalse(cb.function("fn_finance_expense_is_application_managed",Boolean.class,root.get("id"))),approvalPolicy.context(reader).predicate(root,cb)));
                } else if (statuses.contains("APPROVED") && has(reader,"expense:pay")) {
                    visible.add(cb.and(cb.isFalse(cb.function("fn_finance_expense_is_application_managed",Boolean.class,root.get("id"))),approvalPolicy.paymentPredicate(root,cb,reader)));
                }
                predicates.add(cb.or(visible.toArray(new Predicate[0])));
            }
            if (applicantId != null) {
                predicates.add(cb.equal(root.get("applicantId"), applicantId));
            }
            Predicate routingStale=cb.and(root.get("status").in(Set.of("SUBMITTED","REVIEWING")),cb.equal(root.get("approvalStage"),"DEPARTMENT"),
                    cb.isTrue(cb.function("fn_department_approval_snapshot_stale",Boolean.class,root.get("applicantId"),root.get("applicantDepartmentId"),root.get("departmentApprovalSnapshot"))));
            if(statuses.contains("ACTION_REQUIRED"))predicates.add(cb.or(cb.equal(root.get("status"),"REJECTED"),routingStale));
            else if (!statuses.isEmpty())predicates.add(includeAbandoned?cb.or(root.get("status").in(statuses),abandoned):root.get("status").in(statuses));
            if(applicantId!=null&&statuses.equals(Set.of("SUBMITTED","REVIEWING","APPROVED")))predicates.add(cb.not(routingStale));
            if (departmentId != null) {
                predicates.add(cb.equal(root.get("applicantDepartmentId"), departmentId));
            }
            if(stage!=null && !stage.isBlank()) {
                var stages=ExpenseApprovalPolicy.stages(stage);
                if(history) {
                    var filtered=query.subquery(UUID.class);var event=filtered.from(ExpenseClaimEvent.class);
                    filtered.select(event.get("claimId")).where(cb.equal(event.get("actorEmployeeId"),reader.getEmployeeId()),event.get("approvalStage").in(stages));
                    predicates.add(root.get("id").in(filtered));
                } else predicates.add(root.get("approvalStage").in(stages));
            }
            if(departmentCode!=null && !departmentCode.isBlank()) {
                var ids=approvalPolicy.context(reader).departmentCodes().entrySet().stream().filter(entry->departmentCode.equals(entry.getValue())).map(Map.Entry::getKey).toList();
                predicates.add(ids.isEmpty()?cb.disjunction():root.get("applicantDepartmentId").in(ids));
            }
            if (category != null) {
                jakarta.persistence.criteria.Subquery<UUID> itemIds = query.subquery(UUID.class);
                jakarta.persistence.criteria.Root<ExpenseClaimItem> item =
                        itemIds.from(ExpenseClaimItem.class);
                itemIds.select(item.get("claimId")).where(
                        cb.equal(item.get("category"), category));
                predicates.add(root.get("id").in(itemIds));
            }
            // 2026-09-25 单号列统一：报销单号表头值筛选（精确匹配）。
            if (claimNo != null && !claimNo.isBlank()) {
                predicates.add(cb.equal(root.get("claimNo"), claimNo.trim()));
            }
            if (dateRange != null) {
                predicates.add(cb.greaterThanOrEqualTo(
                        root.get("createdAt"), dateRange.fromInclusive()));
                predicates.add(cb.lessThan(
                        root.get("createdAt"), dateRange.toExclusive()));
            }
            return cb.and(predicates.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, claimSort(sort, order, newestFirst));
        Page<ExpenseClaim> result = claimRepository.findAll(spec, pageable);
        return new PageResponse<>(
                mapClaims(result.getContent()),
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                result.getTotalElements(),
                result.getTotalPages());
    }

    /** 排序白名单（2026-09-25 单号列统一）：claimNo → 单号属性；未知/空回落默认
     *  createdAt/id（newestFirst 决定方向）；单号排序稳定键追加默认两段。 */
    private static Sort claimSort(String rawSort, String rawOrder, boolean newestFirst) {
        Sort.Direction direction = newestFirst ? Sort.Direction.DESC : Sort.Direction.ASC;
        if ("claimNo".equals(rawSort == null ? "" : rawSort.strip())) {
            Sort.Direction claimDirection =
                    "desc".equalsIgnoreCase(rawOrder) ? Sort.Direction.DESC : Sort.Direction.ASC;
            return Sort.by(
                    new Sort.Order(claimDirection, "claimNo"),
                    new Sort.Order(direction, "createdAt"),
                    new Sort.Order(direction, "id"));
        }
        return Sort.by(
                new Sort.Order(direction, "createdAt"),
                new Sort.Order(direction, "id"));
    }

    @Transactional(readOnly = true)
    public ExpenseClaimDto detail(UUID id) { return readDetail(id, false); }

    @Transactional(readOnly = true)
    public ExpenseClaimDto detailHistory(UUID id) { return readDetail(id, true); }

    @Transactional(readOnly = true)
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(UUID id,Long beforeId,int size) {
        detailHistory(id);
        return retainedRecords.children("expense_claims",id,beforeId,size);
    }

    private ExpenseClaimDto readDetail(UUID id, boolean historyRead) {
        ExpenseClaim claim = requireClaim(id, historyRead);
        assertCanRead(claim);
        AuthUser user = requireStaff();
        List<AttachmentDto> attachments = has(user, "attachment:view")
                ? attachmentService.list("EXPENSE_CLAIM", id, historyRead, false)
                : List.of();
        Mapping context = detailContext(claim, attachments, historyRead);
        List<ExpenseClaimItem> items =
                itemsFor(List.of(claim)).getOrDefault(id, List.of());
        ExpenseClaimDto result = mapClaim(
                claim,
                items,
                context,
                context.invoices().stream().map(ExpenseClaimService::toInvoiceDto).toList(),
                context.events().stream().map(ExpenseClaimService::toEventDto).toList());
        if (historyRead || claim.isDeleted()) {
            result.history().copyHistoryFrom(retainedRecords.metadata("expense_claims",
                    List.of(new com.uten.imp.common.history.RetainedRecordReader.DocumentRef(claim.getId(),claim.isDeleted(),claim.getDeletedAt())),
                    historyRead).get(claim.getId()));
        }
        return withApplicationLinks(List.of(result)).getFirst();
    }

    private static ExpenseClaimInvoiceDto toInvoiceDto(ExpenseClaimInvoice invoice) {
        return new ExpenseClaimInvoiceDto(
                invoice.getId(),
                invoice.getLineNo(),
                invoice.getInvoiceType(),
                invoice.getInvoiceCode(),
                invoice.getInvoiceNo(),
                invoice.getIssueDate(),
                invoice.getSellerName(),
                invoice.getSellerTaxNo(),
                invoice.getBuyerName(),
                invoice.getAmountExclTax(),
                invoice.getTaxAmount(),
                invoice.getTotalAmount(),
                invoice.getCheckState(),
                invoice.getAttachmentId(),
                invoice.getRemark(), invoice.getBuyerTaxNo(), invoice.getVerificationRemark(),
                invoice.getVerifiedAt(), invoice.getVerifiedByName());
    }

    private static ExpenseClaimEventDto toEventDto(ExpenseClaimEvent event) {
        return new ExpenseClaimEventDto(
                event.getEventType(),
                event.getActorNameSnapshot(),
                event.getRemark(),
                event.getCreatedAt(),event.getApprovalStage(),event.getApprovalRound());
    }

    /** 详情形态映射上下文：部门名 + 操作人名 + 付款账户/费别名 + 发票 + 事件。 */
    private Mapping detailContext(ExpenseClaim claim, List<AttachmentDto> attachments, boolean historyRead) {
        List<ExpenseClaimInvoice> invoices =
                invoiceRepository.findByClaimIdOrderByLineNoAsc(claim.getId());
        List<ExpenseClaimEvent> events =
                eventRepository.findByClaimIdOrderByCreatedAtAscIdAsc(claim.getId());
        var labels = paymentLabels.resolve(claim.getPaymentAccountId(), claim.getPaymentExpenseStyleId());
        Map<UUID, String> accountNames = labels.account() == null ? Map.of()
                : Map.of(claim.getPaymentAccountId(), labels.account());
        Map<UUID, String> styleNames = labels.expenseStyle() == null ? Map.of()
                : Map.of(claim.getPaymentExpenseStyleId(), labels.expenseStyle());
        return new Mapping(
                departmentNamesFor(List.of(claim)),
                actorNamesFor(List.of(claim)),
                accountNames,
                styleNames,
                attachments,
                invoices,
                events,
                has(requireStaff(),"attachment:view") ? attachmentService.list(
                        ExpensePaymentProofAttachmentAccessPolicy.OWNER_TYPE,claim.getId(),historyRead,false) : List.of());
    }

    /**
     * 审批/打款队列表头筛选桶（2026-09-10 表头筛选接后端）：按队列状态集聚合部门与年月。
     * 权限口径与对应列表一致：pending=expense:approve，payable=expense:pay。
     */
    @Transactional(readOnly = true)
    public ExpenseClaimFacetsDto facets(String queue) { return facets(queue,false,false); }

    @Transactional(readOnly = true)
    public ExpenseClaimFacetsDto facets(String queue, boolean includeDeleted, boolean onlyDeleted) {
        return facets(queue,includeDeleted,onlyDeleted,null,null);
    }
    @Transactional(readOnly=true)
    public ExpenseClaimFacetsDto facets(String queue,boolean includeDeleted,boolean onlyDeleted,String stage,String departmentCode) {
        return facets(queue,includeDeleted,onlyDeleted,stage,departmentCode,false);
    }
    @Transactional(readOnly=true)
    public ExpenseClaimFacetsDto facets(String queue,boolean includeDeleted,boolean onlyDeleted,String stage,String departmentCode,boolean includeAbandoned) {
        AuthUser user = requireStaff();
        if(includeAbandoned) {
            require(user,"expense:apply");
            if(!"minehistory".equalsIgnoreCase(queue))throw new ApiException(ErrorCode.VALIDATION_FAILED,"已放弃报销仅可在历史单据中查看");
            return applicantQuery.abandonedHistoryFacets(user.getEmployeeId(),includeDeleted||onlyDeleted,onlyDeleted);
        }
        queue=queue==null?"":queue.trim().toLowerCase(Locale.ROOT);
        if (Set.of("pending","payable","history","browse").contains(queue)) {
            if(!has(user,"expense:view") && !("pending".equals(queue)&&ExpenseApprovalPolicy.hasAny(user))
                    && !("payable".equals(queue)&&has(user,"expense:pay"))
                    && !("history".equals(queue)&&(ExpenseApprovalPolicy.hasAny(user)||has(user,"expense:pay"))))throw new ApiException(ErrorCode.FORBIDDEN);
            return applicantQuery.workflowFacets(user,observerScope(user),queue,stage,departmentCode);
        }
        switch (queue == null ? "" : queue.trim().toLowerCase(Locale.ROOT)) {
            case "mineactive", "minehistory" -> {
                require(user,"expense:apply");
                return new ExpenseClaimFacetsDto(List.of(),List.of(),List.of(),toBuckets(applicantQuery.mineClaimNoFacets(
                        user.getEmployeeId(),includeDeleted||onlyDeleted,onlyDeleted,"minehistory".equalsIgnoreCase(queue))));
            }
            case "mine" -> {
                require(user,"expense:apply");
                return new ExpenseClaimFacetsDto(List.of(),List.of(),List.of(),toBuckets(applicantQuery.mineClaimNoFacets(user.getEmployeeId(),includeDeleted||onlyDeleted,onlyDeleted)));
            }
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED,"未知报销队列");
        }
    }

    private static List<ExpenseClaimFacetsDto.Bucket> toBuckets(
            List<ExpenseApplicantQuery.FacetRow> rows) {
        return rows.stream()
                .map(row -> new ExpenseClaimFacetsDto.Bucket(row.value(), row.label(), row.count()))
                .toList();
    }

    /**
     * 队列汇总（V608 审批页统计卡）：待审批/待打款单数与金额 + 本月提交 + 本月打款。
     * 权限：approve 或 pay 任一；金额口径为状态全集（与队列列表一致）。
     */
    @Transactional(readOnly = true)
    public ExpenseClaimSummaryDto summary() {
        AuthUser user = requireStaff();
        if (!has(user,"expense:view") && !ExpenseApprovalPolicy.hasAny(user) && !has(user, "expense:pay")) {
            throw new ApiException(ErrorCode.FORBIDDEN);
        }
        Object[] pending=ExpenseApprovalPolicy.hasAny(user) ? actionable(user,false) : null;
        Object[] payable=has(user,"expense:pay") ? actionable(user,true) : null;
        // Browsing keeps the session's read authority; task counts use the same actual-grant
        // projection as /counts, so administrative capability never becomes a subscription.
        long[] tasks=taskAudience==null?new long[]{count(pending),count(payable)}:taskAudience.read(()->{
            AuthUser participant=requireStaff();
            var counts=applicantQuery.workflowCounts(participant,approvalPolicy.context(participant),false,has(participant,"expense:pay"));
            return new long[]{counts.pendingApprovalCount(),counts.pendingPaymentCount()};
        });
        return applicantQuery.observerSummary(user, observerScope(user)).withActionableCounts(tasks[0],tasks[1]);
    }

    /**
     * 报销计数：一次往返取齐五档(准则 §五)。ADR-100 补上本人「处理中」后若继续逐档 count
     * 就是第 5 次往返，故合并进 {@link ExpenseApplicantQuery#queueCounts} 的单条 SELECT，
     * 没有权限的档在 SQL 里就短路成 0。
     */
    @Transactional(readOnly=true)
    @com.uten.imp.security.BusinessTaskRead
    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimCountsDto counts() {
        AuthUser user=requireStaff();
        boolean apply=has(user,"expense:apply");
        boolean approve=ExpenseApprovalPolicy.hasAny(user);
        boolean pay=has(user,"expense:pay");
        if(!apply && !approve && !pay) throw new ApiException(ErrorCode.FORBIDDEN);
        return applicantQuery.workflowCounts(user,approvalPolicy.context(user),apply,pay);
    }

    private Object[] actionable(AuthUser user,boolean payment) {
        return (Object[]) em.createNativeQuery("SELECT COUNT(*),COALESCE(SUM(c.total_amount),0) FROM expense_claims c WHERE NOT c.is_deleted AND "+(payment?ExpenseApprovalPolicy.paymentSql("c",user):approvalPolicy.context(user).sql("c"))).getSingleResult();
    }
    private static Object[] aggregateRow(Object[] aggregate) {
        return aggregate!=null && aggregate.length==1 && aggregate[0] instanceof Object[] nested ? nested : aggregate;
    }
    private static long count(Object[] aggregate) {
        Object[] row=aggregateRow(aggregate);
        return row==null || row.length<2?0:((Number)row[0]).longValue();
    }
    private static BigDecimal amount(Object[] aggregate) {
        Object[] row=aggregateRow(aggregate);
        return row==null || row.length<2 || row[1]==null?BigDecimal.ZERO.setScale(2):(BigDecimal)row[1];
    }

    private void expectedVersion(UUID id, Long expected) {
        if(expected==null || expected<0) throw new ApiException(ErrorCode.VALIDATION_FAILED,"页面数据不完整，请刷新页面后重试");
        ExpenseClaim claim=requireClaimForUpdate(id);
        assertCanRead(claim);
        if(claim.getVersion()!=expected) throw new ApiException(ErrorCode.CONFLICT,"报销单已更新，请刷新后重新核对");
    }
    @Transactional public ExpenseClaimDto submit(UUID id,Long version) { expectedVersion(id,version);return submit(id); }
    @Transactional public ExpenseClaimDto withdraw(UUID id,Long version) { expectedVersion(id,version);return withdraw(id); }
    @Transactional public ExpenseClaimDto approve(UUID id,Long version) { expectedVersion(id,version);return approve(id); }
    @Transactional public ExpenseClaimDto reject(UUID id,String reason,Long version) { expectedVersion(id,version);return reject(id,reason); }
    @Transactional public void delete(UUID id,Long version) { expectedVersion(id,version);delete(id); }
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="expense_claim_item", requestArgument=1, documentIdArgument=0)
    @Transactional public ExpenseClaimDto editVersioned(UUID id,ExpenseClaimCreateRequest request) { expectedVersion(id,request.expectedVersion());return edit(id,request); }
    @Transactional public ExpenseClaimDto payVersioned(UUID id,ExpenseClaimPaymentRequest request) {
        PaymentStyleHierarchyLock.lock(em);
        ExpenseClaim claim=requireClaimForUpdate(id);
        assertCanRead(claim);
        // A retry may carry the pre-payment version; the completed payment identity still must match.
        if(!"PAID".equals(claim.getStatus())) expectedVersion(id,request.expectedVersion());
        else if(request.expectedVersion()==null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"页面数据不完整，请刷新页面后再打款");
        return pay(id,request);
    }
    @Transactional public ExpenseClaimDto addInvoiceVersioned(UUID id,ExpenseClaimInvoiceInput input) { expectedVersion(id,input.expectedVersion());return addInvoice(id,input); }
    @Transactional public ExpenseClaimDto updateInvoiceVersioned(UUID id,UUID invoiceId,ExpenseClaimInvoiceInput input) { expectedVersion(id,input.expectedVersion());return updateInvoice(id,invoiceId,input); }
    @Transactional public ExpenseClaimDto deleteInvoice(UUID id,UUID invoiceId,Long version) { expectedVersion(id,version);return deleteInvoice(id,invoiceId); }
    @Transactional public ExpenseClaimBatchResultDto batchVersioned(ExpenseClaimBatchRequest request,boolean approved) {
        if(request.ids()==null || request.ids().isEmpty() || request.ids().size()>50 || request.ids().stream().anyMatch(Objects::isNull)
                || request.expectedVersions()==null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"部分报销单的页面数据不完整，请刷新后重新勾选");
        for(UUID id:request.ids().stream().distinct().sorted().toList()) expectedVersion(id,request.expectedVersions().get(id));
        return approved?approveBatch(request):rejectBatch(request);
    }

    private void validateEvidence(ExpenseClaim claim,boolean approving) {
        List<ExpenseClaimItem> items=itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(List.of(claim.getId()));
        if(items.isEmpty() || items.stream().anyMatch(item->item.getExpenseDate()==null
                || item.getExpenseDate().isAfter(BusinessTime.today()) || trimToNull(item.getDescription())==null))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请完整填写费用日期及每项费用用途说明");
        var originals=attachmentRepository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(
                "EXPENSE_CLAIM",claim.getId(),AttachmentLifecycleState.CLEAN);
        if(originals.isEmpty()) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先上传并完成扫描确认的原始凭证附件");
        var invoices=invoiceRepository.findByClaimIdOrderByLineNoAsc(claim.getId());
        if(invoices.isEmpty()) {
            if(settings.get().requireInvoice()) throw new ApiException(ErrorCode.VALIDATION_FAILED,"公司报销设置要求登记票据");
            if(trimToNull(claim.getRemark())==null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"未登记发票时请在备注说明凭证类型及报销依据");
        }
        Set<UUID> ids=originals.stream().map(a->a.getId()).collect(Collectors.toSet());
        for(var invoice:invoices) {
            if(invoice.getIssueDate()==null || invoice.getIssueDate().isAfter(BusinessTime.today())
                    || invoice.getAttachmentId()==null || !ids.contains(invoice.getAttachmentId()))
                throw new ApiException(ErrorCode.VALIDATION_FAILED,"每张票据须有开具日期并关联本单已扫描确认的原件附件");
            if("MISMATCH".equals(invoice.getCheckState())) throw new ApiException(ErrorCode.VALIDATION_FAILED,"票据存在核对差异，请修正后重提");
            if(approving && !"VERIFIED_MANUAL".equals(invoice.getCheckState()))
                throw new ApiException(ErrorCode.VALIDATION_FAILED,"请逐张核对票据并记录查验依据后再批准");
        }
        BigDecimal covered=invoices.stream().map(ExpenseClaimInvoice::getTotalAmount).reduce(BigDecimal.ZERO,BigDecimal::add);
        if(!invoices.isEmpty() && covered.compareTo(claim.getTotalAmount())<0 && trimToNull(claim.getRemark())==null)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"报销金额超过已登记票据金额，请在备注说明其他凭证依据");
    }

    @Transactional
    public ExpenseClaimDto verifyInvoice(UUID claimId,UUID invoiceId,com.uten.imp.features.expenseclaim.dto.ExpenseClaimInvoiceVerifyRequest input) {
        AuthUser user=requireStaff();boolean applicationManaged=applicationControl!=null&&applicationControl.expenseManaged(claimId);
        if(applicationManaged)applicationControl.requireExpenseInvoiceVerification(claimId);else {if(applicationControl!=null){applicationControl.requireExpenseMainAuthority(claimId);}requireApprover(user);}require(user,"attachment:view");require(user,"attachment:download");
        expectedVersion(claimId,input.expectedVersion());
        ExpenseClaim claim=requireClaimForUpdate(claimId);
        if(!applicationManaged){
            approvalPolicy.requireApprove(user,claim);
            if(!Set.of(ExpenseApprovalPolicy.FINANCE_INITIAL,ExpenseApprovalPolicy.FINANCE_REVIEW).contains(claim.getApprovalStage()))
                throw new ApiException(ErrorCode.FORBIDDEN,"票据查验由当前财务初核或复核节点办理");
        }
        if(user.getEmployeeId().equals(claim.getApplicantId())) throw new ApiException(ErrorCode.FORBIDDEN,"不能核验自己的报销票据");
        if(!Set.of("SUBMITTED","REVIEWING").contains(claim.getStatus())) throw stateConflict(claim);
        if(!applicationManaged)taskClaim.requireNoActiveClaimByOther(TASK_TYPE_APPROVE,claimId.toString());
        if(input.result()==null || !Set.of("VERIFIED_MANUAL","MISMATCH").contains(input.result())
                || trimToNull(input.remark())==null || input.remark().trim().length()>500)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择核对结论并填写查验渠道、日期及结果依据");
        var invoice=invoiceRepository.findById(invoiceId).filter(row->claimId.equals(row.getClaimId()))
                .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"票据不存在"));
        if("VERIFIED_MANUAL".equals(input.result()) && invoice.getAmountExclTax()!=null && invoice.getTaxAmount()!=null
                && invoice.getAmountExclTax().add(invoice.getTaxAmount()).subtract(invoice.getTotalAmount()).abs().compareTo(new BigDecimal("0.01"))>0)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"票面金额勾稽不符，须驳回修正");
        tx.bind();
        invoice.setCheckState(input.result()); invoice.setVerificationRemark(input.remark().trim());
        invoice.setVerifiedBy(user.getEmployeeId()); invoice.setVerifiedAt(Instant.now());
        invoice.setVerifiedByName(applicantQuery.employeeNames(List.of(user.getEmployeeId())).getOrDefault(user.getEmployeeId(),user.getUsername()));
        invoiceRepository.save(invoice); claim.setUpdatedAt(Instant.now());
        appendEvent(claimId,"EDITED",user,("VERIFIED_MANUAL".equals(input.result())?"票据人工核对通过: ":"票据人工核对不符: ")+input.remark().trim());
        return mapClaimWithItems(claim);
    }

    // ---- 申请人动作 ------------------------------------------------------------

    @Transactional
    @com.uten.imp.common.platformcolumns.PlatformColumnDocumentSave(scope="expense_claim_item")
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
        claim.setClaimNo(docNumber.nextNumber(DocNumberPrefix.EXPENSE_CLAIM));
        claim.setTitle(request.title().trim());
        claim.setExpenseKind(expenseKind(request));
        claim.setTotalAmount(total);
        claim.setStatus("DRAFT");
        claim.setRemark(trimToNull(request.remark()));
        claimRepository.save(claim);
        List<ExpenseClaimItem> items = appendItems(claim, validated);
        appendEvent(claim.getId(), "CREATED", user, null);
        if(applicationControl!=null){claimRepository.flush();itemRepository.flush();registerApplicationSource(claim.getId(),request);}
        return mapClaimWithItems(claim, items);
    }

    /**
     * 编辑（V608）：仅 DRAFT / REJECTED 且本人。明细整组替换（行号重排），
     * 合计重算；REJECTED 编辑后仍是 REJECTED，由 {@link #submit} 重提。
     */
    @Transactional
    public ExpenseClaimDto edit(UUID id, ExpenseClaimCreateRequest request) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        ExpenseClaim claim = requireClaimForUpdate(id);
        assertOwner(claim, user);
        if (!EDITABLE_STATUSES.contains(claim.getStatus())) {
            throw stateConflict(claim);
        }
        List<ValidatedItem> validated = request.items().stream()
                .map(this::validateItem)
                .toList();
        BigDecimal total = validated.stream()
                .map(ValidatedItem::amount)
                .reduce(BigDecimal.ZERO.setScale(2), BigDecimal::add);
        if (total.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报销合计必须大于零");
        }
        claim.setTitle(request.title().trim());
        claim.setExpenseKind(request.expenseKind()==null&&request.applicationKind()==null?claim.getExpenseKind():expenseKind(request));
        claim.setRemark(trimToNull(request.remark()));
        claim.setTotalAmount(total);
        claimRepository.save(claim);
        itemRepository.deleteByClaimId(id);
        itemRepository.flush();
        List<ExpenseClaimItem> items = appendItems(claim, validated);
        appendEvent(claim.getId(), "EDITED", user,
                "REJECTED".equals(claim.getStatus()) ? "驳回后修订" : null);
        if(applicationControl!=null){claimRepository.flush();itemRepository.flush();registerApplicationSource(id,request);}
        return mapClaimWithItems(claim, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        ExpenseClaim claim = requireClaimForUpdate(id);
        assertOwner(claim, user);
        assertStatus(claim, "DRAFT");
        claim.setDeleted(true);
        claim.setDeletedAt(java.time.OffsetDateTime.now());
        claimRepository.save(claim);
        em.createNativeQuery("UPDATE expense_claim_invoices SET is_archived=true WHERE claim_id=:id AND NOT is_archived")
                .setParameter("id",id).executeUpdate();
    }

    /** Abandon a rejected reimbursement without inventing a submission or changing its business status. */
    @Transactional
    public ExpenseClaimDto abandon(UUID id,Long version) {
        tx.bind();AuthUser user=requireStaff();require(user,"expense:apply");
        if(version==null||version<0)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请刷新报销单后再放弃");
        ExpenseClaim claim=claimRepository.findByIdForUpdateIncludingDeleted(id).orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"报销单不存在"));
        assertOwner(claim,user);
        if(claim.isDeleted()&&claim.getAbandonedAt()!=null&&"REJECTED".equals(claim.getStatus()))return readDetail(id,true);
        if(claim.isDeleted())throw new ApiException(ErrorCode.NOT_FOUND,"报销单不存在");
        if(claim.getVersion()!=version)throw new ApiException(ErrorCode.CONFLICT,"报销单已更新，请刷新后重新核对");
        assertStatus(claim,"REJECTED");
        if(claim.getPaidAt()!=null||claim.getPaidBy()!=null||claim.getFinanceExpenseId()!=null||claim.getPaymentAccountId()!=null||claim.getPaymentDate()!=null)
            throw new ApiException(ErrorCode.CONFLICT,"报销单存在付款或未知付款事实，不能放弃");
        if(Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM attachments WHERE owner_type='EXPENSE_PAYMENT_PROOF' AND owner_id=:id)").setParameter("id",id).getSingleResult()))
            throw new ApiException(ErrorCode.CONFLICT,"报销单存在付款凭据，须先核实付款现状，不能直接放弃");
        taskClaim.releaseAfterBusinessResolution(TASK_TYPE_APPROVE,id.toString());
        Instant now=Instant.now();claim.setAbandonedAt(now);claim.setDeleted(true);claim.setDeletedAt(java.time.OffsetDateTime.now());
        claimRepository.saveAndFlush(claim);
        em.createNativeQuery("UPDATE expense_claim_invoices SET is_archived=true WHERE claim_id=:id AND NOT is_archived").setParameter("id",id).executeUpdate();
        appendEvent(id,"ABANDONED",user,"申请人放弃本次报销，驳回原因、原件及审批历史保留",claim.getApprovalStage(),claim.getApprovalRound());
        hrNotice.resolveExpenseClaim(id,"ABANDONED");
        return readDetail(id,true);
    }

    /**
     * 提交审批：DRAFT 首提，或 REJECTED 修订后重提（V608；重提清驳回痕迹并重新通知审批人）。
     */
    @Transactional
    public ExpenseClaimDto submit(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        ExpenseClaim claim = requireClaimForUpdate(id);
        assertOwner(claim, user);
        if (!Set.of("DRAFT", "REJECTED").contains(claim.getStatus())) {
            throw stateConflict(claim);
        }
        if(applicationControl!=null)applicationControl.requireExpenseMainAuthority(id);
        if(nativeOrigins!=null)nativeOrigins.requireReady("EXPENSE_CLAIM",id);
        if(applicationSources!=null)applicationSources.validateForSubmit(id);
        validateEvidence(claim, false);
        var applicant=applicantQuery.findEligible(user.getEmployeeId()).orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN,"当前员工档案不可申请报销"));
        claim.setApplicantDepartmentId(applicant.departmentId());claim.setApplicantNameSnapshot(applicant.name());
        boolean applicationManaged=applicationControl!=null&&applicationControl.expenseManaged(id);
        if(!applicationManaged){
            claim.setDepartmentApprovalSnapshot(departmentRouting.capture(claim.getApplicantId(),claim.getApplicantDepartmentId()));
            approvalPolicy.requireNext(claim,ExpenseApprovalPolicy.DEPARTMENT,"");
        }
        boolean rejectedResubmit = "REJECTED".equals(claim.getStatus());
        boolean resubmit = claim.getSubmissionSnapshot() != null || claim.getSubmittedAt() != null
                || rejectedResubmit
                || eventRepository.existsByClaimIdAndEventType(id, "SUBMITTED");
        claim.setPreviousSubmissionSnapshot(claim.getSubmissionSnapshot());
        claim.setSubmissionSnapshot(submissionSnapshot(claim));
        claim.setResubmission(resubmit);
        for(var invoice:invoiceRepository.findByClaimIdOrderByLineNoAsc(id)) {
            if("VERIFIED_MANUAL".equals(invoice.getCheckState())) invoice.setCheckState("UNCHECKED");
            invoice.setVerifiedAt(null);invoice.setVerifiedBy(null);invoice.setVerifiedByName(null);invoice.setVerificationRemark(null);
            invoiceRepository.save(invoice);
        }
        hrNotice.resolveExpenseClaim(id, "RESUBMITTED");
        Instant now = Instant.now();
        claim.setStatus("SUBMITTED");
        claim.setApprovalStage(applicationManaged?null:ExpenseApprovalPolicy.DEPARTMENT);
        claim.setApprovalRound(claim.getApprovalRound()+1);
        claim.setApprovalParticipants("");
        claim.setApprovedBy(null);
        claim.setApprovedAt(null);
        claim.setSubmittedBy(user.getEmployeeId());
        claim.setSubmittedAt(now);
        claim.setRejectReason(null);
        claim.setRejectedBy(null);
        claim.setRejectedAt(null);
        claimRepository.save(claim);
        appendEvent(claim.getId(), "SUBMITTED", user,
                rejectedResubmit ? "驳回后重新提交" : resubmit ? "撤回后重新提交" : null);
        // 提交 → 通知审批人（弹卡 + 通知；2026-09-09 人事通知接入）
        claimRepository.flush();invoiceRepository.flush();
        if(applicationManaged)applicationControl.expenseSubmitted(id);
        if(!applicationManaged)hrNotice.notifyExpenseClaimStage(
                claim.getId(), claim.getApplicantNameSnapshot(),
                claim.getTotalAmount().toPlainString() + " 元",
                claim.getApplicantId(), claim.getApplicantDepartmentId(), claim.getApprovalStage());
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
        // A submitted document is frozen for applicant edits, so it is safe to
        // retain a missing legacy snapshot before withdrawal makes it editable.
        preserveSubmittedSnapshot(claim);
        for(var invoice:invoiceRepository.findByClaimIdOrderByLineNoAsc(id)) {
            if("VERIFIED_MANUAL".equals(invoice.getCheckState())) invoice.setCheckState("UNCHECKED");
            invoice.setVerifiedBy(null);invoice.setVerifiedAt(null);invoice.setVerifiedByName(null);invoice.setVerificationRemark(null);
            invoiceRepository.save(invoice);
        }
        taskClaim.releaseAfterBusinessResolution(TASK_TYPE_APPROVE,id.toString());
        claim.setStatus("DRAFT");
        claim.setApprovalStage(ExpenseApprovalPolicy.DEPARTMENT);
        claim.setApprovalParticipants("");
        claim.setSubmittedBy(null);
        claim.setDepartmentApprovalSnapshot(null);
        claim.setSubmittedAt(null);
        claimRepository.save(claim);
        appendEvent(claim.getId(), "WITHDRAWN", user, null);
        // 撤回 → 办结审批人弹卡
        hrNotice.resolveExpenseClaim(claim.getId(), "WITHDRAWN");
        if(applicationControl!=null){claimRepository.flush();applicationControl.expenseWithdrawn(id);}
        return mapClaimWithItems(claim);
    }

    // ---- 审批 / 打款 ------------------------------------------------------------

    @Transactional
    public ExpenseClaimDto approve(UUID id) {
        tx.bind();
        AuthUser user = requireStaff();
        requireApprover(user);
        return decide(user, id, true);
    }

    @Transactional
    public ExpenseClaimDto reject(UUID id, String reason) {
        tx.bind();
        AuthUser user = requireStaff();
        requireApprover(user);
        return decide(user, id, false, reason);
    }

    /**
     * 批量通过（V608）：单事务、稳定 UUID 顺序，任一单失败整批回滚
     * （对齐财务订货审批 approveBatch 语义，替代前端逐单循环）。
     */
    @Transactional
    public ExpenseClaimBatchResultDto approveBatch(ExpenseClaimBatchRequest request) {
        AuthUser user = requireStaff();
        requireApprover(user);
        List<UUID> ids = request.ids().stream().distinct().sorted().toList();
        for (UUID id : ids) {
            decide(user, id, true);
        }
        return new ExpenseClaimBatchResultDto(ids.size());
    }

    /** 批量驳回：统一原因必填，单事务全成全败。 */
    @Transactional
    public ExpenseClaimBatchResultDto rejectBatch(ExpenseClaimBatchRequest request) {
        AuthUser user = requireStaff();
        requireApprover(user);
        String reason = request.reason() == null ? "" : request.reason().trim();
        if (reason.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "批量驳回必须填写原因");
        }
        List<UUID> ids = request.ids().stream().distinct().sorted().toList();
        for (UUID id : ids) {
            decide(user, id, false, reason);
        }
        return new ExpenseClaimBatchResultDto(ids.size());
    }

    private ExpenseClaimDto decide(AuthUser user, UUID id, boolean approved) {
        return decide(user, id, approved, null);
    }

    private ExpenseClaimDto decide(AuthUser user, UUID id, boolean approved, String reason) {
        return decide(user,id,approved,reason,false);
    }
    private ExpenseClaimDto decide(AuthUser user, UUID id, boolean approved, String reason,boolean applicationDecision) {
        tx.bind();
        if(applicationDecision)require(user,"finance_application:review");else requireApprover(user);
        if(applicationDecision){if(applicationControl==null)throw new ApiException(ErrorCode.CONFLICT,"原申请流程尚未准备好");applicationControl.requireExpenseDecisionContext(id);}
        else if(applicationControl!=null)applicationControl.requireLegacyExpenseDecision(id);
        // 并发认领守卫（show-as-locked 的服务端兜底）：若他人正认领该报销单审批，拒绝重复操作。
        // 认领只是 UX/防碰撞层，下方 requireClaimForUpdate 的悲观锁 + 状态前置条件仍是正确性底线。
        if(!applicationDecision)taskClaim.requireNoActiveClaimByOther(TASK_TYPE_APPROVE, id.toString());
        ExpenseClaim claim = requireClaimForUpdate(id);
        if (claim.getApplicantId().equals(user.getEmployeeId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "申请人不能审批自己的报销单");
        }
        if(!applicationDecision)approvalPolicy.requireApprove(user,claim);
        if(approved&&nativeOrigins!=null)nativeOrigins.requireReady("EXPENSE_CLAIM",id);
        if(!applicationDecision&&ExpenseApprovalPolicy.DEPARTMENT.equals(claim.getApprovalStage()))departmentRouting.requireReviewForUpdate(user,claim.getApplicantId(),claim.getApplicantDepartmentId(),claim.getDepartmentApprovalSnapshot());
        if (!Set.of("SUBMITTED", "REVIEWING").contains(claim.getStatus())) {
            throw stateConflict(claim);
        }
        preserveSubmittedSnapshot(claim);
        if (approved) {
            require(user,"attachment:view");
            require(user,"attachment:download");
            String stage=claim.getApprovalStage();
            validateEvidence(claim, !ExpenseApprovalPolicy.DEPARTMENT.equals(stage));
            String next=applicationDecision?null:ExpenseApprovalPolicy.next(stage);
            if(!applicationDecision)approvalPolicy.requireNext(claim,next,(claim.getApprovalParticipants()==null?"":claim.getApprovalParticipants())+user.getEmployeeId()+",");
            if(!applicationDecision&&next==null)approvalPolicy.requirePaymentOperator(claim,(claim.getApprovalParticipants()==null?"":claim.getApprovalParticipants())+user.getEmployeeId()+",",
                    !attachmentRepository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(ExpensePaymentProofAttachmentAccessPolicy.OWNER_TYPE,id,AttachmentLifecycleState.CLEAN).isEmpty());
            claim.setApprovalParticipants((claim.getApprovalParticipants()==null?"":claim.getApprovalParticipants())+user.getEmployeeId()+",");
            claim.setApprovalStage(next);
            claim.setStatus(next==null?"APPROVED":"REVIEWING");
            if(next==null) {claim.setApprovedBy(user.getEmployeeId());claim.setApprovedAt(Instant.now());}
            claimRepository.save(claim);
            appendApprovalEvent(claim, next==null?"APPROVED":"STAGE_APPROVED", stage,user,ExpenseApprovalPolicy.label(stage)+"通过");
            if(!applicationDecision)taskClaim.releaseAfterBusinessResolution(TASK_TYPE_APPROVE,id.toString());
            // 审批通过 → 打款人弹卡接棒 + 申请人回执；办结「待审批」卡
            // 先办结「待审批」卡再发「待打款」卡：两卡同聚合 (EXPENSE_CLAIM, claimId)，
            // 顺序反了会把新卡一起撤掉。
            hrNotice.resolveExpenseClaim(claim.getId(), "APPROVED_TO_PAY");
            if(!applicationDecision&&next==null) hrNotice.notifyExpenseClaimApproved(
                    claim.getId(), claim.getApplicantNameSnapshot(),
                    claim.getTotalAmount().toPlainString() + " 元",
                    userIdOfEmployee(claim.getApplicantId()),
                    claim.getApplicantId(), claim.getApprovedBy());
            else if(!applicationDecision)hrNotice.notifyExpenseClaimStage(claim.getId(),claim.getApplicantNameSnapshot(),
                    claim.getTotalAmount().toPlainString()+" 元",claim.getApplicantId(),claim.getApplicantDepartmentId(),next);
        } else {
            String normalized = reason == null ? "" : reason.trim();
            if (normalized.isEmpty()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "请填写驳回原因");
            }
            claim.setStatus("REJECTED");
            claim.setRejectReason(normalized);
            claim.setRejectedBy(user.getEmployeeId());
            claim.setRejectedAt(Instant.now());
            claim.setApprovedBy(null);
            claim.setApprovedAt(null);
            claimRepository.save(claim);
            appendApprovalEvent(claim,"REJECTED",claim.getApprovalStage(),user,normalized);
            if(!applicationDecision)taskClaim.releaseAfterBusinessResolution(TASK_TYPE_APPROVE,id.toString());
            hrNotice.resolveExpenseClaim(claim.getId(), "REJECTED");
            if(!applicationDecision)hrNotice.notifyExpenseClaimRejected(
                    claim.getId(), normalized, userIdOfEmployee(claim.getApplicantId()));
        }
        return mapClaimWithItems(claim);
    }

    @Transactional
    public ExpenseClaimDto pay(UUID id, ExpenseClaimPaymentRequest request) {
        tx.bind();
        AuthUser user = requireStaff();
        require(user, "expense:pay");
        PaymentStyleHierarchyLock.lock(em);
        ExpenseClaim claim = requireClaimForUpdate(id);
        if (claim.getApplicantId().equals(user.getEmployeeId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "申请人不能给自己的报销单打款");
        }
        if ("PAID".equals(claim.getStatus())) {
            if (request.accountId().equals(claim.getPaymentAccountId())
                    && request.expenseStyleId().equals(claim.getPaymentExpenseStyleId())
                    && request.paymentDate().equals(claim.getPaymentDate())
                    && com.uten.imp.common.finance.AccountingExpensePurpose.parse(request.postingPurpose()).name().equals(claim.getPaymentPostingPurpose())
                    && claim.getFinanceExpenseId() != null) {
                return mapClaimWithItems(claim);
            }
            throw new ApiException(ErrorCode.CONFLICT, "报销单已使用其他打款参数完成支付");
        }
        assertStatus(claim, "APPROVED");
        boolean applicationManaged=applicationControl!=null&&applicationControl.expenseManaged(id);
        if(applicationManaged)applicationControl.requireExpensePayment(id);else if(applicationControl!=null)applicationControl.requireExpenseMainAuthority(id);
        if(nativeOrigins!=null)nativeOrigins.requireReady("EXPENSE_CLAIM",id);
        if(applicationManaged?user.getEmployeeId().equals(claim.getApprovedBy()):!approvalPolicy.canPay(user,claim)) {
            throw new ApiException(ErrorCode.FORBIDDEN,"本轮审批人与实际打款人须分离");
        }
        if(request.paymentDate()==null || request.paymentDate().isAfter(BusinessTime.today())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"付款日期不能为空或晚于今天");
        }

        if(!(applicationControl!=null&&applicationControl.expenseManaged(id)) && attachmentRepository.findByOwnerTypeAndOwnerIdAndLifecycleStateOrderByCreatedAtAsc(
                ExpensePaymentProofAttachmentAccessPolicy.OWNER_TYPE,id,AttachmentLifecycleState.CLEAN).isEmpty())
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先上传银行付款回单或现金签收凭据并等待扫描完成，再登记付款");

        UUID financeExpenseId = postingPort.postEmployeeClaim(
                new EmployeeClaimPosting(
                        claim.getId(),
                        request.paymentDate(),
                        request.accountId(),
                        request.expenseStyleId(),
                        claim.getApplicantDepartmentId(),
                        claim.getTotalAmount(),com.uten.imp.common.finance.AccountingExpensePurpose.parse(request.postingPurpose())));

        claim.setStatus("PAID");
        claim.setPaidBy(user.getEmployeeId());
        claim.setPaidAt(Instant.now());
        claim.setPaymentDate(request.paymentDate());
        claim.setPaymentAccountId(request.accountId());
        claim.setPaymentExpenseStyleId(request.expenseStyleId());
        claim.setPaymentPostingPurpose(com.uten.imp.common.finance.AccountingExpensePurpose.parse(request.postingPurpose()).name());
        claim.setFinanceExpenseId(financeExpenseId);
        claimRepository.save(claim);
        appendEvent(claim.getId(), "PAID", user, "付款日期 " + request.paymentDate());
        // 打款完成 → 申请人回执 + 办结全部报销弹卡（2026-09-09 人事通知接入）
        hrNotice.notifyExpenseClaimPaid(
                claim.getId(), claim.getTotalAmount().toPlainString() + " 元", userIdOfEmployee(claim.getApplicantId()));
        return mapClaimWithItems(claim);
    }
    /** Trusted original-source bridge. External callers cannot mint its application context. */
    @Transactional
    public ExpenseClaimDto decideFromFinancialApplication(UUID id,boolean approved,String reason){
        if(applicationControl==null)throw new ApiException(ErrorCode.CONFLICT,"原申请流程尚未准备好");
        applicationControl.requireExpenseDecisionContext(id);return decide(requireStaff(),id,approved,reason,true);
    }
    @Transactional
    public void paymentReversedFromFinancialApplication(UUID id,UUID financeExpenseId,String reason){
        if(applicationControl==null)throw new ApiException(ErrorCode.CONFLICT,"原申请流程尚未准备好");applicationControl.requireExpenseReversalContext(id,financeExpenseId);tx.bind();
        var claim=requireClaimForUpdate(id);if(!"PAID".equals(claim.getStatus())||!Objects.equals(claim.getFinanceExpenseId(),financeExpenseId))throw new ApiException(ErrorCode.CONFLICT,"原报销付款身份或状态已变化");
        claim.setStatus("REJECTED");claim.setRejectReason("原付款已反审，请核对后重新提交申请："+Objects.toString(reason,""));claim.setRejectedBy(currentUser.requireEmployeeId());claim.setRejectedAt(Instant.now());
        claim.setPaidBy(null);claim.setPaidAt(null);claim.setPaymentDate(null);claim.setPaymentAccountId(null);claim.setPaymentExpenseStyleId(null);claim.setFinanceExpenseId(null);claim.setApprovedBy(null);claim.setApprovedAt(null);
        claimRepository.save(claim);appendEvent(id,"PAYMENT_REVERSED",requireStaff(),"原财务付款已反审；"+Objects.toString(reason,""));
    }

    // ---- 发票登记（V608） ---------------------------------------------------------

    /** 查重预检（登记表单即时提示；财会〔2020〕6 号防重复入账）。 */
    @Transactional(readOnly = true)
    public ExpenseClaimInvoiceCheckDto checkInvoiceDuplicate(
            String rawInvoiceNo, String rawInvoiceCode, UUID excludeClaimId) {
        return checkInvoiceDuplicate(rawInvoiceNo,rawInvoiceCode,excludeClaimId,null,null);
    }
    @Transactional(readOnly=true)
    public ExpenseClaimInvoiceCheckDto checkInvoiceDuplicate(String rawInvoiceNo,String rawInvoiceCode,UUID excludeClaimId,
            String invoiceType,String sellerName) {
        requireStaffAndApply();
        String invoiceNo = digitsOrNull(rawInvoiceNo);
        String invoiceCode = digitsOrNull(rawInvoiceCode);
        if (invoiceNo == null) {
            return ExpenseClaimInvoiceCheckDto.CLEAN;
        }
        AuthUser user=requireStaffAndApply();
        if(excludeClaimId!=null) assertOwner(requireClaim(excludeClaimId),user);
        // An Optional<Object[]> native result can become a present empty array in
        // Spring Data's collection conversion. A bounded row list has an explicit
        // zero-row meaning and cannot falsely reserve an archived invoice.
        boolean duplicated = !invoiceRepository.findDuplicateHolder(invoiceNo, invoiceCode, excludeClaimId,
                issuer(invoiceType,sellerName,invoiceNo,invoiceCode)).isEmpty();
        return duplicated ? new ExpenseClaimInvoiceCheckDto(true,null,null,null) : ExpenseClaimInvoiceCheckDto.CLEAN;
    }

    @Transactional
    public ExpenseClaimDto addInvoice(UUID claimId, ExpenseClaimInvoiceInput input) {
        tx.bind();
        AuthUser user = requireStaffAndApply();
        ExpenseClaim claim = requireClaimForUpdate(claimId);
        assertOwner(claim, user);
        if (!EDITABLE_STATUSES.contains(claim.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "报销单已进入审批流程，不能增改发票登记；如需调整请先撤回");
        }
        ExpenseClaimInvoice invoice = new ExpenseClaimInvoice();
        invoice.setClaimId(claimId);
        invoice.setLineNo(invoiceRepository.nextLineNo(claimId));
        ValidatedInvoice validated = validateInvoice(input, claimId);
        assertInvoiceNotDuplicated(validated, null);
        applyInvoice(invoice, validated);
        invoiceRepository.saveAndFlush(invoice);
        claim.setUpdatedAt(Instant.now());
        appendEvent(claimId,"EDITED",user,"更新票据登记");
        return mapClaimWithItems(claim);
    }

    @Transactional
    public ExpenseClaimDto updateInvoice(
            UUID claimId, UUID invoiceId, ExpenseClaimInvoiceInput input) {
        tx.bind();
        AuthUser user = requireStaffAndApply();
        ExpenseClaim claim = requireClaimForUpdate(claimId);
        assertOwner(claim, user);
        if (!EDITABLE_STATUSES.contains(claim.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "报销单已进入审批流程，不能增改发票登记；如需调整请先撤回");
        }
        ExpenseClaimInvoice invoice = invoiceRepository.findById(invoiceId)
                .filter(row -> claimId.equals(row.getClaimId()))
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "发票登记不存在"));
        ValidatedInvoice validated = validateInvoice(input, claimId);
        assertInvoiceNotDuplicated(validated, invoiceId);
        applyInvoice(invoice, validated);
        invoiceRepository.saveAndFlush(invoice);
        claim.setUpdatedAt(Instant.now());
        appendEvent(claimId,"EDITED",user,"更新票据登记");
        return mapClaimWithItems(claim);
    }

    @Transactional
    public ExpenseClaimDto deleteInvoice(UUID claimId, UUID invoiceId) {
        tx.bind();
        AuthUser user = requireStaffAndApply();
        ExpenseClaim claim = requireClaimForUpdate(claimId);
        assertOwner(claim, user);
        if (!EDITABLE_STATUSES.contains(claim.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "报销单已进入审批流程，不能删除发票登记；如需调整请先撤回");
        }
        ExpenseClaimInvoice invoice = invoiceRepository.findById(invoiceId)
                .filter(row -> claimId.equals(row.getClaimId()))
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "发票登记不存在"));
        invoiceRepository.delete(invoice);
        claim.setUpdatedAt(Instant.now());
        appendEvent(claimId,"EDITED",user,"删除票据登记");
        return mapClaimWithItems(claim);
    }

    private AuthUser requireStaffAndApply() {
        AuthUser user = requireStaff();
        require(user, "expense:apply");
        return user;
    }

    private void assertInvoiceNotDuplicated(ValidatedInvoice validated, UUID invoiceId) {
        // Transaction-scoped lock serializes equal invoice keys across different claims.
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(CAST(:key AS text),617))")
            .setParameter("key",issuer(validated.invoiceType(),validated.sellerName(),validated.invoiceNo(),validated.invoiceCode())+":"+Objects.toString(validated.invoiceCode(),"")+":"+validated.invoiceNo()).getSingleResult();
        if(invoiceRepository.duplicateInvoice(validated.invoiceNo(),validated.invoiceCode(),invoiceId,issuer(validated.invoiceType(),validated.sellerName(),validated.invoiceNo(),validated.invoiceCode())).isPresent())
            throw new ApiException(ErrorCode.CONFLICT,"该票据已登记，不能重复报销；请核对原登记单");
    }

    private static String issuer(String type,String name,String number,String code) {
        boolean vatIdentity=number!=null && ((number.matches("[0-9]{20}") && code==null)
            || (number.matches("[0-9]{8}") && code!=null && code.matches("[0-9]{10}|[0-9]{12}")));
        return "OTHER".equalsIgnoreCase(type) && !vatIdentity ? Objects.toString(trimToNull(name), "").toUpperCase(Locale.ROOT) : "";
    }

    private void applyInvoice(ExpenseClaimInvoice invoice, ValidatedInvoice validated) {
        invoice.setInvoiceType(validated.invoiceType());
        invoice.setInvoiceCode(validated.invoiceCode());
        invoice.setInvoiceNo(validated.invoiceNo());
        invoice.setIssueDate(validated.issueDate());
        invoice.setSellerName(validated.sellerName());
        invoice.setSellerTaxNo(validated.sellerTaxNo());
        invoice.setBuyerName(validated.buyerName());
        invoice.setAmountExclTax(validated.amountExclTax());
        invoice.setTaxAmount(validated.taxAmount());
        invoice.setTotalAmount(validated.totalAmount());
        invoice.setCheckState(validated.checkState());
        invoice.setAttachmentId(validated.attachmentId());
        invoice.setRemark(validated.remark());
        invoice.setBuyerTaxNo(validated.buyerTaxNo());
        invoice.setVerifiedAt(null); invoice.setVerifiedBy(null);
        invoice.setVerifiedByName(null); invoice.setVerificationRemark(null);
    }

    /**
     * 发票要素校验：号码形状（数电票 20 位无代码 / 老票 8 位 + 10/12 位代码，税务总局
     * 2024 年第 11 号公告）、金额两位小数、勾稽（不含税+税额=价税合计 ±0.01）。
     * 勾稽不符不拒绝落库，标 MISMATCH 供审批人复核（OCR 误读时人工修正）。
     */
    private ValidatedInvoice validateInvoice(ExpenseClaimInvoiceInput input, UUID claimId) {
        String invoiceType = input.invoiceType() == null || input.invoiceType().isBlank()
                ? "GENERAL" : input.invoiceType().trim().toUpperCase(Locale.ROOT);
        if (!INVOICE_TYPES.contains(invoiceType)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知发票类型");
        }
        String invoiceNo = trimToNull(input.invoiceNo());
        String invoiceCode = trimToNull(input.invoiceCode());
        if("OTHER".equals(invoiceType)) {
            if(invoiceNo==null || !invoiceNo.matches("[A-Za-z0-9/-]{1,60}")
                    || (invoiceCode!=null && !invoiceCode.matches("[A-Za-z0-9/-]{1,20}"))
                    || trimToNull(input.sellerName())==null)
                throw new ApiException(ErrorCode.VALIDATION_FAILED,"其他票据须填写有效凭证号码及开具单位");
        } else {
            if(invoiceNo==null || !invoiceNo.matches("[0-9]{8}|[0-9]{20}"))
                throw new ApiException(ErrorCode.VALIDATION_FAILED,"发票号码必须为8位或20位数字");
            if(invoiceNo.length()==20 ? invoiceCode!=null
                    : invoiceCode==null || !invoiceCode.matches("[0-9]{10}|[0-9]{12}"))
                throw new ApiException(ErrorCode.VALIDATION_FAILED,"20位数电票不填代码，8位发票须填写10或12位数字代码");
        }
        if(input.issueDate()!=null && input.issueDate().isAfter(BusinessTime.today()))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"开票日期不能晚于今天");
        BigDecimal total = money(input.totalAmount(), "价税合计");
        if (total.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "价税合计必须大于零");
        }
        BigDecimal excl = input.amountExclTax() == null
                ? null : money(input.amountExclTax(), "合计金额");
        BigDecimal tax = input.taxAmount() == null
                ? null : money(input.taxAmount(), "合计税额");
        String checkState = "UNCHECKED";
        if (excl != null && tax != null) {
            boolean reconciles = excl.add(tax).subtract(total).abs()
                    .compareTo(new BigDecimal("0.01")) <= 0;
            checkState = reconciles ? "AMOUNTS_MATCH" : "MISMATCH";
        }
        UUID attachmentId = input.attachmentId();
        if (attachmentId != null) {
            attachmentRepository.findById(attachmentId)
                    .filter(attachment -> "EXPENSE_CLAIM".equals(attachment.getOwnerType()))
                    .filter(attachment -> claimId.equals(attachment.getOwnerId()))
                    .filter(attachment -> attachment.getLifecycleState()==AttachmentLifecycleState.CLEAN)
                    .orElseThrow(() -> new ApiException(
                            ErrorCode.VALIDATION_FAILED, "关联附件不存在或不属于本报销单"));
        }
        String buyerTax=trimToNull(input.buyerTaxNo());
        if(buyerTax!=null && !buyerTax.toUpperCase(Locale.ROOT).matches("[0-9A-Z]{15}|[0-9A-Z]{18}|[0-9A-Z]{20}"))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"购买方纳税人识别号应为15、18或20位字母数字");
        return new ValidatedInvoice(
                invoiceType, invoiceCode, invoiceNo,
                input.issueDate(),
                trimToNull(input.sellerName()),
                trimToNull(input.sellerTaxNo()),
                trimToNull(input.buyerName()),
                excl, tax, total, checkState, attachmentId,
                trimToNull(input.remark()), buyerTax==null?null:buyerTax.toUpperCase(Locale.ROOT));
    }

    private static BigDecimal money(BigDecimal value, String label) {
        BigDecimal exact=com.uten.imp.common.util.FinancialExactAmount.require(value,label);
        if(exact.signum()<0)throw new ApiException(ErrorCode.VALIDATION_FAILED,label+"不能为负数");
        // Preserve the existing submitted two-place representation by padding only;
        // complete fractional facts beyond two places are never shortened.
        return new BigDecimal(com.uten.imp.common.finance.ExactDecimalText.plain(exact,2));
    }

    private static String digitsOrNull(String raw) {
        if (raw == null) {
            return null;
        }
        String digits = raw.trim();
        return digits.isEmpty() ? null : digits;
    }

    // ---- 事件与映射 ------------------------------------------------------------

    private void appendEvent(UUID claimId,String eventType,AuthUser actor,String remark) {
        appendEvent(claimId,eventType,actor,remark,null,null);
    }

    private void appendApprovalEvent(ExpenseClaim claim,String eventType,String stage,AuthUser actor,String remark) {
        appendEvent(claim.getId(),eventType,actor,remark,stage,claim.getApprovalRound());
    }

    private void appendEvent(UUID claimId,String eventType,AuthUser actor,String remark,String stage,Integer round) {
        String name=applicantQuery.employeeNames(List.of(actor.getEmployeeId())).getOrDefault(actor.getEmployeeId(),actor.getUsername());
        ExpenseClaimEvent event=new ExpenseClaimEvent();event.setClaimId(claimId);event.setEventType(eventType);
        event.setActorEmployeeId(actor.getEmployeeId());event.setActorNameSnapshot(name);event.setRemark(remark);
        event.setApprovalStage(stage);event.setApprovalRound(round);eventRepository.save(event);
    }

    private static void requireApprover(AuthUser user) {
        if(!ExpenseApprovalPolicy.hasAny(user))throw new ApiException(ErrorCode.FORBIDDEN);
    }

    private static String expenseKind(ExpenseClaimCreateRequest request){
        String inferred=request.applicationKind()==null?null:switch(request.applicationKind()){
            case "REIMBURSEMENT"->"GENERAL";case "TRAVEL_REIMBURSEMENT"->"TRAVEL";
            default->throw new ApiException(ErrorCode.VALIDATION_FAILED,"原报销类型不正确");};
        if(request.expenseKind()!=null&&inferred!=null&&!request.expenseKind().equals(inferred))throw new ApiException(ErrorCode.VALIDATION_FAILED,"报销类别与原表来源不一致");
        return expenseKind(request.expenseKind()==null?inferred:request.expenseKind());
    }
    private static String expenseKind(String kind) {
        if(kind==null || kind.isBlank())return "GENERAL";
        if(!Set.of("GENERAL","TRAVEL").contains(kind))throw new ApiException(ErrorCode.VALIDATION_FAILED,"未知报销类型");
        return kind;
    }

    /** 员工档案 id → 登录账号 id（经 HrNoticePort 解析；无账号返回 null，通知侧自行跳过）。 */
    private UUID userIdOfEmployee(UUID employeeId) {
        return hrNotice.recipientUserIdOf(employeeId);
    }

    private List<ExpenseClaimItem> appendItems(ExpenseClaim claim, List<ValidatedItem> validated) {
        int lineNo = 1;
        List<ExpenseClaimItem> items = new ArrayList<>(validated.size());
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
        return items;
    }

    private ValidatedItem validateItem(ExpenseClaimItemInput input) {
        if(input==null || input.date()==null || input.date().isAfter(BusinessTime.today()))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"费用日期不能为空或晚于中国业务日期的今天");
        String category = input.category().trim().toUpperCase(Locale.ROOT);
        if (!CATEGORIES.contains(category)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知报销类别");
        }
        BigDecimal amount=money(input.amount(),"报销金额");
        if(amount.signum()<=0)throw new ApiException(ErrorCode.VALIDATION_FAILED,"报销金额必须大于零");
        return new ValidatedItem(
                category, amount, input.date(), trimToNull(input.description()));
    }

    private void assertCanRead(ExpenseClaim claim) {
        AuthUser user = requireStaff();
        if (!readAccess.mayRead(user,claim,observerScope(user))) {
            throw new ApiException(ErrorCode.NOT_FOUND, "报销单不存在");
        }
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
        return mapClaimWithItems(
                claim,
                itemsFor(List.of(claim)).getOrDefault(claim.getId(), List.of()));
    }

    private ExpenseClaimDto mapClaimWithItems(ExpenseClaim claim, List<ExpenseClaimItem> items) {
        claimRepository.flush();
        var mapped=mapClaim(
                claim,
                items,
                new Mapping(
                        departmentNamesFor(List.of(claim)),
                        actorNamesFor(List.of(claim)),
                        Map.of(),
                        Map.of(),
                        List.of(),
                        List.of(),
                        List.of(),List.of()));
        return withApplicationLinks(List.of(mapped)).getFirst();
    }

    private List<ExpenseClaimDto> mapClaims(List<ExpenseClaim> claims) {
        Map<UUID, List<ExpenseClaimItem>> items = itemsFor(claims);
        Mapping context = new Mapping(
                departmentNamesFor(claims),
                actorNamesFor(claims),
                Map.of(),
                Map.of(),
                List.of(),
                List.of(),
                List.of(),List.of());
        List<ExpenseClaimDto> mapped = claims.stream()
                .map(claim -> mapClaim(
                        claim,
                        items.getOrDefault(claim.getId(), List.of()),
                        context))
                .toList();
        if (claims.stream().anyMatch(ExpenseClaim::isDeleted)) {
            var metadata = retainedRecords.metadata("expense_claims",claims.stream()
                    .map(claim -> new com.uten.imp.common.history.RetainedRecordReader.DocumentRef(claim.getId(),claim.isDeleted(),claim.getDeletedAt())).toList(),false);
            for (ExpenseClaimDto view : mapped) view.history().copyHistoryFrom(metadata.get(view.id()));
        }
        return withApplicationLinks(mapped);
    }
    @org.springframework.beans.factory.annotation.Autowired
    private ExpenseApplicationSourceService applicationSources;
    private void registerApplicationSource(UUID id,ExpenseClaimCreateRequest request){
        if(applicationControl!=null&&applicationControl.expenseManaged(id)){
            applicationControl.registerExpenseDraft(id,request.applicationKind(),request.travelApplicationId());return;
        }
        if(request.applicationKind()!=null||request.travelApplicationId()!=null||request.travelApplicationSourceKind()!=null){
            if(applicationSources==null)throw new ApiException(ErrorCode.CONFLICT,"原申请来源暂不可保存，请保留输入");
            applicationSources.save(id,request.applicationKind(),request.expenseKind(),request.travelApplicationId(),request.travelApplicationSourceKind());
        }
    }
    private List<ExpenseClaimDto> withApplicationLinks(List<ExpenseClaimDto> views){
        if(applicationControl==null||views.isEmpty())return views;
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("SELECT l.claim_id,a.id,a.application_no,a.kind,a.status,n.label_snapshot FROM finance_expense_application_links l JOIN finance_applications a ON a.id=l.application_id LEFT JOIN finance_application_nodes n ON n.application_id=a.id AND n.submission_round=a.submission_round AND n.step_no=a.current_step WHERE l.claim_id IN(:ids)").setParameter("ids",views.stream().map(ExpenseClaimDto::id).toList()).getResultList();
        var readable=applicationControl.readableApplications(rows.stream().map(row->(UUID)row[1]).toList(),requireStaff());
        Map<UUID,com.uten.imp.features.expenseclaim.dto.ExpenseClaimFinancialApplication> links=new HashMap<>();for(var row:rows)links.put((UUID)row[0],new com.uten.imp.features.expenseclaim.dto.ExpenseClaimFinancialApplication((UUID)row[1],Objects.toString(row[2],""),Objects.toString(row[3],""),Objects.toString(row[4],""),Objects.toString(row[5],""),readable.contains((UUID)row[1])));
        var linked=views.stream().map(view->view.withFinancialApplication(links.get(view.id()))).toList();
        return applicationSources==null?linked:applicationSources.attach(linked);
    }

    /** 一页报销单的申请人部门名一次查齐（列表「部门」列，避免逐单查部门）。 */
    private Map<UUID, String> departmentNamesFor(List<ExpenseClaim> claims) {
        List<UUID> ids = claims.stream()
                .map(ExpenseClaim::getApplicantDepartmentId)
                .filter(Objects::nonNull)
                .distinct()
                .toList();
        if (ids.isEmpty()) {
            return Map.of();
        }
        Map<UUID, String> names = applicantQuery.departmentNames(ids);
        return names == null ? Map.of() : names;
    }

    /** 一页报销单的审批/驳回/打款操作人姓名一次查齐（进度列与详情轨迹）。 */
    private Map<UUID, String> actorNamesFor(List<ExpenseClaim> claims) {
        List<UUID> ids = claims.stream()
                .flatMap(claim -> java.util.stream.Stream.of(
                        claim.getApprovedBy(), claim.getRejectedBy(), claim.getPaidBy()))
                .filter(Objects::nonNull)
                .distinct()
                .toList();
        if (ids.isEmpty()) {
            return Map.of();
        }
        return applicantQuery.employeeNames(ids);
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

    /** DTO 映射上下文：列表/动作响应只给 names；详情再带附件、发票、事件与付款名称。 */
    private record Mapping(
            Map<UUID, String> departmentNames,
            Map<UUID, String> actorNames,
            Map<UUID, String> accountNames,
            Map<UUID, String> styleNames,
            List<AttachmentDto> attachments,
            List<ExpenseClaimInvoice> invoices,
            List<ExpenseClaimEvent> events, List<AttachmentDto> paymentProofs) {
    }

    private ExpenseClaimDto mapClaim(
            ExpenseClaim claim,
            List<ExpenseClaimItem> items,
            Mapping context) {
        return mapClaim(claim, items, context, List.of(), List.of());
    }

    private ExpenseClaimDto mapClaim(
            ExpenseClaim claim,
            List<ExpenseClaimItem> items,
            Mapping context,
            List<ExpenseClaimInvoiceDto> invoices,
            List<ExpenseClaimEventDto> events) {
        UUID departmentId = claim.getApplicantDepartmentId();
        return new ExpenseClaimDto(
                claim.getId(),
                claim.getClaimNo(),
                claim.getApplicantId(),
                claim.getApplicantNameSnapshot(),
                departmentId,
                departmentId == null ? null : context.departmentNames().get(departmentId),
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
                claim.getRejectedAt(),
                claim.getPaidAt(),
                claim.getRemark(),
                claim.getRejectReason(),
                nameOf(context.actorNames(), claim.getApprovedBy()),
                nameOf(context.actorNames(), claim.getRejectedBy()),
                nameOf(context.actorNames(), claim.getPaidBy()),
                claim.getPaymentDate(),
                claim.getPaymentAccountId(),
                nameOf(context.accountNames(), claim.getPaymentAccountId()),
                claim.getPaymentExpenseStyleId(),
                nameOf(context.styleNames(), claim.getPaymentExpenseStyleId()),
                claim.getFinanceExpenseId(),
                context.attachments(),
                invoices,
                events, claim.getVersion(), claim.getApprovedBy(), context.paymentProofs(),
                visibleSubmissionSnapshot(claim.getPreviousSubmissionSnapshot()), visibleSubmissionSnapshot(claim.getSubmissionSnapshot()), claim.isResubmission(),
                new com.uten.imp.common.history.DocumentHistoryMetadata(),claim.getApprovalStage(),ExpenseApprovalPolicy.label(claim.getApprovalStage()),
                approvalPolicy.canApprove(requireStaff(),claim),claim.getApprovalRound(),claim.getExpenseKind(),approvalRoutingStale(claim),approvalPolicy.canPay(requireStaff(),claim),claim.getAbandonedAt()!=null&&claim.isDeleted());
    }

    private boolean approvalRoutingStale(ExpenseClaim claim) {
        return Set.of("SUBMITTED","REVIEWING").contains(claim.getStatus())&&"DEPARTMENT".equals(claim.getApprovalStage())
                &&departmentRouting.isStale(claim.getApplicantId(),claim.getApplicantDepartmentId(),claim.getDepartmentApprovalSnapshot());
    }

    private String submissionSnapshot(ExpenseClaim claim) {
        var items=itemRepository.findByClaimIdInOrderByClaimIdAscLineNoAsc(List.of(claim.getId()));
        var invoices=invoiceRepository.findByClaimIdOrderByLineNoAsc(claim.getId());
        if(platformColumns==null)return ExpenseClaimSubmissionSnapshot.capture(claim,items,invoices);
        Map<UUID,Map<String,BigDecimal>> facts=new LinkedHashMap<>();
        for(var item:items)facts.put(item.getId(),item.getAmount()==null?Map.of():Map.of("amount",item.getAmount()));
        return ExpenseClaimSubmissionSnapshot.capture(claim,items,invoices,
                platformColumns.getObject().freezeForReview("expense_claim_item",claim.getId(),facts),
                platformColumns.getObject().freezeForReview("expense_claim",claim.getId(),Map.of(claim.getId(),
                    claim.getTotalAmount()==null?Map.of():Map.of("totalAmount",claim.getTotalAmount()))).get(claim.getId()));
    }
    /** Same native commercial facts before and after submit; verification/lifecycle fields never alter the fingerprint. */
    @Transactional(readOnly=true)
    public Map<String,Object> originalApplicationSource(UUID id){
        var claim=requireClaim(id);assertCanRead(claim);
        return nativeOrigins==null?Map.of():nativeOrigins.originalView("EXPENSE_CLAIM",id);
    }
    @Transactional(readOnly=true)
    public String applicationBusinessSnapshot(UUID id){var claim=requireClaim(id);assertCanRead(claim);return submissionSnapshot(claim);}

    private String visibleSubmissionSnapshot(String snapshot) {
        return platformColumns==null?snapshot:platformColumns.getObject().maskReviewSnapshot("expense_claim_item",snapshot);
    }

    private void preserveSubmittedSnapshot(ExpenseClaim claim) {
        if (claim.getSubmissionSnapshot() == null) claim.setSubmissionSnapshot(submissionSnapshot(claim));
    }

    private static String nameOf(Map<UUID, String> names, UUID id) {
        return id == null ? null : names.get(id);
    }

    private ExpenseClaim requireClaim(UUID id) { return requireClaim(id, false); }

    private ExpenseClaim requireClaim(UUID id, boolean includeDeleted) {
        return claimRepository.findById(id).filter(claim -> includeDeleted || !claim.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "报销单不存在"));
    }

    private ExpenseClaim requireClaimForUpdate(UUID id) {
        return claimRepository.findByIdForUpdate(id).filter(claim -> !claim.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "报销单不存在"));
    }

    private static Set<String> normalizeStatuses(String raw) {
        if(raw!=null&&"ACTION_REQUIRED".equals(raw.trim().toUpperCase(Locale.ROOT)))return Set.of("ACTION_REQUIRED");
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
        return user.getPermissions().contains(permission);
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

    private record ValidatedInvoice(
            String invoiceType,
            String invoiceCode,
            String invoiceNo,
            LocalDate issueDate,
            String sellerName,
            String sellerTaxNo,
            String buyerName,
            BigDecimal amountExclTax,
            BigDecimal taxAmount,
            BigDecimal totalAmount,
            String checkState,
            UUID attachmentId,
            String remark, String buyerTaxNo
    ) {
    }

    private record DateRange(Instant fromInclusive, Instant toExclusive) {
    }
}
