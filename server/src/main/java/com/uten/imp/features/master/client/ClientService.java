package com.uten.imp.features.master.client;

import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.CategoryKeywordSearch;

import com.uten.imp.common.concurrency.OptimisticLocks;
import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.SettlementMethodReferenceResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientDictItem;
import com.uten.imp.features.master.client.dto.ClientFacets;
import com.uten.imp.features.master.client.dto.ClientListItem;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.client.dto.FacetBucket;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 客户主档：子树范围列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（client:edit）。
 *
 * <p>范式照抄 {@code GoodsService}：list 用 {@link Specification}（子树 id 集合 +
 * keyword 多字段 OR + 字段精确等值 + {@code nullFields} 空值白名单），facets 用原生 SQL
 * 聚合（字段→列名硬编码白名单，防注入；列名非用户输入）。
 *
 * <p>子树汇总由 {@link ClientCategoryRepository#findSubtree} 递归 CTE 实现——客户主档会
 * 直接挂在有子分类的节点上（如「外贸(钟)」既有子分类又直接挂客户），子树才能一次看全。
 */
@Service
@RequiredArgsConstructor
public class ClientService {

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径；UUID 关联名称不走旧字段 facet。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of(
            "code", "name", "fullName", "clientXz", "tday", "region", "placeId",
            "empId", "ownerEmployeeId", "legalPerson", "linkman", "mobile", "phone", "phone2", "fax",
            "postcode", "address", "bank", "bankAccount", "taxId", "credit", "creditFloor", "website");

    /** 列排序白名单：前端列 key → JPA 实体属性名（金额/数量列；命中才排序，否则默认 code ASC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "tday", "tday", "credit", "credit", "creditFloor", "creditFloor");

    /** facet 截断阈值（高基数列取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /**
     * facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。
     * 与 {@link #ALLOWED_NULL_FIELDS} 同步。empId 不在此列：桶值是负责人 UUID、
     * label 需 JOIN employees 出人名，走 {@link #ownerFacet} 专用聚合。
     */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("code", "code");
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("fullName", "full_name");
        FACET_COLUMNS.put("clientXz", "client_xz");
        FACET_COLUMNS.put("tday", "tday");
        FACET_COLUMNS.put("region", "region");
        FACET_COLUMNS.put("placeId", "place_id");
        FACET_COLUMNS.put("legalPerson", "legal_person");
        FACET_COLUMNS.put("linkman", "linkman");
        FACET_COLUMNS.put("mobile", "mobile");
        FACET_COLUMNS.put("phone", "phone");
        FACET_COLUMNS.put("phone2", "phone2");
        FACET_COLUMNS.put("fax", "fax");
        FACET_COLUMNS.put("postcode", "postcode");
        FACET_COLUMNS.put("address", "address");
        FACET_COLUMNS.put("bank", "bank");
        FACET_COLUMNS.put("bankAccount", "bank_account");
        FACET_COLUMNS.put("taxId", "tax_id");
        FACET_COLUMNS.put("credit", "credit");
        FACET_COLUMNS.put("creditFloor", "credit_floor");
        FACET_COLUMNS.put("website", "website");
    }

    private final ClientRepository repo;
    private final ClientCategoryRepository categoryRepo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final CategoryDrivenCodeService categoryCodes;
    private final ClientAccessPolicy clientAccessPolicy;
    private final com.uten.imp.features.org.employee.EmployeeRepository employeeRepo;
    private final EmployeeNameResolver employeeNameResolver;

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public PageResponse<ClientListItem> list(ClientQueryFilter f, int page, int size, String sort, String order) {
        validateReadFilter(f);
        List<UUID> subtreeIds = (f.categoryId() == null) ? null : resolveSubtreeIds(f.categoryId());
        ClientAccessPolicy.ClientScope accessScope = clientAccessPolicy.evaluate();
        var keyword = keywordPlan(f.keyword());
        Sort defaultSort = Sort.by(Sort.Direction.ASC, "code").and(Sort.by(Sort.Direction.ASC, "id"));
        Sort requestedSort = TableSort.resolve(sort, order, defaultSort, ALLOWED_SORT);
        Specification<Client> spec = clientSpec(f, subtreeIds, accessScope, keyword, requestedSort);
        Pageable pageable = Pageables.of(page, size, keyword.active() ? Sort.unsorted() : requestedSort);
        Page<Client> p = com.uten.imp.common.export.MasterExportSource.page(repo, em, Client.class, spec, pageable, f);
        Map<UUID, String> settlementNames = settlementMethodNames(p.getContent());
        Map<UUID, String> ownerNames = p.isEmpty() ? Map.of() : employeeNameResolver.namesOf(
                p.getContent().stream().map(Client::getOwnerEmployeeId).toList());
        Map<UUID, List<OwnerReference>> owners = ownerReferences(p.getContent(), ownerNames);
        return new PageResponse<>(
                p.getContent().stream()
                        // settlementNames 可能为空 Map.of()（不可变），null key 的 get 会抛 NPE，先判空。
                        .map(client -> toList(
                                client,
                                client.getDefaultSettlementMethodId() == null
                                        ? null
                                        : settlementNames.get(client.getDefaultSettlementMethodId()),
                                client.getOwnerEmployeeId() == null ? null : ownerNames.get(client.getOwnerEmployeeId()),
                                accessScope, owners.getOrDefault(client.getId(), List.of())))
                        .toList(),
                p);
    }

    /** 全量字典（单据名称解析用；client:view 全员有）。无此端点时 /dict 会落到 /{id} 报 Invalid UUID。 */
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public List<ClientDictItem> dict() {
        return dict(true);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public List<ClientDictItem> dict(boolean excludeLegacyFinanceStub) {
        ClientAccessPolicy.ClientScope scope = clientAccessPolicy.evaluate();
        return repo.findAll(dictionarySpec(scope, excludeLegacyFinanceStub), Sort.by(Sort.Direction.ASC, "name")).stream()
                .map(ClientService::dictionaryItem).toList();
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public List<ClientDictItem> lookup(Set<UUID> ids, boolean excludeLegacyFinanceStub) {
        if (ids == null || ids.isEmpty()) return List.of();
        if (ids.size() > com.uten.imp.common.validation.RequestLimits.LOOKUP_IDS || ids.stream().anyMatch(Objects::isNull))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户名称一次最多读取200个有效UUID");
        var scope = clientAccessPolicy.evaluate();
        var spec = dictionarySpec(scope, excludeLegacyFinanceStub).and((root, q, cb) -> root.get("id").in(ids));
        return repo.findAll(spec, Sort.by("name").and(Sort.by("id"))).stream().map(ClientService::dictionaryItem).toList();
    }

    private static ClientDictItem dictionaryItem(Client client) {
        return new ClientDictItem(client.getId(), client.getCode(), client.getName(), "使用".equals(client.getStatus()));
    }

    private Specification<Client> dictionarySpec(ClientAccessPolicy.ClientScope scope, boolean excludeLegacyFinanceStub) {
        return (root, q, cb) -> {
            List<Predicate> predicates = new ArrayList<>();
            predicates.add(cb.isFalse(root.get("deleted")));
            predicates.add(clientAccessPolicy.readablePredicate(root, q, cb, scope));
            if (excludeLegacyFinanceStub) {
                predicates.add(cb.or(
                        cb.isNull(root.get("code")),
                        cb.notLike(cb.lower(root.get("code")), "legacy-fin-cl-%")));
            }
            return cb.and(predicates.toArray(Predicate[]::new));
        };
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public com.uten.imp.common.web.MasterSearchContext searchContext(ClientQueryFilter filter, int page, int size) {
        validateReadFilter(filter);
        var subtreeIds = filter.categoryId() == null ? null : resolveSubtreeIds(filter.categoryId());
        var scope = clientAccessPolicy.evaluate();
        var spec = clientSpec(filter, subtreeIds, scope, keywordPlan(filter.keyword()), Sort.unsorted());
        return com.uten.imp.common.web.CategorySearchContext.read(em, Client.class, spec, "category", page, size);
    }

    private static void validateReadFilter(ClientQueryFilter filter) {
        com.uten.imp.common.web.ContactSensitiveFilter.requireBoundedReadValues(
                filter.keyword(), filter.mobile(), filter.phone(), filter.phone2(), filter.bankAccount());
    }

    private Specification<Client> clientSpec(ClientQueryFilter f, List<UUID> subtreeIds,
            ClientAccessPolicy.ClientScope accessScope, CategoryKeywordSearch.Plan keyword, Sort requestedSort) {
        return (Root<Client> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                      CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(com.uten.imp.features.master.search.MasterColumnSearch.predicate(cb, root.get("id"),
                    com.uten.imp.features.master.search.MasterColumnSearch.Domain.CLIENT, f.columnSearch()));
            if (f.excludeLegacyFinanceStub()) {
                ps.add(cb.or(
                        cb.isNull(root.get("code")),
                        cb.notLike(cb.lower(root.get("code")), "legacy-fin-cl-%")));
            }
            if (f.selectableOnly()) {
                ps.add(cb.equal(root.get("status"), "使用"));
            }
            ps.add(clientAccessPolicy.readablePredicate(root, q, cb, accessScope));
            if (subtreeIds != null) {
                ps.add(root.get("category").get("id").in(subtreeIds));
            }
            if (!KeywordSearch.terms(f.keyword()).isEmpty()) {
                List<jakarta.persistence.criteria.Expression<String>> visible = List.of(root.get("name"), root.get("code"), root.get("fullName"), root.get("nameEn"), root.get("email"), root.get("linkman"), root.get("mobile"));
                ps.add(keyword.predicate(cb, root.get("category").get("id"), visible,
                        List.of()));
                if (q != null && q.getResultType() != Long.class) {
                    CategoryKeywordSearch.order(q, cb, root,
                            keyword.rank(cb, root.get("category").get("id"), root.get("code"), root.get("name"), visible), requestedSort);
                }
            }
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "fullName", f.fullName());
            addEq(ps, cb, root, "clientXz", f.clientXz());
            addEq(ps, cb, root, "region", f.region());
            addEq(ps, cb, root, "placeId", f.placeId());
            addEq(ps, cb, root, "empId", f.empId());
            if (f.ownerEmployeeId() != null) {
                ps.add(clientAccessPolicy.ownerPredicate(root, q, cb, Set.of(f.ownerEmployeeId())));
            }
            addEq(ps, cb, root, "legalPerson", f.legalPerson());
            addEq(ps, cb, root, "linkman", f.linkman());
            addEq(ps, cb, root, "mobile", f.mobile());
            addEq(ps, cb, root, "phone", f.phone());
            addEq(ps, cb, root, "phone2", f.phone2());
            addEq(ps, cb, root, "fax", f.fax());
            addEq(ps, cb, root, "postcode", f.postcode());
            addEq(ps, cb, root, "address", f.address());
            addEq(ps, cb, root, "bank", f.bank());
            addEq(ps, cb, root, "bankAccount", f.bankAccount());
            addEq(ps, cb, root, "taxId", f.taxId());
            addEq(ps, cb, root, "website", f.website());
            if (f.tday() != null) ps.add(cb.equal(root.get("tday"), f.tday()));
            if (f.credit() != null) ps.add(cb.equal(root.get("credit"), f.credit()));
            if (f.creditFloor() != null) ps.add(cb.equal(root.get("creditFloor"), f.creditFloor()));
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    private CategoryKeywordSearch.Plan keywordPlan(String query) {
        return CategoryKeywordSearch.plan(query, KeywordSearch.terms(query).isEmpty() ? List.of()
                : categoryRepo.findByDeletedFalseOrderBySortOrderAscNameAsc().stream()
                .map(node -> new CategoryKeywordSearch.Node(node.getId(), node.getParent() == null ? null : node.getParent().getId(),
                        node.getName(), node.getCode())).toList());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Client> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    private List<UUID> resolveSubtreeIds(UUID categoryId) {
        return categoryRepo.findSubtree(categoryId).stream().map(ClientCategory::getId).toList();
    }

    // ===== 加密 Excel 导出（服务端权威列定义） =====

    /**
     * 加密 Excel 导出：复用 list 的同一筛选/映射，后台以 100 行游标批次输出；同步仅保留有界小结果。
     * 列定义服务端权威；过滤/排序走 list 已接的 TableSort 白名单（tday/credit）。
     * 2026-09-25 口径「表格显示啥导出啥」：列集与前端表格一致——「负责人」导解析人名
     * （空显「未分配」，与表格同兜底），不再导旧库 empId 数字串；表格没有「状态」列
     * （启停走前导分组/行菜单），导出同步不带。
     */
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ExportPayload export(ClientQueryFilter f, String sort, String order, int maxRows) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("code", "客户编码", ExportColumn.TEXT),
                new ExportColumn("name", "客户简称", ExportColumn.TEXT),
                new ExportColumn("fullName", "客户全称", ExportColumn.TEXT),
                new ExportColumn("nameEn", "外文名称", ExportColumn.TEXT),
                new ExportColumn("defaultSettlementMethodName", "主结账方式", ExportColumn.TEXT),
                new ExportColumn("clientXz", "客户性质", ExportColumn.TEXT),
                new ExportColumn("tday", "信用天数", ExportColumn.NUMBER),
                new ExportColumn("region", "区域", ExportColumn.TEXT),
                new ExportColumn("placeId", "所属地区", ExportColumn.TEXT),
                new ExportColumn("ownerEmployeeName", "负责人", ExportColumn.TEXT),
                new ExportColumn("legalPerson", "法人代表", ExportColumn.TEXT),
                new ExportColumn("linkman", "联系人", ExportColumn.TEXT),
                new ExportColumn("mobile", "手机", ExportColumn.TEXT),
                new ExportColumn("phone", "联系电话", ExportColumn.TEXT),
                new ExportColumn("phone2", "备用电话", ExportColumn.TEXT),
                new ExportColumn("fax", "传真", ExportColumn.TEXT),
                new ExportColumn("postcode", "邮编", ExportColumn.TEXT),
                new ExportColumn("address", "地址", ExportColumn.TEXT),
                new ExportColumn("bank", "开户银行", ExportColumn.TEXT),
                new ExportColumn("bankAccount", "银行账号", ExportColumn.TEXT),
                new ExportColumn("taxId", "纳税号", ExportColumn.TEXT),
                new ExportColumn("credit", "信用额度 / 旧库 Credit 快照", ExportColumn.MONEY),
                new ExportColumn("creditFloor", "铺底额", ExportColumn.MONEY),
                new ExportColumn("website", "网址", ExportColumn.TEXT));
        // 行数上限读系统设置「导出行数上限」(调用方传入), 与报表、审计导出同一口径。
        return com.uten.imp.common.export.MasterExportSource.exportEntities(em, cols,
                maxRows, (p, size) -> list(f, p, size, sort, order), m -> {
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("_platformRecordId", m.getId());
                    row.put("code", m.getCode());
                    row.put("name", m.getName());
                    row.put("fullName", m.getFullName());
                    row.put("nameEn", m.getNameEn());
                    row.put("defaultSettlementMethodName", m.getDefaultSettlementMethodName());
                    row.put("clientXz", m.getClientXz());
                    row.put("tday", m.getTday());
                    row.put("region", m.getRegion());
                    row.put("placeId", m.getPlaceId());
                    row.put("ownerEmployeeName",
                            !m.getOwnerEmployeeNames().isEmpty() ? String.join("、", m.getOwnerEmployeeNames()) : m.getOwnerEmployeeName() == null || m.getOwnerEmployeeName().isBlank()
                                    ? "未分配" : m.getOwnerEmployeeName());
                    row.put("legalPerson", m.getLegalPerson());
                    row.put("linkman", m.getLinkman());
                    row.put("mobile", m.getMobile());
                    row.put("phone", m.getPhone());
                    row.put("phone2", m.getPhone2());
                    row.put("fax", m.getFax());
                    row.put("postcode", m.getPostcode());
                    row.put("address", m.getAddress());
                    row.put("bank", m.getBank());
                    row.put("bankAccount", m.getBankAccount());
                    row.put("taxId", m.getTaxId());
                    row.put("credit", m.getCredit());
                    row.put("creditFloor", m.getCreditFloor());
                    row.put("website", m.getWebsite());
                    return row;
                });
    }

    // ===== facets（子树范围内各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ClientFacets facets(UUID categoryId) {
        return facets(categoryId, true);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ClientFacets facets(UUID categoryId, boolean excludeLegacyFinanceStub) {
        List<UUID> ids = categoryId == null ? null : resolveSubtreeIds(categoryId);
        String categoryClause = ids == null ? "" : " and category_id in (:ids)";
        ClientAccessPolicy.ClientScope accessScope = clientAccessPolicy.evaluate();
        ClientAccessPolicy.NativeReadScope accessSql =
                clientAccessPolicy.nativeReadScope("", accessScope);
        String legacyStubClause = excludeLegacyFinanceStub
                ? " and (code is null or lower(code) not like 'legacy-fin-cl-%')"
                : "";
        // JOIN employees 的负责人聚合用全限定版（两表都有 code/is_deleted，裸列名会歧义）。
        String legacyStubClauseQualified = excludeLegacyFinanceStub
                ? " and (clients.code is null or lower(clients.code) not like 'legacy-fin-cl-%')"
                : "";
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            var fq = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from clients "
                            + "where is_deleted = false" + categoryClause + " and " + col + " is not null "
                            + legacyStubClause + " and " + accessSql.predicate()
                            + " group by " + col + " order by c desc, v asc limit " + FACET_LIMIT);
            if (ids != null) fq.setParameter("ids", ids);
            accessSql.bind(fq);
            List<Object[]> rows = NativeQueryResults.objectArrayRows(fq);
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            var nq = em.createNativeQuery(
                    "select count(*) from clients "
                            + "where is_deleted = false" + categoryClause + " and " + col + " is null"
                            + legacyStubClause + " and " + accessSql.predicate());
            if (ids != null) nq.setParameter("ids", ids);
            accessSql.bind(nq);
            Long nc = ((Number) nq.getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        // 负责人（empId）桶：值=owner_employee_id（employees.id）、label=人名；空值=未分配负责人。
        buckets.put("empId", ownerFacet(ids, legacyStubClauseQualified, accessSql));
        nullCounts.put("empId", ownerNullCount(ids, legacyStubClause, accessSql));
        return new ClientFacets(
                buckets.get("code"), buckets.get("name"), buckets.get("fullName"),
                buckets.get("clientXz"), buckets.get("tday"), buckets.get("region"),
                buckets.get("placeId"), buckets.get("empId"), buckets.get("legalPerson"),
                buckets.get("linkman"), buckets.get("mobile"), buckets.get("phone"),
                buckets.get("phone2"), buckets.get("fax"), buckets.get("postcode"),
                buckets.get("address"), buckets.get("bank"), buckets.get("bankAccount"),
                buckets.get("taxId"), buckets.get("credit"), buckets.get("website"),
                nullCounts);
    }

    /**
     * 负责人 facet 桶：JOIN employees 按 employees.id 分组、label 出人名（范式同
     * {@code GoodsService#refFacet}）。不使用别名（clients/employees 全名引用），
     * 使 {@code accessSql.predicate()} 里的 {@code clients.xxx} 引用继续成立。
     */
    private List<FacetBucket> ownerFacet(
            List<UUID> ids, String legacyStubClause, ClientAccessPolicy.NativeReadScope accessSql) {
        var fq = em.createNativeQuery(
                "select employees.id as v, employees.full_name as label, count(*) as c "
                        + "from clients join employees on (employees.id = clients.owner_employee_id "
                        + "or exists(select 1 from client_co_owners co_owner where co_owner.client_id=clients.id and co_owner.employee_id=employees.id)) "
                        + "where clients.is_deleted = false " + (ids == null ? "" : "and clients.category_id in (:ids) ")
                        + "and clients.owner_employee_id is not null "
                        + legacyStubClause + " and " + accessSql.predicate()
                        + " group by employees.id, employees.full_name "
                        + "order by c desc, label asc limit " + FACET_LIMIT);
        if (ids != null) fq.setParameter("ids", ids);
        accessSql.bind(fq);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(fq);
        List<FacetBucket> list = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            list.add(new FacetBucket(String.valueOf(row[0]),
                    ((Number) row[2]).longValue(), String.valueOf(row[1])));
        }
        return list;
    }

    /** 负责人空值计数：owner_employee_id 为 null（前端列显「未分配」）的行数。 */
    private Long ownerNullCount(
            List<UUID> ids, String legacyStubClause, ClientAccessPolicy.NativeReadScope accessSql) {
        var nq = em.createNativeQuery(
                "select count(*) from clients "
                        + "where is_deleted = false " + (ids == null ? "" : "and category_id in (:ids) ") + "and owner_employee_id is null"
                        + legacyStubClause + " and " + accessSql.predicate());
        if (ids != null) nq.setParameter("ids", ids);
        accessSql.bind(nq);
        return ((Number) nq.getSingleResult()).longValue();
    }

    // ===== 详情 / CRUD（不变） =====

    private void requireReadable(Client client) {
        clientAccessPolicy.requireReadable(client, clientAccessPolicy.evaluate());
    }

    private void requireWritable(Client client) {
        clientAccessPolicy.requireWritable(client, clientAccessPolicy.evaluate());
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ClientDetail detail(UUID id) {
        Client m = requireClient(id);
        ClientAccessPolicy.ClientScope scope = clientAccessPolicy.evaluate();
        clientAccessPolicy.requireReadable(m, scope);
        return toDetail(m, scope);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('client:create')")
    @Transactional
    public ClientDetail create(ClientSaveRequest req) {
        tx.bind();
        // 货款类型 V607 起可不填（未分类客户财务放行前有专门闸门要求补选）；
        // 编号 readOnly 不上送 → allocate(null) 按分类前缀自动发号。
        prepareOwnerForCreate(req);
        requireCoreFields(req);
        if (!ClientFinancialPolicy.hasAuthority()) requireNewFinancialDefaults(req);
        if (req.getStatus() != null && !"使用".equals(req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("client:status");
        }
        Client m = new Client();
        apply(req, m);
        applyCodeAllocation(m, categoryCodes.allocate(
                CategoryDrivenCodeService.MasterType.CLIENT,
                m.getCategory() == null ? null : m.getCategory().getId(), req.getCode()));
        if (m.getStatus() == null) m.setStatus("使用");
        repo.save(m);
        em.flush();
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('client:edit', 'client:finance')")
    @Transactional
    public ClientDetail update(UUID id, ClientSaveRequest req) {
        tx.bind();
        Client m = requireClient(id);
        var scope = clientAccessPolicy.evaluate();
        clientAccessPolicy.requireReadable(m, scope);
        boolean ordinary = hasOrdinaryEditAuthority() && clientAccessPolicy.canWrite(m, scope);
        boolean financial = ClientFinancialPolicy.hasAuthority() && clientAccessPolicy.canWrite(m, scope);
        if (!ordinary && !financial) throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        requireOwnerUnchanged(req, m);
        // 乐观锁：编辑回传的版本与当前不符 → 409（记录已被他人修改）。null 放行（兼容旧客户端）。
        OptimisticLocks.requireUpToDate(m.getVersion(), req.getVersion());
        if (req.hasFinancialField("credit")) requireLegacyCreditSnapshotUnchanged(m, req.getCredit());
        if (!financial) requireFinancialUnchanged(m, req);
        if (!ordinary) {
            requireOrdinaryUnchanged(m, req);
            applyFinancial(req, m);
            repo.save(m);
            em.flush();
            return toDetail(m, scope);
        }
        requireCoreFields(req);
        if (req.getStatus() != null && !Objects.equals(m.getStatus(), req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("client:status");
        }
        CategoryCodeAllocation currentCode = currentCodeAllocation(m);
        apply(req, m);
        applyCodeAllocation(m, categoryCodes.allocateForUpdate(
                CategoryDrivenCodeService.MasterType.CLIENT,
                m.getId(), m.getCategory() == null ? null : m.getCategory().getId(),
                req.getCode(), currentCode));
        repo.save(m);
        em.flush();
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('client:status')")
    @Transactional
    public ClientDetail changeStatus(
            UUID id, com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        req.requireValidStatus();
        tx.bind();
        Client m = requireClientForUpdate(id);
        ClientAccessPolicy.ClientScope scope = clientAccessPolicy.evaluate();
        clientAccessPolicy.requireWritable(m, scope);
        OptimisticLocks.requireUpToDate(m.getVersion(), req.version());
        m.setStatus(req.status());
        repo.save(m);
        return toDetail(m, scope);
    }


    private void apply(ClientSaveRequest req, Client m) {
        m.setCategory(requireCategory(req.getCategoryId()));
        m.setName(req.getName());
        m.setFullName(req.getFullName());
        applyNameEn(req, m);
        m.setClientRank(req.getClientRank());
        m.setRegion(req.getRegion());
        m.setPlaceId(req.getPlaceId());
        applyOwnerEmployee(req, m);
        m.setLegalPerson(req.getLegalPerson());
        m.setLinkman(req.getLinkman());
        m.setMobile(req.getMobile());
        m.setPhone(req.getPhone());
        m.setPhone2(req.getPhone2());
        m.setFax(req.getFax());
        m.setPostcode(req.getPostcode());
        m.setAddress(req.getAddress());
        m.setEmail(req.getEmail());
        m.setWebsite(req.getWebsite());
        m.setShipVia(req.getShipVia());
        m.setShipAddress(req.getShipAddress());
        applyDefaultShipmentPolicy(req, m);
        if (ClientFinancialPolicy.hasAuthority()) applyFinancial(req, m);
        m.setStatus(req.getStatus());
        m.setRemark(req.getRemark());
    }

    private static CategoryCodeAllocation currentCodeAllocation(Client client) {
        return new CategoryCodeAllocation(
                client.getCode(), client.getCodeSequence(),
                client.getCodePrefixCategoryId(), client.isCodeManaged());
    }

    private static void applyCodeAllocation(Client client, CategoryCodeAllocation allocation) {
        client.setCode(allocation.code());
        client.setCodeSequence(allocation.sequence());
        client.setCodePrefixCategoryId(allocation.prefixCategoryId());
        client.setCodeManaged(allocation.managed());
    }

    private ClientDetail toDetail(Client m) {
        return toDetail(m, clientAccessPolicy.evaluate());
    }

    private ClientDetail toDetail(Client m, ClientAccessPolicy.ClientScope scope) {
        UUID categoryId = m.getCategory() == null ? null : m.getCategory().getId();
        String categoryName = m.getCategory() == null ? null : m.getCategory().getName();
        String settlementMethodName = m.getDefaultSettlementMethodId() == null
                ? null
                : settlementMethodNames(List.of(m)).get(m.getDefaultSettlementMethodId());
        var detail = new ClientDetail(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getRegion(),
                m.getLinkman(), m.getLegacyId(),
                categoryId, categoryName, m.getFullName(), m.getClientRank(),
                m.getPlaceId(), m.getEmpId(), m.getLegalPerson(), m.getMobile(),
                m.getPhone(), m.getPhone2(), m.getFax(), m.getPostcode(), m.getAddress(),
                m.getEmail(), m.getWebsite(), m.getShipVia(), m.getShipAddress(),
                m.getBank(), m.getBankAccount(), m.getTaxId(), m.getCredit(),
                m.getInitTotal(), m.getTday(), m.getCreditFloor(), m.getRemark(),
                m.getVersion(), m.getOwnerEmployeeId(),
                employeeNameResolver.nameOf(m.getOwnerEmployeeId()),
                m.getDefaultSettlementMethodId(),
                settlementMethodName,
                clientAccessPolicy.canWrite(m, scope),
                clientAccessPolicy.canManageAccess(m, scope),
                clientAccessPolicy.accessReason(m, scope),
                m.getDefaultShipmentPolicy(),
                m.getDefaultCurrencyId(),
                currencyName(m.getDefaultCurrencyId()),
                m.getNameEn(), List.of(), List.of(), false);
        var owners = ownerReferences(List.of(m)).getOrDefault(m.getId(), List.of());
        detail.setOwnerEmployeeIds(owners.stream().map(OwnerReference::id).toList());
        detail.setOwnerEmployeeNames(owners.stream().map(OwnerReference::name).toList());
        detail.setFinancialWritable(ClientFinancialPolicy.hasAuthority() && clientAccessPolicy.canWrite(m, scope));
        return detail;
    }

    private ClientListItem toList(
            Client m,
            String settlementMethodName,
            String ownerEmployeeName,
            ClientAccessPolicy.ClientScope scope, List<OwnerReference> owners) {
        var item = new ClientListItem(
                m.getId(), m.getCode(), m.getName(), m.getFullName(), m.getClientXz(),
                m.getTday(), m.getRegion(), m.getPlaceId(), m.getEmpId(), m.getLegalPerson(),
                m.getLinkman(), m.getMobile(), m.getPhone(), m.getPhone2(), m.getFax(),
                m.getPostcode(), m.getAddress(), m.getBank(), m.getBankAccount(), m.getTaxId(),
                m.getCredit(), m.getCreditFloor(), m.getWebsite(), m.getStatus(), m.getLegacyId(),
                m.getCategory() == null ? null : m.getCategory().getId(),
                m.getOwnerEmployeeId(),
                ownerEmployeeName,
                m.getDefaultSettlementMethodId(), settlementMethodName,
                writableFromOwners(scope, owners),
                scope != null && scope.canAssign() && (m.getOwnerEmployeeId() == null || writableFromOwners(scope, owners)),
                m.getVersion(),
                m.getNameEn(), List.of(), List.of(), false);
        item.setOwnerEmployeeIds(owners.stream().map(OwnerReference::id).toList());
        // 首负责人名字解析不到(老库未匹配/悬空引用)不进多负责人展示，表格与导出兜底「未分配」；
        // 共同负责人行由 JOIN employees 保证存在，名字空时在 ownerReferences 里显「未命名员工」。
        item.setOwnerEmployeeNames(owners.stream().map(OwnerReference::name)
                .filter(name -> name != null && !name.isBlank()).toList());
        item.setFinancialWritable(ClientFinancialPolicy.hasAuthority() && writableFromOwners(scope, owners));
        return item;
    }

    private record OwnerReference(UUID id, String name) {}
    private static boolean writableFromOwners(ClientAccessPolicy.ClientScope scope,
            List<OwnerReference> owners) {
        return scope != null && (scope.ownerScope().seeAll()
                || owners.stream().anyMatch(owner -> scope.ownerScope().writableOwners().contains(owner.id())));
    }
    private Map<UUID, List<OwnerReference>> ownerReferences(List<Client> clients) {
        return ownerReferences(clients, employeeNameResolver.namesOf(clients.stream().map(Client::getOwnerEmployeeId).toList()));
    }
    private Map<UUID, List<OwnerReference>> ownerReferences(List<Client> clients, Map<UUID, String> primaryNames) {
        if (clients.isEmpty()) return Map.of();
        var result = new HashMap<UUID, List<OwnerReference>>();
        for (Client client : clients) {
            var refs = new ArrayList<OwnerReference>();
            if (client.getOwnerEmployeeId() != null) refs.add(new OwnerReference(client.getOwnerEmployeeId(),
                    primaryNames.get(client.getOwnerEmployeeId())));
            result.put(client.getId(), refs);
        }
        // One bounded query per list page, never one lookup per co-owner.
        var ids = clients.stream().map(Client::getId).filter(Objects::nonNull).toList();
        if (ids.isEmpty()) return result;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT co_owner.client_id, employee.id, employee.full_name
                FROM client_co_owners co_owner JOIN employees employee ON employee.id=co_owner.employee_id
                WHERE co_owner.client_id IN (:ids)
                ORDER BY co_owner.client_id, co_owner.sort_order, employee.id
                """).setParameter("ids", ids));
        for (var row : rows) result.get((UUID)row[0]).add(new OwnerReference((UUID)row[1], Objects.toString(row[2], "未命名员工")));
        return result;
    }

    private static boolean hasOrdinaryEditAuthority() {
        try { com.uten.imp.security.CurrentAuthorityGuard.requireAll("client:edit"); return true; }
        catch (ApiException denied) { return false; }
    }

    private static void requireCoreFields(ClientSaveRequest req) {
        if (req.getCategoryId() == null || req.getName() == null || req.getName().isBlank())
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户名称及分类必填");
    }

    private void applyFinancial(ClientSaveRequest req, Client client) {
        if (req.hasFinancialField("bank")) client.setBank(req.getBank());
        if (req.hasFinancialField("bankAccount")) client.setBankAccount(req.getBankAccount());
        if (req.hasFinancialField("taxId")) client.setTaxId(req.getTaxId());
        if (req.hasFinancialField("credit")) client.setCredit(req.getCredit());
        if (req.hasFinancialField("initTotal")) client.setInitTotal(req.getInitTotal());
        if (req.hasFinancialField("tday")) client.setTday(req.getTday());
        if (req.hasFinancialField("creditFloor")) client.setCreditFloor(normalizeCreditFloor(req.getCreditFloor()));
        applyDefaultSettlementMethod(req, client);
        applyDefaultCurrency(req, client);
    }

    static void requireFinancialUnchanged(Client client, ClientSaveRequest req) {
        // Resolve authority from the server principal alone so the per-field loop
        // below never conditions an authorization check on request content.
        boolean authorized = ClientFinancialPolicy.hasAuthority();
        for (String field : ClientFinancialPolicy.FINANCIAL_FIELDS) {
            boolean present = switch (field) {
                case "defaultSettlementMethodId" -> req.hasDefaultSettlementMethodReference();
                case "defaultCurrencyId" -> req.hasDefaultCurrencyReference();
                default -> req.hasFinancialField(field);
            };
            Object requested = present ? property(req, field) : null;
            Object stored = property(client, field);
            if (present && !sameValue(requested, stored) && !authorized)
                throw new ApiException(ErrorCode.FORBIDDEN, "客户财务资料仅限具有财务维护权限的人员修改");
        }
    }

    static void requireNewFinancialDefaults(ClientSaveRequest req) {
        for (String field : ClientFinancialPolicy.FINANCIAL_FIELDS) {
            Object value = property(req, field);
            boolean empty = value == null || value instanceof String text && text.isBlank()
                    || value instanceof BigDecimal decimal && decimal.signum() == 0
                    || value instanceof Integer integer && integer == 0;
            if (!empty) ClientFinancialPolicy.requireAuthority();
        }
    }

    private static void requireOrdinaryUnchanged(Client client, ClientSaveRequest req) {
        for (String field : List.of("name", "code", "fullName", "clientRank", "region", "placeId", "legalPerson",
                "linkman", "mobile", "phone", "phone2", "fax", "postcode", "address", "email", "website",
                "shipVia", "shipAddress", "status", "remark", "nameEn", "defaultShipmentPolicy")) {
            Object requested = property(req, field);
            if (requested != null && !sameValue(requested, property(client, field)))
                throw new ApiException(ErrorCode.FORBIDDEN, "当前账号只能维护客户财务资料");
        }
        if (req.getCategoryId() != null && (client.getCategory() == null
                || !req.getCategoryId().equals(client.getCategory().getId())))
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号不能修改客户分类");
    }

    private static Object property(Object bean, String field) {
        try { return bean.getClass().getMethod("get" + Character.toUpperCase(field.charAt(0)) + field.substring(1)).invoke(bean); }
        catch (ReflectiveOperationException failure) { throw new IllegalStateException(failure); }
    }
    private static boolean sameValue(Object left, Object right) {
        if (left instanceof BigDecimal a && right instanceof BigDecimal b) return a.compareTo(b) == 0;
        if (left instanceof String a && (right == null || right instanceof String))
            return Objects.equals(a.isBlank() ? null : a, right == null || right.toString().isBlank() ? null : right);
        return Objects.equals(left, right);
    }

    private Map<UUID, String> settlementMethodNames(List<Client> clients) {
        Set<UUID> ids = clients.stream()
                .map(Client::getDefaultSettlementMethodId)
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());
        if (ids.isEmpty()) return Map.of();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT method.id, method.name
                        FROM settlement_methods method
                        WHERE method.id IN (:ids)
                        """)
                        .setParameter("ids", ids));
        Map<UUID, String> names = new HashMap<>();
        for (Object[] row : rows) {
            names.put((UUID) row[0], row[1] == null ? null : row[1].toString());
        }
        return names;
    }

    private ClientCategory requireCategory(UUID id) {
        return categoryRepo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "客户分类不存在"));
    }

    private void applyOwnerEmployee(ClientSaveRequest req, Client client) {
        if (!req.hasOwnerEmployeeReference()) return;
        UUID id = req.getOwnerEmployeeId();
        if (id == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户负责人不能为空");
        }
        if (Objects.equals(client.getOwnerEmployeeId(), id)) return;
        var employee = employeeRepo.findById(id)
                .filter(e -> !e.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "业务员不存在"));
        if (!CurrentEmployeeStatusPolicy.isCurrentEmployee(employee.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "客户负责人必须是在职、试用或留职员工");
        }
        if (!id.equals(clientAccessPolicy.requireCurrentEmployeeId())) {
            Number activeAccounts = (Number) em.createNativeQuery("""
                            SELECT count(*) FROM users account
                            WHERE account.employee_id = :employeeId
                              AND account.is_deleted = FALSE
                              AND account.status = 'active'
                            """)
                    .setParameter("employeeId", id)
                    .getSingleResult();
            if (activeAccounts.longValue() == 0L) {
                throw new ApiException(ErrorCode.CONFLICT, "客户负责人必须具有启用的登录账号");
            }
        }
        client.setOwnerEmployeeId(employee.getId());
        client.setEmpId(employee.getLegacyId() == null ? null : employee.getLegacyId().toString());
    }

    private void prepareOwnerForCreate(ClientSaveRequest request) {
        UUID currentEmployeeId = clientAccessPolicy.requireCurrentEmployeeId();
        if (!request.hasOwnerEmployeeReference()) {
            request.setOwnerEmployeeId(currentEmployeeId);
            return;
        }
        UUID requestedOwnerId = request.getOwnerEmployeeId();
        if (requestedOwnerId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户负责人不能为空");
        }
        if (!requestedOwnerId.equals(currentEmployeeId)
                && !clientAccessPolicy.hasAssignAuthority()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只能把新客户归属给本人");
        }
    }

    private static void requireOwnerUnchanged(ClientSaveRequest request, Client client) {
        if (!request.hasOwnerEmployeeReference()) return;
        UUID requestedOwnerId = request.getOwnerEmployeeId();
        if (requestedOwnerId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户负责人不能为空");
        }
        if (!Objects.equals(requestedOwnerId, client.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "负责人变更请使用客户资料中的「归属与可见人」设置");
        }
    }

    private void applyDefaultSettlementMethod(
            ClientSaveRequest req, Client client) {
        if (!req.hasDefaultSettlementMethodReference()) return;
        UUID id = req.getDefaultSettlementMethodId();
        if (id == null) {
            client.setDefaultSettlementMethodId(null);
            client.setPriceStyle(null);
            return;
        }
        var method = SettlementMethodReferenceResolver.resolve(
                em, id, null, "客户默认结账方式");
        client.setDefaultSettlementMethodId(method.id());
        client.setPriceStyle(method.legacyId());
    }

    /**
     * 默认货运策略 (V592)：presence 语义同结账方式/币种——请求没带这个键=不动。
     *
     * <p>这一列由保存销售订货单自动写回 (ClientDefaultTermsSyncService)。按老的
     * 「字符串字段整体覆盖」写法, 任何只提交部分字段的客户端保存一次客户就会把
     * 自动学到的值抹成 null。带了空串/空白=用户显式清空。
     */
    private void applyDefaultShipmentPolicy(ClientSaveRequest req, Client client) {
        if (!req.hasDefaultShipmentPolicy()) return;
        String raw = req.getDefaultShipmentPolicy();
        String trimmed = raw == null ? null : raw.trim();
        client.setDefaultShipmentPolicy(
                trimmed == null || trimmed.isEmpty() ? null : trimmed);
    }

    /** 默认币种（V592）：presence 语义同结账方式；必须存在且未软删。 */
    private void applyDefaultCurrency(ClientSaveRequest req, Client client) {
        if (!req.hasDefaultCurrencyReference()) return;
        UUID id = req.getDefaultCurrencyId();
        if (id == null) {
            client.setDefaultCurrencyId(null);
            return;
        }
        var found = em.createNativeQuery(
                        "SELECT id FROM currencies WHERE id = :id AND is_deleted = false")
                .setParameter("id", id)
                .getResultList();
        if (!(found instanceof List<?> rows) || rows.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "币种不存在");
        }
        client.setDefaultCurrencyId(id);
    }

    /** 外文名称(ADR-134): presence 语义, 没带键不动; 首尾空白去掉、连续空白合并, 空白归一为 null。 */
    private static void applyNameEn(ClientSaveRequest req, Client client) {
        if (!req.hasNameEn()) return;
        String raw = req.getNameEn();
        String value = raw == null ? null : raw.strip().replaceAll("(?U)\\s+", " ");
        client.setNameEn(value == null || value.isEmpty() ? null : value);
    }

    /** 币种名（详情展示用；软删/缺行回落 null）。 */
    private String currencyName(UUID id) {
        if (id == null) return null;
        var rows = em.createNativeQuery(
                        "SELECT name FROM currencies WHERE id = :id AND is_deleted = false")
                .setParameter("id", id)
                .getResultList();
        return rows.isEmpty() ? null : String.valueOf(rows.get(0));
    }

    static BigDecimal normalizeCreditFloor(BigDecimal value) {
        if (value == null) return BigDecimal.ZERO;
        BigDecimal normalized = value.stripTrailingZeros();
        int fractionalDigits = Math.max(normalized.scale(), 0);
        int integerDigits = Math.max(normalized.precision() - normalized.scale(), 0);
        if (value.signum() < 0 || fractionalDigits > 4 || integerDigits > 14) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "铺底额必须为非负数，最多 14 位整数和 4 位小数");
        }
        return value;
    }

    static void requireLegacyCreditSnapshotUnchanged(
            Client client, BigDecimal requestedCredit) {
        if (client.getLegacyId() == null) return;
        BigDecimal stored = client.getCredit();
        boolean unchanged = stored == null
                ? requestedCredit == null
                : requestedCredit != null && stored.compareTo(requestedCredit) == 0;
        if (!unchanged) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "这里显示的是旧系统导入的铺底参考值，不能当作信用额度来改；正式信用额度需另行核准");
        }
    }

    private Client requireClient(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "客户不存在"));
    }

    private Client requireClientForUpdate(UUID id) {
        Client client = em.find(Client.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (client == null || client.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
        return client;
    }
}
