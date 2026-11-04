package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.util.*;

/** The same live approval scope drives writes, queues, facets, badges and notice routing. */
@Component
@RequiredArgsConstructor
public class ExpenseApprovalPolicy implements com.uten.imp.application.port.ExpenseApprovalAudiencePort {
    public static final String DEPARTMENT = "DEPARTMENT";
    public static final String FINANCE_INITIAL = "FINANCE_INITIAL";
    public static final String FINANCE_REVIEW = "FINANCE_REVIEW";
    public static final String EXECUTIVE = "EXECUTIVE";
    public static final Set<String> PERMISSIONS = com.uten.imp.application.port.ExpenseApprovalAudiencePort.APPROVAL_PERMISSIONS;
    private final com.uten.imp.application.policy.DepartmentApprovalScope departments;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.application.port.ApprovalCandidateDirectoryPort candidates;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.application.policy.DepartmentApprovalRouting routing;
    @org.springframework.beans.factory.annotation.Autowired
    private ExpenseClaimRepository claims;

    public static String permission(String stage) {
        return switch (stage == null ? "" : stage) {
            case DEPARTMENT -> "expense:approve:department";
            case FINANCE_INITIAL -> "expense:approve:finance_initial";
            case FINANCE_REVIEW -> "expense:approve:finance_review";
            case EXECUTIVE -> "expense:approve:executive";
            default -> "";
        };
    }

    public static String label(String stage) {
        return switch (stage == null ? "" : stage) {
            case DEPARTMENT -> "部门负责人审核";
            case FINANCE_INITIAL -> "财务初核";
            case FINANCE_REVIEW -> "财务复核";
            case EXECUTIVE -> "总经办批准";
            default -> "审批已结束";
        };
    }

    public static String next(String stage) {
        return switch (stage == null ? "" : stage) {
            case DEPARTMENT -> FINANCE_INITIAL;
            case FINANCE_INITIAL -> FINANCE_REVIEW;
            case FINANCE_REVIEW -> EXECUTIVE;
            case EXECUTIVE -> null;
            default -> throw new ApiException(ErrorCode.CONFLICT, "报销审批节点不完整，请刷新后重试");
        };
    }

    public static boolean hasAny(AuthUser user) {
        return user != null && user.getPermissions().stream().anyMatch(PERMISSIONS::contains);
    }

    public static Set<String> stages(String value) {
        if (value == null || value.isBlank()) return Set.of(DEPARTMENT, FINANCE_INITIAL, FINANCE_REVIEW, EXECUTIVE);
        if ("FINANCE".equals(value)) return Set.of(FINANCE_INITIAL, FINANCE_REVIEW);
        if (Set.of(DEPARTMENT, FINANCE_INITIAL, FINANCE_REVIEW, EXECUTIVE).contains(value)) return Set.of(value);
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知报销审批分类");
    }

    /** Active descendants of the operator's membership/manager roots. Permission alone never grants company scope. */
    public Context context(AuthUser user) {
        if (user == null || user.isVisitor() || user.getEmployeeId() == null) return new Context(null, Set.of(), Map.of(), Set.of());
        Object key = List.of(this, user.getId(), Set.copyOf(user.getPermissions()), user.isSuperAdmin());
        if (TransactionSynchronizationManager.hasResource(key)) return (Context) TransactionSynchronizationManager.getResource(key);
        Set<String> stages = new LinkedHashSet<>();
        for (String stage : stages(null)) if (user.getPermissions().contains(permission(stage))) stages.add(stage);
        if(!stages.isEmpty() && !departments.isCurrent(user))return new Context(user.getEmployeeId(),Set.of(),Map.of(),Set.of());
        Set<UUID> departmentsInScope = new LinkedHashSet<>();
        Map<UUID, String> codes = new LinkedHashMap<>();
        if (stages.contains(DEPARTMENT)) {
            var scoped=routing.departmentCodes(user);departmentsInScope.addAll(scoped.keySet());codes.putAll(scoped);
        }
        Context result = new Context(user.getEmployeeId(), Set.copyOf(departmentsInScope), Map.copyOf(codes), Set.copyOf(stages));
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.bindResource(key, result);
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override public void afterCompletion(int status) { TransactionSynchronizationManager.unbindResourceIfPossible(key); }
            });
        }
        return result;
    }

    public boolean canApprove(AuthUser user, ExpenseClaim claim) {
        return context(user).canApprove(claim) && (!DEPARTMENT.equals(claim.getApprovalStage())
                || routing.canReview(user,claim.getApplicantId(),claim.getApplicantDepartmentId(),claim.getDepartmentApprovalSnapshot()));
    }

    @Override public boolean eligible(UUID userId,UUID employeeId,Set<String> permissions,UUID claimId) {
        if(employeeId==null)return false;
        AuthUser user=new AuthUser(userId,employeeId,"approval-recipient",permissions,false,true,false);
        return claims.findById(claimId).filter(claim->!claim.isDeleted()).map(claim->canApprove(user,claim)).orElse(false);
    }

    public static boolean canPayFacts(AuthUser user,ExpenseClaim claim) {
        if(user==null||user.isVisitor()||user.getEmployeeId()==null||!user.getPermissions().contains("expense:pay")||claim.isDeleted()||!"APPROVED".equals(claim.getStatus()))return false;
        UUID actor=user.getEmployeeId();
        return !actor.equals(claim.getApplicantId())&&!actor.equals(claim.getApprovedBy())
                &&!(claim.getApprovalParticipants()==null?"":claim.getApprovalParticipants()).contains(actor.toString());
    }

    public boolean canPay(AuthUser user,ExpenseClaim claim) {return canPayFacts(user,claim)&&departments.isCurrent(user);}

    public void requirePaymentOperator(ExpenseClaim claim,String participants,boolean proofAlreadyPresent) {
        Set<String> prerequisites=new LinkedHashSet<>(Set.of("attachment:view","attachment:download"));
        if(!proofAlreadyPresent)prerequisites.add("attachment:upload");
        var projected=new ExpenseClaim();projected.setStatus("APPROVED");projected.setApplicantId(claim.getApplicantId());projected.setApprovedBy(claim.getApprovedBy());projected.setApprovalParticipants(participants);
        for(var candidate:candidates.candidates("expense:pay",prerequisites)) {
            var user=new AuthUser(candidate.userId(),candidate.employeeId(),"payment-candidate",Set.of("expense:pay"),false,true,false);
            if(canPay(user,projected))return;
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED,"暂无与本轮所有审批人分离的出纳，请配置报销付款及凭据上传、查看、下载权限");
    }

    @Override public boolean eligiblePayment(UUID userId,UUID employeeId,Set<String> permissions,UUID claimId) {
        if(employeeId==null)return false;
        var user=new AuthUser(userId,employeeId,"payment-recipient",permissions,false,true,false);
        return claims.findById(claimId).map(claim->canPay(user,claim)).orElse(false);
    }

    public static String paymentSql(String alias,AuthUser user) {
        if(user==null||user.getEmployeeId()==null||!user.getPermissions().contains("expense:pay"))return "FALSE";
        UUID actor=user.getEmployeeId();
        return alias+".status='APPROVED' AND "+alias+".applicant_id<>'"+actor+"'::uuid AND "+alias+".approved_by IS DISTINCT FROM '"+actor+"'::uuid"
            +" AND POSITION('"+actor+"' IN COALESCE("+alias+".approval_participants,''))=0"
            +" AND EXISTS(SELECT 1 FROM employees payment_actor WHERE payment_actor.id='"+actor+"'::uuid AND NOT payment_actor.is_deleted AND payment_actor.status IN('active','probation','onLeave'))";
    }

    public Predicate paymentPredicate(Root<ExpenseClaim> root,CriteriaBuilder cb,AuthUser user) {
        if(user==null||user.getEmployeeId()==null||!user.getPermissions().contains("expense:pay")||!departments.isCurrent(user))return cb.disjunction();
        UUID actor=user.getEmployeeId();
        return cb.and(cb.equal(root.get("status"),"APPROVED"),cb.notEqual(root.get("applicantId"),actor),
            cb.or(cb.isNull(root.get("approvedBy")),cb.notEqual(root.get("approvedBy"),actor)),
            cb.notLike(cb.coalesce(root.get("approvalParticipants"),""),"%"+actor+"%"));
    }

    @Override public String route(UUID userId,UUID employeeId,Set<String> permissions,UUID departmentId,String stage) {
        String code=EXECUTIVE.equals(stage)?"GM":"FINANCE";
        if(DEPARTMENT.equals(stage))code=context(new AuthUser(userId,employeeId,"approval-recipient",permissions,false,true,false)).departmentCodes().get(departmentId);
        if(code==null)return "/expense/approval";
        if(DEPARTMENT.equals(stage)&&"GM".equals(code))code="GM_DEPARTMENT";
        return "/approvals/"+org.springframework.web.util.UriUtils.encodePathSegment(code,java.nio.charset.StandardCharsets.UTF_8)+"?group=expense";
    }

    public void requireApprove(AuthUser user, ExpenseClaim claim) {
        if (!canApprove(user, claim)) throw new ApiException(ErrorCode.FORBIDDEN,
                "当前报销单不在你的审批节点或部门范围内，同一人不能审批本单多个节点");
    }

    /** Resolve a real next operator before changing any state, including same-round separation. */
    public void requireNext(ExpenseClaim claim,String stage,String participants) {
        if(stage==null)return;
        String permission=permission(stage);
        for(var candidate:candidates.candidates(permission,Set.of("attachment:view","attachment:download"))) {
            var user=new AuthUser(candidate.userId(),candidate.employeeId(),"approval-candidate",Set.of(permission),false,true,false);
            var projected=new ExpenseClaim();projected.setStatus("SUBMITTED");projected.setApplicantId(claim.getApplicantId());projected.setApplicantDepartmentId(claim.getApplicantDepartmentId());
            projected.setApprovalStage(stage);projected.setApprovalParticipants(participants);projected.setDepartmentApprovalSnapshot(claim.getDepartmentApprovalSnapshot());
            if(canApprove(user,projected))return;
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED,"暂无可办理的"+label(stage)+"人员，请联系管理员配置对应岗位审批权限及原件查看、下载权限；不能由申请人或本轮已审批人员兼任");
    }

    public record Context(UUID actor, Set<UUID> departmentIds, Map<UUID, String> departmentCodes, Set<String> allowedStages) {
        public boolean canApprove(ExpenseClaim claim) {
            return actor != null && !actor.equals(claim.getApplicantId())
                    && Set.of("SUBMITTED", "REVIEWING").contains(claim.getStatus())
                    && claim.getApprovalStage()!=null && allowedStages.contains(claim.getApprovalStage())
                    && (!DEPARTMENT.equals(claim.getApprovalStage()) || departmentIds.contains(claim.getApplicantDepartmentId()))
                    && !(claim.getApprovalParticipants() == null ? "" : claim.getApprovalParticipants()).contains(actor.toString());
        }

        public String sql(String alias) {
            if (actor == null || allowedStages.isEmpty()) return "FALSE";
            List<String> scopes = new ArrayList<>();
            for (String stage : allowedStages) {
                String term = alias + ".approval_stage='" + stage + "'";
                if (DEPARTMENT.equals(stage)) term += " AND " + alias + ".applicant_department_id IN (" + uuidSql(departmentIds) + ") AND fn_department_approval_can_review('"+actor+"'::uuid,"+alias+".applicant_id,"+alias+".applicant_department_id,"+alias+".department_approval_snapshot)";
                scopes.add("(" + term + ")");
            }
            return alias + ".status IN ('SUBMITTED','REVIEWING') AND " + alias + ".applicant_id<>'" + actor + "'::uuid"
                    + " AND POSITION('" + actor + "' IN COALESCE(" + alias + ".approval_participants,''))=0 AND (" + String.join(" OR ", scopes) + ")";
        }

        public Predicate predicate(Root<ExpenseClaim> root, CriteriaBuilder cb) {
            if (actor == null) return cb.disjunction();
            List<Predicate> scopes = new ArrayList<>();
            for (String stage : allowedStages) {
                Predicate term = cb.equal(root.get("approvalStage"), stage);
                if (DEPARTMENT.equals(stage)) term = cb.and(term, departmentIds.isEmpty() ? cb.disjunction() : root.get("applicantDepartmentId").in(departmentIds),
                        cb.isTrue(cb.function("fn_department_approval_can_review",Boolean.class,cb.literal(actor),root.get("applicantId"),root.get("applicantDepartmentId"),root.get("departmentApprovalSnapshot"))));
                scopes.add(term);
            }
            return cb.and(root.get("status").in(Set.of("SUBMITTED", "REVIEWING")), cb.notEqual(root.get("applicantId"), actor),
                    cb.notLike(cb.coalesce(root.get("approvalParticipants"), ""), "%" + actor + "%"), cb.or(scopes.toArray(Predicate[]::new)));
        }
    }

    static String uuidSql(Collection<UUID> ids) {
        return ids.isEmpty() ? "NULL::uuid" : ids.stream().map(id -> "'" + id + "'::uuid").collect(java.util.stream.Collectors.joining(","));
    }
}
