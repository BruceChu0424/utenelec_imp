package com.uten.imp.features.master.supplier;

import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.CategoryKeywordSearch;

import com.uten.imp.common.concurrency.OptimisticLocks;
import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.SettlementMethodReferenceResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.master.supplier.dto.FacetBucket;
import com.uten.imp.features.master.supplier.dto.SupplierDetail;
import com.uten.imp.features.master.supplier.dto.SupplierDictItem;
import com.uten.imp.features.master.supplier.dto.SupplierFacets;
import com.uten.imp.features.master.supplier.dto.SupplierListItem;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
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
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 供应商主档：子树范围列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（supplier:edit）。
 *
 * <p>列表用 {@link Specification} 复刻 {@code GoodsService.list} 范式：子树 id 集合（复用
 * {@link SupplierCategoryRepository#findSubtree} 递归 CTE）+ keyword 多字段 OR + 字段精确等值 +
 * {@code nullFields} 空值白名单。19 个可筛字段（与用户列表面板一一对应，主结账方式/损耗率无对应列）。
 *
 * <p>facets 用原生 SQL 聚合（字段→列名硬编码白名单，防注入；列名非用户输入）。
 */
@Service
@RequiredArgsConstructor
public class SupplierService {

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of(
            "name", "description", "tday", "place", "empId", "ownerEmployeeId", "legalPerson",
            "linkman", "mobile", "phone", "phone2", "fax", "postcode", "address", "bank",
            "bankAccount", "taxId", "website", "shipVia", "shipAddress");

    /** 列排序白名单：前端列 key → JPA 实体属性名（数量列；命中才排序，否则默认 code ASC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("tday", "tday");

    /** facet 截断阈值（高基数列如 name/address 取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /**
     * facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。
     * empId 不在此列：桶值是业务员 UUID（owner_employee_id）、label 需 JOIN employees
     * 出人名，走 {@link #ownerFacet} 专用聚合。
     */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("description", "description");
        FACET_COLUMNS.put("tday", "tday");
        FACET_COLUMNS.put("place", "place");
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
        FACET_COLUMNS.put("website", "website");
        FACET_COLUMNS.put("shipVia", "ship_via");
        FACET_COLUMNS.put("shipAddress", "ship_address");
    }

    private final SupplierRepository repo;
    private final SupplierCategoryRepository categoryRepo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final CategoryDrivenCodeService categoryCodes;
    private final com.uten.imp.features.org.employee.EmployeeRepository employeeRepo;
    private final EmployeeNameResolver employeeNameResolver;

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<SupplierListItem> list(SupplierQueryFilter f, int page, int size, String sort, String order) {
        validateReadFilter(f);
        List<UUID> subtreeIds = (f.categoryId() == null) ? null : resolveSubtreeIds(f.categoryId());
        var keyword = keywordPlan(f.keyword());
        Sort defaultSort = Sort.by(Sort.Direction.ASC, "code").and(Sort.by(Sort.Direction.ASC, "id"));
        Sort requestedSort = TableSort.resolve(sort, order, defaultSort, ALLOWED_SORT);
        Specification<Supplier> spec = supplierSpec(f, subtreeIds, keyword, requestedSort);
        Pageable pageable = Pageables.of(page, size, keyword.active() ? Sort.unsorted() : requestedSort);
        Page<Supplier> p = com.uten.imp.common.export.MasterExportSource.page(repo, em, Supplier.class, spec, pageable, f);
        Map<UUID, String> settlementNames = settlementMethodNames(p.getContent());
        Map<UUID, String> ownerNames = p.isEmpty() ? Map.of() : employeeNameResolver.namesOf(
                p.getContent().stream().map(Supplier::getOwnerEmployeeId).toList());
        List<SupplierListItem> items = new ArrayList<>(p.getContent().stream()
                .map(supplier -> toList(supplier, supplier.getDefaultSettlementMethodId() == null
                        ? null : settlementNames.get(supplier.getDefaultSettlementMethodId()),
                        supplier.getOwnerEmployeeId() == null ? null : ownerNames.get(supplier.getOwnerEmployeeId())))
                .toList());
        applySubcontractLossRates(items);
        return new PageResponse<>(items, p);
    }

    private Specification<Supplier> supplierSpec(SupplierQueryFilter f, List<UUID> subtreeIds,
            CategoryKeywordSearch.Plan keyword, Sort requestedSort) {
        return (Root<Supplier> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                        CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(com.uten.imp.features.master.search.MasterColumnSearch.predicate(cb, root.get("id"),
                    com.uten.imp.features.master.search.MasterColumnSearch.Domain.SUPPLIER, f.columnSearch()));
            // 单据选商口径：仅「使用」状态（老库 status 为空的按启用处理）可被选择。
            if (f.selectableOnly()) {
                ps.add(cb.or(
                        cb.isNull(root.get("status")),
                        cb.equal(root.get("status"), "使用")));
                ps.add(cb.isFalse(root.get("internalWorkshop")));
            }
            if (subtreeIds != null) {
                ps.add(root.get("category").get("id").in(subtreeIds));
            }
            if (!KeywordSearch.terms(f.keyword()).isEmpty()) {
                List<jakarta.persistence.criteria.Expression<String>> visible = List.of(root.get("code"), root.get("name"), root.get("linkman"), root.get("legalPerson"), root.get("place"), root.get("mobile"));
                ps.add(keyword.predicate(cb, root.get("category").get("id"), visible,
                        List.of(root.get("description"))));
                if (q != null && q.getResultType() != Long.class) {
                    CategoryKeywordSearch.order(q, cb, root,
                            keyword.rank(cb, root.get("category").get("id"), root.get("code"), root.get("name"), visible), requestedSort);
                }
            }
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "description", f.description());
            addEq(ps, cb, root, "place", f.place());
            addEq(ps, cb, root, "empId", f.empId());
            if (f.ownerEmployeeId() != null) {
                ps.add(cb.equal(root.get("ownerEmployeeId"), f.ownerEmployeeId()));
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
            addEq(ps, cb, root, "shipVia", f.shipVia());
            addEq(ps, cb, root, "shipAddress", f.shipAddress());
            // tday 为 Integer：单独处理（非 String addEq）。
            if (f.tday() != null) ps.add(cb.equal(root.get("tday"), f.tday()));
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

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Supplier> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    private List<UUID> resolveSubtreeIds(UUID categoryId) {
        return categoryRepo.findSubtree(categoryId).stream().map(SupplierCategory::getId).toList();
    }

    // ===== 加密 Excel 导出（服务端权威列定义） =====

    /**
     * 加密 Excel 导出：复用 list 的同一筛选/映射，后台以 100 行游标批次输出；同步仅保留有界小结果。
     * 列定义服务端权威；过滤/排序走 list 已接的 TableSort 白名单（tday）。
     * 2026-09-25 口径「表格显示啥导出啥」：补「损耗率(%)」（ADR-098 汇总视图，表格已有）；
     * 「业务员」导解析人名（空显「未分配」，与表格同兜底），不再导旧库 empId 数字串。
     * 主结账方式与详情/列表同源，按 default_settlement_method_id 解析，不使用旧快照猜测。
     */
    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ExportPayload export(SupplierQueryFilter f, String sort, String order, int maxRows) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("name", "供应商简称", ExportColumn.TEXT),
                new ExportColumn("description", "全称", ExportColumn.TEXT),
                new ExportColumn("priceStyle", "主结账方式", ExportColumn.TEXT),
                new ExportColumn("tday", "信用天数", ExportColumn.NUMBER),
                new ExportColumn("lossRate", "损耗率(%)", ExportColumn.NUMBER),
                new ExportColumn("place", "所属地区", ExportColumn.TEXT),
                new ExportColumn("ownerEmployeeName", "业务员", ExportColumn.TEXT),
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
                new ExportColumn("website", "网址", ExportColumn.TEXT),
                new ExportColumn("shipVia", "运输方式", ExportColumn.TEXT),
                new ExportColumn("shipAddress", "送货地址", ExportColumn.TEXT));
        // 行数上限读系统设置「导出行数上限」(调用方传入), 与报表、审计导出同一口径。
        return com.uten.imp.common.export.MasterExportSource.exportEntities(em, cols,
                maxRows, (p, size) -> list(f, p, size, sort, order), m -> {
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("_platformRecordId", m.getId());
                    row.put("name", m.getName());
                    row.put("description", m.getDescription());
                    row.put("priceStyle", m.getDefaultSettlementMethodName());
                    row.put("tday", m.getTday());
                    row.put("lossRate", m.getLossRate());
                    row.put("place", m.getPlace());
                    row.put("ownerEmployeeName",
                            m.getOwnerEmployeeName() == null || m.getOwnerEmployeeName().isBlank()
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
                    row.put("website", m.getWebsite());
                    row.put("shipVia", m.getShipVia());
                    row.put("shipAddress", m.getShipAddress());
                    return row;
                });
    }

    // ===== facets（子树范围内各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public SupplierFacets facets(UUID categoryId) {
        List<UUID> ids = categoryId == null ? null : resolveSubtreeIds(categoryId);
        String categoryClause = ids == null ? "" : " and category_id in (:ids)";
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            var fq = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from suppliers "
                            + "where is_deleted = false" + categoryClause + " and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT);
            if (ids != null) fq.setParameter("ids", ids);
            List<Object[]> rows = NativeQueryResults.objectArrayRows(fq);
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            var nq = em.createNativeQuery(
                    "select count(*) from suppliers "
                            + "where is_deleted = false" + categoryClause + " and " + col + " is null");
            if (ids != null) nq.setParameter("ids", ids);
            Long nc = ((Number) nq.getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        // 业务员（empId）桶：值=owner_employee_id（employees.id）、label=人名；空值=未设置业务员。
        buckets.put("empId", ownerFacet(ids));
        nullCounts.put("empId", ownerNullCount(ids));
        return new SupplierFacets(
                buckets.get("name"), buckets.get("description"), buckets.get("tday"),
                buckets.get("place"), buckets.get("empId"), buckets.get("legalPerson"),
                buckets.get("linkman"), buckets.get("mobile"), buckets.get("phone"),
                buckets.get("phone2"), buckets.get("fax"), buckets.get("postcode"),
                buckets.get("address"), buckets.get("bank"), buckets.get("bankAccount"),
                buckets.get("taxId"), buckets.get("website"), buckets.get("shipVia"),
                buckets.get("shipAddress"),
                nullCounts);
    }

    /**
     * 业务员 facet 桶：JOIN employees 按 employees.id 分组、label 出人名（范式同
     * {@code GoodsService#refFacet}）。不使用别名（suppliers/employees 全名引用），
     * 避免两表同名列（is_deleted 等）歧义。
     */
    private List<FacetBucket> ownerFacet(List<UUID> ids) {
        var fq = em.createNativeQuery(
                "select employees.id as v, employees.full_name as label, count(*) as c "
                        + "from suppliers join employees on employees.id = suppliers.owner_employee_id "
                        + "where suppliers.is_deleted = false " + (ids == null ? "" : "and suppliers.category_id in (:ids) ")
                        + "and suppliers.owner_employee_id is not null "
                        + "group by employees.id, employees.full_name "
                        + "order by c desc, label asc limit " + FACET_LIMIT);
        if (ids != null) fq.setParameter("ids", ids);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(fq);
        List<FacetBucket> list = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            list.add(new FacetBucket(String.valueOf(row[0]),
                    ((Number) row[2]).longValue(), String.valueOf(row[1])));
        }
        return list;
    }

    /** 业务员空值计数：owner_employee_id 为 null（前端列显「未分配」）的行数。 */
    private Long ownerNullCount(List<UUID> ids) {
        var nq = em.createNativeQuery(
                "select count(*) from suppliers "
                        + "where is_deleted = false " + (ids == null ? "" : "and category_id in (:ids) ") + "and owner_employee_id is null");
        if (ids != null) nq.setParameter("ids", ids);
        return ((Number) nq.getSingleResult()).longValue();
    }

    // ===== 详情 / CRUD（不变） =====

    /** 全量字典（采购单据页按 id 解析供应商名用）：全部未软删供应商，按名称排序。
     *  含禁用项（status 供前端下拉过滤，名称解析需全量）；排除内部车间。 */
    @Transactional(readOnly = true)
    public List<SupplierDictItem> dict() {
        // 排除内部车间：车间=部门，不再作为委外商可选
        return repo.findAll(dictionarySpec(), Sort.by(Sort.Direction.ASC, "name")).stream()
                .map(SupplierService::dictionaryItem).toList();
    }

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public List<SupplierDictItem> lookup(Set<UUID> ids) {
        if (ids == null || ids.isEmpty()) return List.of();
        if (ids.size() > com.uten.imp.common.validation.RequestLimits.LOOKUP_IDS || ids.stream().anyMatch(java.util.Objects::isNull))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "供应商名称一次最多读取200个有效UUID");
        var spec = dictionarySpec().and((root, q, cb) -> root.get("id").in(ids));
        return repo.findAll(spec, Sort.by("name").and(Sort.by("id"))).stream().map(SupplierService::dictionaryItem).toList();
    }

    private static SupplierDictItem dictionaryItem(Supplier supplier) {
        return new SupplierDictItem(supplier.getId(), supplier.getCode(), supplier.getName(), supplier.getStatus(),
                supplier.getDefaultSettlementMethodId());
    }

    private Specification<Supplier> dictionarySpec() {
        return (root, q, cb) -> cb.and(
                cb.isFalse(root.get("deleted")),
                cb.isFalse(root.get("internalWorkshop")));
    }

    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public com.uten.imp.common.web.MasterSearchContext searchContext(SupplierQueryFilter filter, int page, int size) {
        validateReadFilter(filter);
        var subtreeIds = filter.categoryId() == null ? null : resolveSubtreeIds(filter.categoryId());
        var spec = supplierSpec(filter, subtreeIds, keywordPlan(filter.keyword()), Sort.unsorted());
        return com.uten.imp.common.web.CategorySearchContext.read(em, Supplier.class, spec, "category", page, size);
    }

    private static void validateReadFilter(SupplierQueryFilter filter) {
        com.uten.imp.features.master.dto.ContactSensitiveFilter.requireBoundedReadValues(
                filter.keyword(), filter.mobile(), filter.phone(), filter.phone2(), filter.bankAccount());
    }

    @Transactional(readOnly = true)
    public SupplierDetail detail(UUID id) {
        return toDetail(requireSupplier(id));
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('supplier:create')")
    @Transactional
    public SupplierDetail create(SupplierSaveRequest req) {
        tx.bind();
        if (req.getStatus() != null && !"使用".equals(req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("supplier:status");
        }
        Supplier m = new Supplier();
        apply(req, m);
        applyCodeAllocation(m, categoryCodes.allocate(
                CategoryDrivenCodeService.MasterType.SUPPLIER,
                m.getCategory().getId(), req.getCode()));
        if (m.getStatus() == null) m.setStatus("使用");
        repo.save(m);
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('supplier:edit', 'supplier:status')")
    @Transactional
    public SupplierDetail update(UUID id, SupplierSaveRequest req) {
        tx.bind();
        com.uten.imp.security.CurrentAuthorityGuard.requireAll("supplier:edit");
        Supplier m = requireSupplier(id);
        // 乐观锁：编辑回传版本与当前不符 → 409（记录已被他人修改）。null 放行（兼容旧客户端）。
        OptimisticLocks.requireUpToDate(m.getVersion(), req.getVersion());
        if (req.getStatus() != null && !java.util.Objects.equals(m.getStatus(), req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("supplier:status");
        }
        CategoryCodeAllocation currentCode = currentCodeAllocation(m);
        apply(req, m);
        applyCodeAllocation(m, categoryCodes.allocateForUpdate(
                CategoryDrivenCodeService.MasterType.SUPPLIER,
                m.getId(), m.getCategory().getId(), req.getCode(), currentCode));
        repo.save(m);
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('supplier:status')")
    @Transactional
    public SupplierDetail changeStatus(
            UUID id, com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        tx.bind();
        Supplier m = requireSupplier(id);
        em.refresh(m, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        OptimisticLocks.requireUpToDate(m.getVersion(), req.version());
        m.setStatus(req.status());
        repo.save(m);
        return toDetail(m);
    }


    private void apply(SupplierSaveRequest req, Supplier m) {
        m.setCategory(requireCategory(req.getCategoryId()));
        m.setName(req.getName());
        m.setDescription(req.getDescription());
        m.setPlace(req.getPlace());
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
        m.setBank(req.getBank());
        m.setBankAccount(req.getBankAccount());
        m.setTaxId(req.getTaxId());
        m.setInitTotal(req.getInitTotal());
        m.setTday(req.getTday());
        applyDefaultSettlementMethod(req, m);
        applyDefaultCurrency(req, m);
        if (req.getDefaultTaxRate() != null) {
            m.setDefaultTaxRate(req.getDefaultTaxRate());
        }
        m.setStatus(req.getStatus());
        m.setRemark(req.getRemark());
    }

    /**
     * 默认结算方式 UUID 真源（V452，镜像 ClientService#applyDefaultSettlementMethod）：
     * 传 null 显式清空时同步清掉旧库快照；DB 触发器 fn_sync_supplier_default_settlement_reference
     * 另有一致性兜底（UUID 必须指向使用中的结算方式，price_style 由 UUID 同步）。
     */
    /** 默认币种（V593）：presence 语义同结账方式；必须存在且未软删。 */
    private void applyDefaultCurrency(SupplierSaveRequest req, Supplier supplier) {
        if (!req.hasDefaultCurrencyReference()) return;
        UUID id = req.getDefaultCurrencyId();
        if (id == null) {
            supplier.setDefaultCurrencyId(null);
            return;
        }
        var found = em.createNativeQuery(
                        "SELECT id FROM currencies WHERE id = :id AND is_deleted = false")
                .setParameter("id", id)
                .getResultList();
        if (!(found instanceof List<?> rows) || rows.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "币种不存在");
        }
        supplier.setDefaultCurrencyId(id);
    }

    private void applyDefaultSettlementMethod(
            SupplierSaveRequest req, Supplier supplier) {
        if (!req.hasDefaultSettlementMethodReference()) return;
        UUID id = req.getDefaultSettlementMethodId();
        if (id == null) {
            supplier.setDefaultSettlementMethodId(null);
            supplier.setPriceStyle(null);
            return;
        }
        var method = SettlementMethodReferenceResolver.resolve(
                em, id, null, "供应商默认结算方式");
        supplier.setDefaultSettlementMethodId(method.id());
        supplier.setPriceStyle(method.legacyId());
    }

    private static CategoryCodeAllocation currentCodeAllocation(Supplier supplier) {
        return new CategoryCodeAllocation(
                supplier.getCode(), supplier.getCodeSequence(),
                supplier.getCodePrefixCategoryId(), supplier.isCodeManaged());
    }

    private static void applyCodeAllocation(Supplier supplier, CategoryCodeAllocation allocation) {
        supplier.setCode(allocation.code());
        supplier.setCodeSequence(allocation.sequence());
        supplier.setCodePrefixCategoryId(allocation.prefixCategoryId());
        supplier.setCodeManaged(allocation.managed());
    }

    private SupplierDetail toDetail(Supplier m) {
        UUID categoryId = m.getCategory() == null ? null : m.getCategory().getId();
        String categoryName = m.getCategory() == null ? null : m.getCategory().getName();
        String settlementMethodName = m.getDefaultSettlementMethodId() == null
                ? null
                : settlementMethodNames(List.of(m)).get(m.getDefaultSettlementMethodId());
        return new SupplierDetail(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getPlace(),
                m.getLinkman(), m.getLegacyId(),
                categoryId, categoryName, m.getDescription(), m.getEmpId(), m.getLegalPerson(),
                m.getMobile(), m.getPhone(), m.getPhone2(), m.getFax(), m.getPostcode(),
                m.getAddress(), m.getEmail(), m.getWebsite(), m.getShipVia(), m.getShipAddress(),
                m.getBank(), m.getBankAccount(), m.getTaxId(), m.getInitTotal(), m.getTday(),
                m.getRemark(), m.getVersion(), m.getOwnerEmployeeId(),
                employeeNameResolver.nameOf(m.getOwnerEmployeeId()),
                m.getDefaultSettlementMethodId(),
                settlementMethodName,
                m.getDefaultCurrencyId(),
                currencyName(m.getDefaultCurrencyId()),
                m.getDefaultTaxRate());
    }

    /** 币种名（详情展示；软删/缺行回落 null）。 */
    private String currencyName(UUID id) {
        if (id == null) return null;
        var rows = em.createNativeQuery(
                        "SELECT name FROM currencies WHERE id = :id AND is_deleted = false")
                .setParameter("id", id)
                .getResultList();
        return rows.isEmpty() ? null : String.valueOf(rows.get(0));
    }

    private Map<UUID, String> settlementMethodNames(List<Supplier> suppliers) {
        Set<UUID> ids = suppliers.stream()
                .map(Supplier::getDefaultSettlementMethodId)
                .filter(java.util.Objects::nonNull)
                .collect(java.util.stream.Collectors.toSet());
        if (ids.isEmpty()) return Map.of();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT method.id, method.name
                        FROM settlement_methods method
                        WHERE method.id IN (:ids)
                        """)
                        .setParameter("ids", ids));
        Map<UUID, String> names = new LinkedHashMap<>();
        for (Object[] row : rows) {
            names.put((UUID) row[0], row[1] == null ? null : row[1].toString());
        }
        return names;
    }

    private SupplierListItem toList(Supplier m, String settlementMethodName, String ownerEmployeeName) {
        return new SupplierListItem(
                m.getId(), m.getLegacyId(),
                m.getName(), m.getDescription(), m.getTday(), m.getPlace(),
                m.getEmpId(), m.getLegalPerson(), m.getLinkman(), m.getMobile(),
                m.getPhone(), m.getPhone2(), m.getFax(), m.getPostcode(), m.getAddress(),
                m.getBank(), m.getBankAccount(), m.getTaxId(), m.getWebsite(),
                m.getShipVia(), m.getShipAddress(),
                m.getCategory() == null ? null : m.getCategory().getId(),
                ownerEmployeeName,
                null, m.getVersion(), m.getStatus(), m.getDefaultSettlementMethodId(), settlementMethodName);
    }

    /**
     * ADR-098 供应商列表「损耗率(%)」列：一次点查页内供应商的委外加权损耗率(视图
     * v_subcontract_supplier_loss_summary 是共享库读模型, 不引委外 Java 代码)。没有结清行的供应商保持空。
     */
    private void applySubcontractLossRates(List<SupplierListItem> items) {
        List<UUID> ids = items.stream().map(SupplierListItem::getId).filter(java.util.Objects::nonNull).toList();
        if (ids.isEmpty()) return;
        Map<UUID, java.math.BigDecimal> rates = new LinkedHashMap<>();
        for (Object[] row : com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        SELECT supplier_id, loss_pct
                        FROM v_subcontract_supplier_loss_summary
                        WHERE supplier_id IN (:ids)
                        """).setParameter("ids", ids))) {
            rates.put((UUID) row[0], (java.math.BigDecimal) row[1]);
        }
        for (SupplierListItem item : items) {
            item.setLossRate(rates.get(item.getId()));
        }
    }

    private SupplierCategory requireCategory(UUID id) {
        return categoryRepo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "供应商分类不存在"));
    }

    private void applyOwnerEmployee(SupplierSaveRequest req, Supplier supplier) {
        if (!req.hasOwnerEmployeeReference()) return;
        UUID id = req.getOwnerEmployeeId();
        if (id == null) {
            supplier.setOwnerEmployeeId(null);
            supplier.setEmpId(null);
            return;
        }
        var employee = employeeRepo.findById(id)
                .filter(e -> !e.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "业务员不存在"));
        supplier.setOwnerEmployeeId(employee.getId());
        supplier.setEmpId(employee.getLegacyId() == null ? null : employee.getLegacyId().toString());
    }

    private Supplier requireSupplier(UUID id) {
        return repo.findById(id)
                .filter(m -> !m.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "供应商不存在"));
    }
}
