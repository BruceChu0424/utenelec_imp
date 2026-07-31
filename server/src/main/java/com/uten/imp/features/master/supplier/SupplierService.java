package com.uten.imp.features.master.supplier;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.util.NativeQueryResults;
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

import java.time.OffsetDateTime;
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

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.SUPPLIER;

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of(
            "name", "description", "tday", "place", "empId", "legalPerson", "linkman",
            "mobile", "phone", "phone2", "fax", "postcode", "address", "bank",
            "bankAccount", "taxId", "website", "shipVia", "shipAddress");

    /** 列排序白名单：前端列 key → JPA 实体属性名（数量列；命中才排序，否则默认 id ASC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("tday", "tday");

    /** facet 截断阈值（高基数列如 name/address 取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /** facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。 */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("description", "description");
        FACET_COLUMNS.put("tday", "tday");
        FACET_COLUMNS.put("place", "place");
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
        FACET_COLUMNS.put("website", "website");
        FACET_COLUMNS.put("shipVia", "ship_via");
        FACET_COLUMNS.put("shipAddress", "ship_address");
    }

    private final SupplierRepository repo;
    private final SupplierCategoryRepository categoryRepo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final MasterCodeService masterCodeService;

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<SupplierListItem> list(SupplierQueryFilter f, int page, int size, String sort, String order) {
        List<UUID> subtreeIds = (f.categoryId() == null) ? null : resolveSubtreeIds(f.categoryId());
        Specification<Supplier> spec = (Root<Supplier> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                        CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (subtreeIds != null) {
                ps.add(root.get("category").get("id").in(subtreeIds));
            }
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("name")), like),
                        cb.like(cb.lower(root.get("description")), like),
                        cb.like(cb.lower(root.get("linkman")), like),
                        cb.like(cb.lower(root.get("legalPerson")), like),
                        cb.like(cb.lower(root.get("place")), like),
                        cb.like(cb.lower(root.get("mobile")), like)));
            }
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "description", f.description());
            addEq(ps, cb, root, "place", f.place());
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
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.ASC, "id"), ALLOWED_SORT));
        Page<Supplier> p = repo.findAll(spec, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
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
     * 加密 Excel 导出：循环 list 分页累积全部行（size=100），硬上限 1000 页=10万行防 OOM。
     * 列定义服务端权威；过滤/排序走 list 已接的 TableSort 白名单（tday）。
     * 覆盖前端表格 21 列里 19 个有 DB 列的字段（主结账方式/损耗率无对应列，导出也省略）。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(SupplierQueryFilter f, String sort, String order) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("name", "供应商简称", ExportColumn.TEXT),
                new ExportColumn("description", "全称", ExportColumn.TEXT),
                new ExportColumn("tday", "信用天数", ExportColumn.NUMBER),
                new ExportColumn("place", "所属地区", ExportColumn.TEXT),
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
                new ExportColumn("website", "网址", ExportColumn.TEXT),
                new ExportColumn("shipVia", "运输方式", ExportColumn.TEXT),
                new ExportColumn("shipAddress", "送货地址", ExportColumn.TEXT));
        List<Map<String, Object>> rows = new ArrayList<>();
        int pageSize = 100;
        int maxPages = 1000;
        long total = -1;
        for (int p = 1; p <= maxPages; p++) {
            PageResponse<SupplierListItem> page = list(f, p, pageSize, sort, order);
            if (total < 0) total = page.getTotal();
            for (SupplierListItem m : page.getItems()) {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("name", m.getName());
                row.put("description", m.getDescription());
                row.put("tday", m.getTday());
                row.put("place", m.getPlace());
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
                row.put("website", m.getWebsite());
                row.put("shipVia", m.getShipVia());
                row.put("shipAddress", m.getShipAddress());
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
    public SupplierFacets facets(UUID categoryId) {
        if (categoryId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "categoryId 必填");
        }
        List<UUID> ids = resolveSubtreeIds(categoryId);
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from suppliers "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .setParameter("ids", ids));
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from suppliers "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is null")
                    .setParameter("ids", ids)
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
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

    // ===== 详情 / CRUD（不变） =====

    /** 全量字典（采购单据页按 id 解析供应商名用）：全部未软删供应商，按名称排序。 */
    @Transactional(readOnly = true)
    public List<SupplierDictItem> dict() {
        // 排除内部车间（V100）：车间=部门，不再作为委外商可选
        Specification<Supplier> spec = (root, q, cb) -> cb.and(
                cb.isFalse(root.get("deleted")),
                cb.isFalse(root.get("internalWorkshop")));
        return repo.findAll(spec, Sort.by(Sort.Direction.ASC, "name")).stream()
                .map(m -> new SupplierDictItem(m.getId(), m.getCode(), m.getName()))
                .toList();
    }

    @Transactional(readOnly = true)
    public SupplierDetail detail(UUID id) {
        return toDetail(requireSupplier(id));
    }

    @Transactional
    public SupplierDetail create(SupplierSaveRequest req) {
        tx.bind();
        Supplier m = new Supplier();
        apply(req, m);
        m.setCode(masterCodeService.nextCode(CODE_PREFIX));
        if (m.getStatus() == null) m.setStatus("使用");
        repo.save(m);
        return toDetail(m);
    }

    @Transactional
    public SupplierDetail update(UUID id, SupplierSaveRequest req) {
        tx.bind();
        Supplier m = requireSupplier(id);
        apply(req, m);
        repo.save(m);
        return toDetail(m);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Supplier m = requireSupplier(id);
        m.setDeleted(true);
        m.setDeletedAt(OffsetDateTime.now());
        repo.save(m);
    }

    private void apply(SupplierSaveRequest req, Supplier m) {
        m.setCategory(requireCategory(req.getCategoryId()));
        m.setName(req.getName());
        m.setDescription(req.getDescription());
        m.setPlace(req.getPlace());
        m.setEmpId(req.getEmpId());
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
        m.setStatus(req.getStatus());
        m.setRemark(req.getRemark());
    }

    private SupplierDetail toDetail(Supplier m) {
        UUID categoryId = m.getCategory() == null ? null : m.getCategory().getId();
        String categoryName = m.getCategory() == null ? null : m.getCategory().getName();
        return new SupplierDetail(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getPlace(),
                m.getLinkman(), m.getLegacyId(),
                categoryId, categoryName, m.getDescription(), m.getEmpId(), m.getLegalPerson(),
                m.getMobile(), m.getPhone(), m.getPhone2(), m.getFax(), m.getPostcode(),
                m.getAddress(), m.getEmail(), m.getWebsite(), m.getShipVia(), m.getShipAddress(),
                m.getBank(), m.getBankAccount(), m.getTaxId(), m.getInitTotal(), m.getTday(),
                m.getRemark());
    }

    private SupplierListItem toList(Supplier m) {
        return new SupplierListItem(
                m.getId(), m.getLegacyId(),
                m.getName(), m.getDescription(), m.getTday(), m.getPlace(),
                m.getEmpId(), m.getLegalPerson(), m.getLinkman(), m.getMobile(),
                m.getPhone(), m.getPhone2(), m.getFax(), m.getPostcode(), m.getAddress(),
                m.getBank(), m.getBankAccount(), m.getTaxId(), m.getWebsite(),
                m.getShipVia(), m.getShipAddress(),
                m.getCategory() == null ? null : m.getCategory().getId());
    }

    private SupplierCategory requireCategory(UUID id) {
        return categoryRepo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "供应商分类不存在"));
    }

    private Supplier requireSupplier(UUID id) {
        return repo.findById(id)
                .filter(m -> !m.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "供应商不存在"));
    }
}
