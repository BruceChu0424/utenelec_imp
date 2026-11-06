package com.uten.imp.features.expenseclaim;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Repository;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 报销申请人 / 部门快照查询。报销域只保存姓名和部门快照，不依赖组织域实体或仓储，
 * 部门名称与筛选桶均走原生 SQL 只读查询（全部参数化）。
 */
@Repository
@RequiredArgsConstructor
public class ExpenseApplicantQuery {

    private final EntityManager entityManager;
    @org.springframework.beans.factory.annotation.Autowired
    private ExpenseApprovalPolicy approvalPolicy;

    private String observerVisibility(com.uten.imp.security.AuthUser actor,
            com.uten.imp.security.OwnerVisibility.OwnerScope scope, String queue) {
        String visible=scope.seeAll()?"TRUE":scope.visibleOwners().isEmpty()?"FALSE":"c.applicant_id IN (:observerOwners)";
        boolean approve=ExpenseApprovalPolicy.hasAny(actor), pay=actor.getPermissions().contains("expense:pay") || actor.isSuperAdmin();
        String legacy=switch(queue) {
            case "pending" -> approve?approvalPolicy.context(actor).sql("c"):"FALSE";
            case "payable" -> pay?ExpenseApprovalPolicy.paymentSql("c",actor):"FALSE";
            case "history" -> "("+(approve?"EXISTS(SELECT 1 FROM expense_claim_events e WHERE e.claim_id=c.id AND e.actor_employee_id=:actor AND e.event_type IN ('STAGE_APPROVED','APPROVED','REJECTED'))":"FALSE")+") OR "+(pay?"c.status='PAID'":"FALSE");
            default -> "FALSE";
        };
        return "("+visible+" OR (NOT fn_finance_expense_is_application_managed(c.id) AND ("+legacy+")))";
    }

    private jakarta.persistence.Query observerQuery(String sql, com.uten.imp.security.AuthUser actor,
            com.uten.imp.security.OwnerVisibility.OwnerScope scope) {
        var query=entityManager.createNativeQuery(sql);
        if(sql.contains(":observerOwners")) query.setParameter("observerOwners",scope.visibleOwners());
        if(sql.contains(":actor")) query.setParameter("actor",actor.getEmployeeId());
        return query;
    }

    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto observerFacets(
            com.uten.imp.security.AuthUser actor, com.uten.imp.security.OwnerVisibility.OwnerScope scope, String queue) {
        return workflowFacets(actor,scope,queue,null,null);
    }

    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto workflowFacets(
            com.uten.imp.security.AuthUser actor, com.uten.imp.security.OwnerVisibility.OwnerScope scope,
            String queue,String stage,String departmentCode) {
        return workflowFacets(actor,scope,queue,stage,departmentCode,true);
    }

    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto workflowFacets(
            com.uten.imp.security.AuthUser actor, com.uten.imp.security.OwnerVisibility.OwnerScope scope,
            String queue,String stage,String departmentCode,boolean includeClaimNos) {
        String statuses=switch(queue) {
            case "pending" -> "c.status IN ('SUBMITTED','REVIEWING')";
            case "payable" -> "c.status='APPROVED'";
            case "history" -> "c.status<>'DRAFT'";
            case "browse" -> "TRUE";
            default -> throw new IllegalArgumentException("Unknown expense read queue");
        };
        String where=" FROM expense_claims c WHERE NOT c.is_deleted AND "+statuses+" AND "+observerVisibility(actor,scope,queue)+scopeSql(actor,queue,stage,departmentCode);
        var departments=observerBuckets("SELECT c.applicant_department_id::text,COALESCE((SELECT d.name FROM departments d WHERE d.id=c.applicant_department_id),''),count(*)"+where+" GROUP BY 1,2 ORDER BY 2,1",actor,scope);
        var months=observerBuckets("SELECT to_char(c.created_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM'),to_char(c.created_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM'),count(*)"+where+" GROUP BY 1,2 ORDER BY 1 DESC",actor,scope);
        var claims=includeClaimNos?observerBuckets("SELECT c.claim_no,c.claim_no,count(*)"+where+" GROUP BY 1,2 ORDER BY 1",actor,scope):List.<com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto.Bucket>of();
        // Category counts are distinct documents, matching the list's EXISTS predicate.
        var categories=observerBuckets("SELECT category,category,count(*) FROM (SELECT DISTINCT c.id,i.category "+
                where.replace(" FROM expense_claims c", " FROM expense_claims c JOIN expense_claim_items i ON i.claim_id=c.id")+
                ") visible GROUP BY category ORDER BY category",actor,scope);
        return new com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto(departments,months,categories,claims);
    }

    String scopeSql(com.uten.imp.security.AuthUser actor,String queue,String stage,String departmentCode) {
        String filter="";
        if(stage!=null && !stage.isBlank()) {
            String stages=ExpenseApprovalPolicy.stages(stage).stream().map(value->"'"+value+"'").collect(java.util.stream.Collectors.joining(","));
            filter+=" AND "+("history".equals(queue)
                    ? "EXISTS(SELECT 1 FROM expense_claim_events scoped_event WHERE scoped_event.claim_id=c.id AND scoped_event.actor_employee_id='"+actor.getEmployeeId()+"'::uuid AND scoped_event.approval_stage IN ("+stages+"))"
                    : "c.approval_stage IN ("+stages+")");
        }
        if(departmentCode!=null && !departmentCode.isBlank()) {
            var ids=approvalPolicy.context(actor).departmentCodes().entrySet().stream().filter(entry->departmentCode.equals(entry.getValue())).map(Map.Entry::getKey).toList();
            filter+=" AND c.applicant_department_id IN ("+ExpenseApprovalPolicy.uuidSql(ids)+")";
        }
        return filter;
    }

    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimCountsDto workflowCounts(
            com.uten.imp.security.AuthUser user,ExpenseApprovalPolicy.Context context,boolean apply,boolean pay) {
        UUID actor=user.getEmployeeId();
        String approval=context.sql("c");
        String stale="c.status IN('SUBMITTED','REVIEWING') AND c.approval_stage='DEPARTMENT' AND fn_department_approval_snapshot_stale(c.applicant_id,c.applicant_department_id,c.department_approval_snapshot)";
        String payable=ExpenseApprovalPolicy.paymentSql("c",user);
        var rows=com.uten.imp.common.util.NativeQueryResults.objectArrayRows(entityManager.createNativeQuery(
                "SELECT c.status,c.approval_stage,c.applicant_department_id,COUNT(*) FILTER(WHERE c.applicant_id=:actor),"
                +"COUNT(*) FILTER(WHERE "+approval+"),COUNT(*) FILTER(WHERE "+payable+"),COUNT(*) FILTER(WHERE c.applicant_id=:actor AND "+stale+") FROM expense_claims c WHERE NOT c.is_deleted AND ("
                +(apply?"c.applicant_id=:actor":"FALSE")+" OR ("+approval+") OR ("+(pay?payable:"FALSE")+")) GROUP BY c.status,c.approval_stage,c.applicant_department_id").setParameter("actor",actor));
        long draft=0,rejected=0,processing=0,payment=0,routingStale=0;
        Map<String,Long> stageCounts=new LinkedHashMap<>(), byCode=new LinkedHashMap<>(), scopes=new LinkedHashMap<>();
        context.departmentCodes().values().forEach(code->{scopes.put(code,1L);byCode.put(code,0L);});
        for(Object[] row:rows) {
            String status=(String)row[0], stage=(String)row[1]; long own=apply?count(row[3]):0, pending=count(row[4]);
            if("DRAFT".equals(status))draft+=own;
            if("REJECTED".equals(status))rejected+=own;
            long staleOwn=apply?count(row[6]):0;routingStale+=staleOwn;
            if(Set.of("SUBMITTED","REVIEWING","APPROVED").contains(status))processing+=own-staleOwn;
            if(pay)payment+=count(row[5]);
            if(stage!=null)stageCounts.merge(stage,pending,Long::sum);
            if(ExpenseApprovalPolicy.DEPARTMENT.equals(stage) && pending>0) {
                String code=context.departmentCodes().get((UUID)row[2]);if(code!=null)byCode.merge(code,pending,Long::sum);
            }
        }
        long department=stageCounts.getOrDefault(ExpenseApprovalPolicy.DEPARTMENT,0L),initial=stageCounts.getOrDefault(ExpenseApprovalPolicy.FINANCE_INITIAL,0L),
                review=stageCounts.getOrDefault(ExpenseApprovalPolicy.FINANCE_REVIEW,0L),executive=stageCounts.getOrDefault(ExpenseApprovalPolicy.EXECUTIVE,0L);
        return new com.uten.imp.features.expenseclaim.dto.ExpenseClaimCountsDto(draft,rejected,department+initial+review+executive,payment,processing,
                department,initial,review,executive,Map.copyOf(byCode),Map.copyOf(scopes),routingStale);
    }

    private List<com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto.Bucket> observerBuckets(
            String sql, com.uten.imp.security.AuthUser actor, com.uten.imp.security.OwnerVisibility.OwnerScope scope) {
        return com.uten.imp.common.util.NativeQueryResults.objectArrayRows(observerQuery(sql,actor,scope)).stream()
                .filter(row->row[0]!=null).map(row->new com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto.Bucket(
                        row[0].toString(),row[1].toString(),((Number)row[2]).longValue())).toList();
    }

    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimSummaryDto observerSummary(
            com.uten.imp.security.AuthUser actor, com.uten.imp.security.OwnerVisibility.OwnerScope scope) {
        String pending="c.status IN ('SUBMITTED','REVIEWING') AND "+observerVisibility(actor,scope,"pending");
        String payable="c.status='APPROVED' AND "+observerVisibility(actor,scope,"payable");
        String read="("+observerVisibility(actor,scope,"browse")+" OR (c.status IN ('SUBMITTED','REVIEWING') AND "+observerVisibility(actor,scope,"pending")+") OR (c.status IN ('APPROVED','REJECTED','PAID') AND "+observerVisibility(actor,scope,"history")+"))";
        String submitted="c.submitted_at>=:monthStart AND c.submitted_at<:monthEnd AND "+read;
        String paid="c.status='PAID' AND c.paid_at>=:monthStart AND c.paid_at<:monthEnd AND "+read;
        var fields=new java.util.ArrayList<String>();
        for(String predicate:List.of(pending,payable,submitted,paid)) {
            fields.add("count(*) FILTER(WHERE "+predicate+")");
            fields.add("COALESCE(sum(c.total_amount) FILTER(WHERE "+predicate+"),0)");
        }
        var month=java.time.YearMonth.now(com.uten.imp.common.time.BusinessTime.ZONE);
        var query=observerQuery("SELECT "+String.join(",",fields)+" FROM expense_claims c WHERE NOT c.is_deleted",actor,scope);
        query.setParameter("monthStart",month.atDay(1).atStartOfDay(com.uten.imp.common.time.BusinessTime.ZONE).toInstant());
        query.setParameter("monthEnd",month.plusMonths(1).atDay(1).atStartOfDay(com.uten.imp.common.time.BusinessTime.ZONE).toInstant());
        Object[] row=(Object[])query.getSingleResult();
        return new com.uten.imp.features.expenseclaim.dto.ExpenseClaimSummaryDto(
                ((Number)row[0]).longValue(),new java.math.BigDecimal(row[1].toString()),
                ((Number)row[2]).longValue(),new java.math.BigDecimal(row[3].toString()),
                ((Number)row[4]).longValue(),new java.math.BigDecimal(row[5].toString()),
                ((Number)row[6]).longValue(),new java.math.BigDecimal(row[7].toString()));
    }

    public Optional<ApplicantSnapshot> findEligible(UUID employeeId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT e.full_name, e.department_id
                        FROM employees e
                        JOIN departments d
                          ON d.id = e.department_id AND d.is_deleted = false
                        WHERE e.id = :id
                          AND e.is_deleted = false
                          AND e.status IN ('active', 'probation', 'onLeave')
                        """)
                .setParameter("id", employeeId)
                .setMaxResults(1)
                .getResultList();
        return rows.stream()
                .findFirst()
                .map(row -> new ApplicantSnapshot((String) row[0], (UUID) row[1]));
    }

    /**
     * 部门 id → 名称（一次查齐，供列表/详情回填「部门」列，避免逐单查询）。
     * 已删除部门仍返回名称（历史报销单的部门快照要能显示）。
     */
    public Map<UUID, String> departmentNames(Collection<UUID> departmentIds) {
        Set<UUID> ids = new LinkedHashSet<>();
        if (departmentIds != null) {
            departmentIds.stream().filter(java.util.Objects::nonNull).forEach(ids::add);
        }
        if (ids.isEmpty()) {
            return Map.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT d.id, d.name
                        FROM departments d
                        WHERE d.id IN (:ids)
                        """)
                .setParameter("ids", ids)
                .getResultList();
        Map<UUID, String> names = new LinkedHashMap<>();
        for (Object[] row : rows) {
            names.put((UUID) row[0], (String) row[1]);
        }
        return names;
    }

    /**
     * 员工 id → 姓名快照（V608：审批/打款操作人回显与事件落库；已删除员工仍返回姓名，
     * 历史单据的操作人要能显示）。一次查齐，避免逐单查询。
     */
    public Map<UUID, String> employeeNames(Collection<UUID> employeeIds) {
        Set<UUID> ids = new LinkedHashSet<>();
        if (employeeIds != null) {
            employeeIds.stream().filter(java.util.Objects::nonNull).forEach(ids::add);
        }
        if (ids.isEmpty()) {
            return Map.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT e.id, e.full_name
                        FROM employees e
                        WHERE e.id IN (:ids)
                        """)
                .setParameter("ids", ids)
                .getResultList();
        Map<UUID, String> names = new LinkedHashMap<>();
        for (Object[] row : rows) {
            names.put((UUID) row[0], (String) row[1]);
        }
        return names;
    }

    /**
     * 某状态集合下报销单按申请人部门聚合（表头「部门」筛选桶）。
     * 返回 [department_id, department_name, count]，按部门名排序；无部门快照的单据不进桶。
     */
    public List<FacetRow> departmentFacets(Collection<String> statuses, UUID actor, boolean payment) {
        if (statuses == null || statuses.isEmpty()) {
            return List.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT c.applicant_department_id, d.name, COUNT(*)
                        FROM expense_claims c
                        JOIN departments d ON d.id = c.applicant_department_id
                        WHERE c.is_deleted = false AND c.status IN (:statuses)
                          AND NOT fn_finance_expense_is_application_managed(c.id) AND c.applicant_id<>:actor
                          AND (:payment=false OR c.approved_by IS NULL OR c.approved_by<>:actor)
                          AND (:payment=false OR POSITION(CAST(:actor AS text) IN COALESCE(c.approval_participants,''))=0)
                        GROUP BY c.applicant_department_id, d.name
                        ORDER BY d.name, c.applicant_department_id
                        """)
                .setParameter("statuses", statuses)
                .setParameter("actor", actor).setParameter("payment", payment)
                .getResultList();
        return rows.stream()
                .map(row -> new FacetRow(
                        row[0].toString(),
                        (String) row[1],
                        ((Number) row[2]).longValue()))
                .toList();
    }

    /**
     * 某状态集合下报销单按创建年月（业务时区 Asia/Shanghai，与列表 year/month 筛选口径一致）聚合
     * （表头「年月」筛选桶）。返回 [yyyy-MM, yyyy-MM, count]，最近月份在前。
     */
    public List<FacetRow> monthFacets(Collection<String> statuses, UUID actor, boolean payment) {
        if (statuses == null || statuses.isEmpty()) {
            return List.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT to_char(c.created_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM') AS ym,
                               COUNT(*)
                        FROM expense_claims c
                        WHERE c.is_deleted = false AND c.status IN (:statuses)
                          AND NOT fn_finance_expense_is_application_managed(c.id) AND c.applicant_id<>:actor
                          AND (:payment=false OR c.approved_by IS NULL OR c.approved_by<>:actor)
                          AND (:payment=false OR POSITION(CAST(:actor AS text) IN COALESCE(c.approval_participants,''))=0)
                        GROUP BY ym
                        ORDER BY ym DESC
                        """)
                .setParameter("statuses", statuses)
                .setParameter("actor", actor).setParameter("payment", payment)
                .getResultList();
        return rows.stream()
                .map(row -> new FacetRow(
                        (String) row[0],
                        (String) row[0],
                        ((Number) row[1]).longValue()))
                .toList();
    }

    /**
     * 某状态集合下报销单按明细项类别聚合（表头「类别」筛选桶，2026-09-16）。
     * 类别挂在明细项上：count=含该类别明细的单数（一单多类别会在多桶各计一次）。
     * 返回 [category, category, count]，按类别码稳定序。
     */
    public List<FacetRow> categoryFacets(Collection<String> statuses, UUID actor, boolean payment) {
        if (statuses == null || statuses.isEmpty()) {
            return List.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT i.category, COUNT(DISTINCT i.claim_id)
                        FROM expense_claim_items i
                        JOIN expense_claims c ON c.id = i.claim_id
                        WHERE c.is_deleted = false AND c.status IN (:statuses)
                          AND NOT fn_finance_expense_is_application_managed(c.id) AND c.applicant_id<>:actor
                          AND (:payment=false OR c.approved_by IS NULL OR c.approved_by<>:actor)
                          AND (:payment=false OR POSITION(CAST(:actor AS text) IN COALESCE(c.approval_participants,''))=0)
                        GROUP BY i.category
                        ORDER BY i.category
                        """)
                .setParameter("statuses", statuses)
                .setParameter("actor", actor).setParameter("payment", payment)
                .getResultList();
        return rows.stream()
                .map(row -> new FacetRow(
                        (String) row[0],
                        (String) row[0],
                        ((Number) row[1]).longValue()))
                .toList();
    }

    /**
     * 某状态集合下报销单按单号聚合（表头「报销单号」筛选桶，2026-09-25 单号列统一）。
     * 返回 [claim_no, claim_no, count]，按单号升序（下拉可搜索）；单号恒非空，上限 500。
     */
    public List<FacetRow> claimNoFacets(Collection<String> statuses, UUID actor, boolean payment) {
        if (statuses == null || statuses.isEmpty()) {
            return List.of();
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT c.claim_no, COUNT(*)
                        FROM expense_claims c
                        WHERE c.is_deleted = false AND c.status IN (:statuses)
                          AND NOT fn_finance_expense_is_application_managed(c.id) AND c.applicant_id<>:actor
                          AND (:payment=false OR c.approved_by IS NULL OR c.approved_by<>:actor)
                          AND (:payment=false OR POSITION(CAST(:actor AS text) IN COALESCE(c.approval_participants,''))=0)
                        GROUP BY c.claim_no
                        ORDER BY c.claim_no
                        """)
                .setParameter("statuses", statuses)
                .setParameter("actor", actor).setParameter("payment", payment)
                .setMaxResults(500)
                .getResultList();
        return rows.stream()
                .map(row -> new FacetRow(
                        (String) row[0],
                        (String) row[0],
                        ((Number) row[1]).longValue()))
                .toList();
    }

    /**
     * 本人报销单按单号聚合（我的报销列表「报销单号」筛选桶，2026-09-25 单号列统一）。
     * 返回 [claim_no, claim_no, count]，按单号升序；单号恒非空，上限 500。
     */
    public List<FacetRow> mineClaimNoFacets(UUID actor) { return mineClaimNoFacets(actor,false,false); }

    public List<FacetRow> mineClaimNoFacets(UUID actor, boolean includeDeleted, boolean onlyDeleted) {
        return mineClaimNoFacets(actor, includeDeleted, onlyDeleted, null);
    }

    public List<FacetRow> mineClaimNoFacets(UUID actor, boolean includeDeleted, boolean onlyDeleted, Boolean historyOnly) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = entityManager.createNativeQuery("""
                        SELECT c.claim_no, COUNT(*)
                        FROM expense_claims c
                        WHERE (:onlyDeleted AND c.is_deleted OR NOT :onlyDeleted AND (:includeDeleted OR NOT c.is_deleted)) AND c.applicant_id = :actor
                          AND (CAST(:historyOnly AS boolean) IS NULL
                               OR (:historyOnly = true AND c.status = 'PAID')
                               OR (:historyOnly = false AND c.status <> 'PAID'))
                        GROUP BY c.claim_no
                        ORDER BY c.claim_no
                        """)
                .setParameter("actor", actor).setParameter("includeDeleted",includeDeleted).setParameter("onlyDeleted",onlyDeleted)
                .setParameter("historyOnly", historyOnly)
                .setMaxResults(500)
                .getResultList();
        return rows.stream()
                .map(row -> new FacetRow(
                        (String) row[0],
                        (String) row[0],
                        ((Number) row[1]).longValue()))
                .toList();
    }

    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto abandonedHistoryFacets(UUID actor,boolean includeDeleted,boolean onlyDeleted) {
        return abandonedHistoryFacets(actor,includeDeleted,onlyDeleted,true);
    }
    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto abandonedHistoryFacets(UUID actor,boolean includeDeleted,boolean onlyDeleted,boolean includeClaimNos) {
        String where="""
            FROM expense_claims c WHERE c.applicant_id=:actor AND (
              ((:onlyDeleted AND c.is_deleted OR NOT :onlyDeleted AND (:includeDeleted OR NOT c.is_deleted)) AND c.status='PAID')
              OR (c.is_deleted AND c.status='REJECTED' AND c.abandoned_at IS NOT NULL))
            """;
        var numbers=includeClaimNos?abandonedBuckets("SELECT c.claim_no,c.claim_no,count(*) "+where+" GROUP BY c.claim_no ORDER BY c.claim_no LIMIT 500",actor,includeDeleted,onlyDeleted):List.<com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto.Bucket>of();
        var categories=abandonedBuckets("SELECT i.category,i.category,count(DISTINCT c.id) "+where.replace("FROM expense_claims c","FROM expense_claims c JOIN expense_claim_items i ON i.claim_id=c.id")+" GROUP BY i.category ORDER BY i.category",actor,includeDeleted,onlyDeleted);
        return new com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto(List.of(),List.of(),categories,numbers);
    }

    private List<com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto.Bucket> abandonedBuckets(String sql,UUID actor,boolean includeDeleted,boolean onlyDeleted) {
        return com.uten.imp.common.util.NativeQueryResults.objectArrayRows(entityManager.createNativeQuery(sql).setParameter("actor",actor)
                .setParameter("includeDeleted",includeDeleted).setParameter("onlyDeleted",onlyDeleted)).stream()
                .map(row->new com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto.Bucket(row[0].toString(),row[1].toString(),((Number)row[2]).longValue())).toList();
    }

    public com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto historyFacets(UUID actor,boolean approve,boolean pay) {
        String scope="""
                WHERE c.is_deleted = false AND c.status IN ('APPROVED','REJECTED','PAID')
                  AND ((:approve=true AND (c.approved_by=:actor OR c.rejected_by=:actor)) OR (:pay=true AND c.status='PAID'))
                """;
        return new com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto(
            historyBuckets("SELECT d.id::text,d.name,count(*) FROM expense_claims c JOIN departments d ON d.id=c.applicant_department_id "+scope+" GROUP BY d.id,d.name ORDER BY d.name",actor,approve,pay),
            historyBuckets("SELECT to_char(c.created_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM') ym,to_char(c.created_at AT TIME ZONE 'Asia/Shanghai','YYYY-MM'),count(*) FROM expense_claims c "+scope+" GROUP BY ym ORDER BY ym DESC",actor,approve,pay),
            historyBuckets("SELECT i.category,i.category,count(DISTINCT c.id) FROM expense_claims c JOIN expense_claim_items i ON i.claim_id=c.id "+scope+" GROUP BY i.category ORDER BY i.category",actor,approve,pay),
            // 2026-09-25 单号列统一：报销单号桶（同一历史可见范围）。
            historyBuckets("SELECT c.claim_no,c.claim_no,count(*) FROM expense_claims c "+scope+" GROUP BY c.claim_no ORDER BY c.claim_no",actor,approve,pay));
    }
    @SuppressWarnings("unchecked")
    private List<com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto.Bucket> historyBuckets(String sql,UUID actor,boolean approve,boolean pay) {
        List<Object[]> rows=entityManager.createNativeQuery(sql).setParameter("actor",actor).setParameter("approve",approve)
                .setParameter("pay",pay).getResultList();
        return rows.stream().map(row->new com.uten.imp.features.expenseclaim.dto.ExpenseClaimFacetsDto.Bucket(
                (String)row[0],(String)row[1],((Number)row[2]).longValue())).toList();
    }

    /**
     * 报销五档计数一次取齐(准则 §五：一个模块一个 /counts，不加往返)。ADR-100 补「处理中」
     * 后本来要变成 5 条 count，这里合并成一条多标量子查询的 SELECT。
     *
     * <p>每个子查询自带权限开关且写在 WHERE 第一位：没有对应权限时 Postgres 按 one-time filter
     * 直接短路，既不扫表也不返回数字——「无权限返回 0 且不查库」在 SQL 这一层就成立。
     *
     * <p>本人三档按申请人自己算：draft/rejected 是要本人动手的，processing 是已交出去、
     * 还在审批链上跑的中间态(PAID 是终态，不计)。审批/打款两档沿用队列列表口径，
     * 排除自审，打款再排除本单审核人。
     */
    public QueueCounts queueCounts(UUID actor, boolean apply, boolean approve, boolean pay) {
        Object[] row = (Object[]) entityManager.createNativeQuery("""
                        SELECT
                          (SELECT COUNT(*) FROM expense_claims c
                            WHERE c.is_deleted = false AND :apply = true AND c.applicant_id = :actor AND c.status = 'DRAFT'),
                          (SELECT COUNT(*) FROM expense_claims c
                            WHERE c.is_deleted = false AND :apply = true AND c.applicant_id = :actor AND c.status = 'REJECTED'),
                          (SELECT COUNT(*) FROM expense_claims c
                            WHERE c.is_deleted = false AND :apply = true AND c.applicant_id = :actor
                              AND c.status IN ('SUBMITTED','REVIEWING','APPROVED')),
                          (SELECT COUNT(*) FROM expense_claims c
                            WHERE c.is_deleted = false AND :approve = true AND c.status IN ('SUBMITTED','REVIEWING')
                              AND NOT fn_finance_expense_is_application_managed(c.id) AND c.applicant_id <> :actor),
                          (SELECT COUNT(*) FROM expense_claims c
                            WHERE c.is_deleted = false AND :pay = true AND c.status = 'APPROVED'
                              AND NOT fn_finance_expense_is_application_managed(c.id) AND c.applicant_id <> :actor
                              AND (c.approved_by IS NULL OR c.approved_by <> :actor)
                              AND POSITION(CAST(:actor AS text) IN COALESCE(c.approval_participants,''))=0)
                        """)
                .setParameter("actor", actor)
                .setParameter("apply", apply)
                .setParameter("approve", approve)
                .setParameter("pay", pay)
                .getSingleResult();
        return new QueueCounts(count(row[0]), count(row[1]), count(row[2]),
                count(row[3]), count(row[4]));
    }

    private static long count(Object value) {
        return value == null ? 0 : ((Number) value).longValue();
    }

    /** 报销计数五档：本人草稿 / 本人驳回待修订 / 本人处理中 / 待我审核 / 待我打款。 */
    public record QueueCounts(long draft, long rejected, long processing,
                              long pendingApproval, long pendingPayment) {
    }

    public record ApplicantSnapshot(String name, UUID departmentId) {
    }

    /** 筛选桶行：value=回传筛选值（部门 id / yyyy-MM），label=展示名，count=命中数。 */
    public record FacetRow(String value, String label, long count) {
    }
}
