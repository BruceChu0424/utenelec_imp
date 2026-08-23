package com.uten.imp.features.master.client;

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

import java.math.BigDecimal;
import java.time.OffsetDateTime;
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
            "empId", "legalPerson", "linkman", "mobile", "phone", "phone2", "fax",
            "postcode", "address", "bank", "bankAccount", "taxId", "credit", "website");

    /** 列排序白名单：前端列 key → JPA 实体属性名（金额/数量列；命中才排序，否则默认 code ASC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "tday", "tday", "credit", "credit");

    /** facet 截断阈值（高基数列取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /**
     * facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。
     * 与 {@link #ALLOWED_NULL_FIELDS} 同步：21 个有 DB 列的字段。
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
        FACET_COLUMNS.put("empId", "emp_id");
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
        FACET_COLUMNS.put("website", "website");
    }

    private final ClientRepository repo;
    private final ClientCategoryRepository categoryRepo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final CategoryDrivenCodeService categoryCodes;
    private final com.uten.imp.security.OwnerVisibility ownerVisibility;
    private final com.uten.imp.features.org.employee.EmployeeRepository employeeRepo;
    private final EmployeeNameResolver employeeNameResolver;

    // ===== 归属可见性（每个销售只看自己的客户；判定逻辑统一在 OwnerVisibility） =====

    /** facets 原生 SQL 片段：归属过滤 AND 子句（参数名 :__ownerEmp；无需绑参时 bindEmp[0]=false）。 */
    private String ownerClause(boolean[] bindEmp) {
        var scope = ownerVisibility.evaluate("client", "client:view:all");
        if (scope.seeAll()) { bindEmp[0] = false; return ""; }
        if (scope.visibleOwners().isEmpty()) { bindEmp[0] = false; return " and owner_employee_id is null"; }
        bindEmp[0] = true;
        return " and (owner_employee_id is null or owner_employee_id in (:__ownerEmp))";
    }

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<ClientListItem> list(ClientQueryFilter f, int page, int size, String sort, String order) {
        List<UUID> subtreeIds = (f.categoryId() == null) ? null : resolveSubtreeIds(f.categoryId());
        Specification<Client> spec = (Root<Client> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                      CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.excludeLegacyFinanceStub()) {
                ps.add(cb.or(
                        cb.isNull(root.get("code")),
                        cb.notLike(cb.lower(root.get("code")), "legacy-fin-cl-%")));
            }
            // 归属可见性（每个销售只看自己的客户）：公共客户或可见归属人；超管/client:view:all 全见
            var scope = ownerVisibility.evaluate("client", "client:view:all");
            if (!scope.seeAll()) {
                if (scope.visibleOwners().isEmpty()) {
                    ps.add(cb.isNull(root.get("ownerEmployeeId")));
                } else {
                    ps.add(cb.or(cb.isNull(root.get("ownerEmployeeId")),
                            root.get("ownerEmployeeId").in(scope.visibleOwners())));
                }
            }
            if (subtreeIds != null) {
                ps.add(root.get("category").get("id").in(subtreeIds));
            }
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("name")), like),
                        cb.like(cb.lower(root.get("code")), like),
                        cb.like(cb.lower(root.get("fullName")), like),
                        cb.like(cb.lower(root.get("linkman")), like),
                        cb.like(cb.lower(root.get("mobile")), like)));
            }
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "fullName", f.fullName());
            addEq(ps, cb, root, "clientXz", f.clientXz());
            addEq(ps, cb, root, "region", f.region());
            addEq(ps, cb, root, "placeId", f.placeId());
            addEq(ps, cb, root, "empId", f.empId());
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
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.ASC, "code"), ALLOWED_SORT));
        Page<Client> p = repo.findAll(spec, pageable);
        Map<UUID, String> settlementNames = settlementMethodNames(p.getContent());
        return new PageResponse<>(
                p.getContent().stream()
                        // settlementNames 可能为空 Map.of()（不可变），null key 的 get 会抛 NPE，先判空。
                        .map(client -> toList(
                                client,
                                client.getDefaultSettlementMethodId() == null
                                        ? null
                                        : settlementNames.get(client.getDefaultSettlementMethodId())))
                        .toList(),
                page, size, p.getTotalElements(), p.getTotalPages());
    }

    /** 全量字典（单据名称解析用；client:view 全员有）。无此端点时 /dict 会落到 /{id} 报 Invalid UUID。 */
    @Transactional(readOnly = true)
    public List<ClientDictItem> dict() {
        var scope = ownerVisibility.evaluate("client", "client:view:all");
        Specification<Client> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        return repo.findAll(spec, Sort.by(Sort.Direction.ASC, "name")).stream()
                .filter(client -> scope.seeAll()
                        || client.getOwnerEmployeeId() == null
                        || scope.visibleOwners().contains(client.getOwnerEmployeeId()))
                .map(client -> new ClientDictItem(
                        client.getId(),
                        client.getCode(),
                        client.getName(),
                        "\u4f7f\u7528".equals(client.getStatus())))
                .toList();
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
     * 加密 Excel 导出：循环 list 分页累积全部行（size=100），硬上限 1000 页=10万行防 OOM。
     * 列定义服务端权威；过滤/排序走 list 已接的 TableSort 白名单（tday/credit）。
     * 覆盖前端表格的业务列；默认结账方式按 UUID 批量解析名称，总监无对应列。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(ClientQueryFilter f, String sort, String order) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("code", "客户编码", ExportColumn.TEXT),
                new ExportColumn("name", "客户简称", ExportColumn.TEXT),
                new ExportColumn("fullName", "客户全称", ExportColumn.TEXT),
                new ExportColumn("defaultSettlementMethodName", "主结账方式", ExportColumn.TEXT),
                new ExportColumn("clientXz", "客户性质", ExportColumn.TEXT),
                new ExportColumn("tday", "信用天数", ExportColumn.NUMBER),
                new ExportColumn("region", "区域", ExportColumn.TEXT),
                new ExportColumn("placeId", "所属地区", ExportColumn.TEXT),
                new ExportColumn("empId", "业务员", ExportColumn.TEXT),
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
                new ExportColumn("credit", "信誉额度", ExportColumn.MONEY),
                new ExportColumn("website", "网址", ExportColumn.TEXT),
                new ExportColumn("status", "状态", ExportColumn.TEXT));
        List<Map<String, Object>> rows = new ArrayList<>();
        int pageSize = 100;
        int maxPages = 1000;
        long total = -1;
        for (int p = 1; p <= maxPages; p++) {
            PageResponse<ClientListItem> page = list(f, p, pageSize, sort, order);
            if (total < 0) total = page.getTotal();
            for (ClientListItem m : page.getItems()) {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("code", m.getCode());
                row.put("name", m.getName());
                row.put("fullName", m.getFullName());
                row.put("defaultSettlementMethodName", m.getDefaultSettlementMethodName());
                row.put("clientXz", m.getClientXz());
                row.put("tday", m.getTday());
                row.put("region", m.getRegion());
                row.put("placeId", m.getPlaceId());
                row.put("empId", m.getEmpId());
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
                row.put("website", m.getWebsite());
                row.put("status", m.getStatus());
                rows.add(row);
            }
            if (page.getItems().size() < pageSize) break;
            if (rows.size() >= total) break;
            if (p == maxPages && rows.size() < total) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "导出数据超过 10 万行上限，请收窄筛选条件后重试");
            }
        }
        return new ExportPayload(cols, rows, rows.size());
    }

    // ===== facets（子树范围内各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public ClientFacets facets(UUID categoryId) {
        if (categoryId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "categoryId 必填");
        }
        List<UUID> ids = resolveSubtreeIds(categoryId);
        // 归属可见性（每个销售只看自己的客户）：与 list() 同规则
        boolean[] bindEmp = new boolean[1];
        String ownerClause = ownerClause(bindEmp);
        java.util.Set<UUID> ownerEmps = ownerVisibility.evaluate("client", "client:view:all").visibleOwners();
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            var fq = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from clients "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is not null "
                            + ownerClause
                            + " group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .setParameter("ids", ids);
            if (bindEmp[0]) fq.setParameter("__ownerEmp", ownerEmps);
            List<Object[]> rows = NativeQueryResults.objectArrayRows(fq);
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            var nq = em.createNativeQuery(
                    "select count(*) from clients "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is null"
                            + ownerClause)
                    .setParameter("ids", ids);
            if (bindEmp[0]) nq.setParameter("__ownerEmp", ownerEmps);
            Long nc = ((Number) nq.getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
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

    // ===== 详情 / CRUD（不变） =====

    /**
     * 归属可见性守卫（详情/编辑前调用）：归属客户非本人且未授权 → 404（不透出存在性）。
     */
    private void requireVisible(Client m) {
        var scope = ownerVisibility.evaluate("client", "client:view:all");
        if (scope.seeAll() || m.getOwnerEmployeeId() == null) return;
        if (!scope.visibleOwners().contains(m.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
    }

    @Transactional(readOnly = true)
    public ClientDetail detail(UUID id) {
        Client m = requireClient(id);
        requireVisible(m);
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('client:create')")
    @Transactional
    public ClientDetail create(ClientSaveRequest req) {
        tx.bind();
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
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('client:edit', 'client:status')")
    @Transactional
    public ClientDetail update(UUID id, ClientSaveRequest req) {
        tx.bind();
        com.uten.imp.security.CurrentAuthorityGuard.requireAll("client:edit");
        Client m = requireClient(id);
        requireVisible(m);
        // 乐观锁：编辑回传的版本与当前不符 → 409（记录已被他人修改）。null 放行（兼容旧客户端）。
        OptimisticLocks.requireUpToDate(m.getVersion(), req.getVersion());
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
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('client:status')")
    @Transactional
    public ClientDetail changeStatus(
            UUID id, com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        tx.bind();
        Client m = requireClient(id);
        requireVisible(m);
        em.refresh(m, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        OptimisticLocks.requireUpToDate(m.getVersion(), req.version());
        m.setStatus(req.status());
        repo.save(m);
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('client:delete')")
    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Client m = requireClient(id);
        requireVisible(m);
        m.setDeleted(true);
        m.setDeletedAt(OffsetDateTime.now());
        repo.save(m);
    }

    private void apply(ClientSaveRequest req, Client m) {
        m.setCategory(requireCategory(req.getCategoryId()));
        m.setName(req.getName());
        m.setFullName(req.getFullName());
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
        m.setBank(req.getBank());
        m.setBankAccount(req.getBankAccount());
        m.setTaxId(req.getTaxId());
        m.setCredit(req.getCredit());
        m.setInitTotal(req.getInitTotal());
        m.setTday(req.getTday());
        applyDefaultSettlementMethod(req, m);
        m.setCreditFloor(req.getCreditFloor());
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
        UUID categoryId = m.getCategory() == null ? null : m.getCategory().getId();
        String categoryName = m.getCategory() == null ? null : m.getCategory().getName();
        String settlementMethodName = m.getDefaultSettlementMethodId() == null
                ? null
                : settlementMethodNames(List.of(m)).get(m.getDefaultSettlementMethodId());
        return new ClientDetail(
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
                settlementMethodName);
    }

    private ClientListItem toList(Client m, String settlementMethodName) {
        return new ClientListItem(
                m.getId(), m.getCode(), m.getName(), m.getFullName(), m.getClientXz(),
                m.getTday(), m.getRegion(), m.getPlaceId(), m.getEmpId(), m.getLegalPerson(),
                m.getLinkman(), m.getMobile(), m.getPhone(), m.getPhone2(), m.getFax(),
                m.getPostcode(), m.getAddress(), m.getBank(), m.getBankAccount(), m.getTaxId(),
                m.getCredit(), m.getWebsite(), m.getStatus(), m.getLegacyId(),
                m.getCategory() == null ? null : m.getCategory().getId(),
                m.getDefaultSettlementMethodId(), settlementMethodName);
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
            client.setOwnerEmployeeId(null);
            client.setEmpId(null);
            return;
        }
        var employee = employeeRepo.findById(id)
                .filter(e -> !e.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "业务员不存在"));
        client.setOwnerEmployeeId(employee.getId());
        client.setEmpId(employee.getLegacyId() == null ? null : employee.getLegacyId().toString());
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

    private Client requireClient(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "客户不存在"));
    }
}
