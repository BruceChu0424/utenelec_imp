package com.uten.imp.features.master.currency;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.master.currency.dto.CurrencyDetail;
import com.uten.imp.features.master.currency.dto.CurrencyFacets;
import com.uten.imp.features.master.currency.dto.CurrencyListItem;
import com.uten.imp.features.master.currency.dto.CurrencyQueryFilter;
import com.uten.imp.features.master.currency.dto.CurrencySaveRequest;
import com.uten.imp.features.master.currency.dto.FacetBucket;
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
 * 币种主档：扁平列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（currency:edit）。
 *
 * <p>范式同 {@code ColorService}，加 {@code exchange_rate} 数字字段（不进 facet，仅列表/详情/保存）。
 * 币种供采购订货/收货/退货单据选择（有美金/港币进出口采购）。
 *
 * <p>列表用 {@link Specification}：keyword 多字段 OR + 字段精确等值 + {@code nullFields} 空值白名单。
 * facets 用原生 SQL 聚合（字段→列名硬编码白名单，防注入；列名非用户输入）。
 */
@Service
@RequiredArgsConstructor
public class CurrencyService {

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.CURRENCY;

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of("code", "name", "status");

    /** 列排序白名单：前端列 key → JPA 实体属性名（数值列；命中才排序，否则默认 code ASC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("exchangeRate", "exchangeRate");

    /** facet 截断阈值。 */
    private static final int FACET_LIMIT = 50;

    /** facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。 */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("code", "code");
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("status", "status");
    }

    private final CurrencyRepository repo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final MasterCodeService masterCodeService;

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<CurrencyListItem> list(CurrencyQueryFilter f, int page, int size, String sort, String order) {
        Specification<Currency> spec = (Root<Currency> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                        CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("name")), like),
                        cb.like(cb.lower(root.get("code")), like)));
            }
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "status", f.status());
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.ASC, "code"), ALLOWED_SORT));
        Page<Currency> p = repo.findAll(spec, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Currency> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    // ===== 加密 Excel 导出（服务端权威列定义） =====

    /**
     * 加密 Excel 导出：循环 list 分页累积全部行（size=100），硬上限 1000 页=10万行防 OOM。
     * 列定义服务端权威；过滤/排序走 list 已接的 TableSort 白名单（exchangeRate）。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(CurrencyQueryFilter f, String sort, String order) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("code", "编号", ExportColumn.TEXT),
                new ExportColumn("name", "币种名称", ExportColumn.TEXT),
                new ExportColumn("exchangeRate", "参考汇率", ExportColumn.NUMBER),
                new ExportColumn("status", "状态", ExportColumn.TEXT));
        List<Map<String, Object>> rows = new ArrayList<>();
        int pageSize = 100;
        int maxPages = 1000;
        long total = -1;
        for (int p = 1; p <= maxPages; p++) {
            PageResponse<CurrencyListItem> page = list(f, p, pageSize, sort, order);
            if (total < 0) total = page.getTotal();
            for (CurrencyListItem c : page.getItems()) {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("code", c.getCode());
                row.put("name", c.getName());
                row.put("exchangeRate", c.getExchangeRate());
                row.put("status", c.getStatus());
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

    // ===== facets（各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public CurrencyFacets facets() {
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            String col = e.getValue();   // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL
            List<Object[]> rows = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from currencies "
                            + "where is_deleted = false and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .getResultList();
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from currencies where is_deleted = false and " + col + " is null")
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new CurrencyFacets(buckets.get("code"), buckets.get("name"), buckets.get("status"), nullCounts);
    }

    // ===== 详情 / CRUD =====

    /** 全量字典（采购单据选币种用）：返回全部未软删币种，按编号排序。 */
    @Transactional(readOnly = true)
    public List<CurrencyListItem> dict() {
        Specification<Currency> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        return repo.findAll(spec, Sort.by(Sort.Direction.ASC, "code")).stream()
                .map(this::toList).toList();
    }

    @Transactional(readOnly = true)
    public CurrencyDetail detail(UUID id) {
        return toDetail(requireCurrency(id));
    }

    @Transactional
    public CurrencyDetail create(CurrencySaveRequest req) {
        tx.bind();
        Currency c = new Currency();
        apply(req, c);
        c.setCode(masterCodeService.nextCode(CODE_PREFIX));
        if (c.getStatus() == null) c.setStatus("使用");
        repo.save(c);
        return toDetail(c);
    }

    @Transactional
    public CurrencyDetail update(UUID id, CurrencySaveRequest req) {
        tx.bind();
        Currency c = requireCurrency(id);
        apply(req, c);
        repo.save(c);
        return toDetail(c);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Currency c = requireCurrency(id);
        c.setDeleted(true);
        c.setDeletedAt(OffsetDateTime.now());
        repo.save(c);
    }

    private void apply(CurrencySaveRequest req, Currency c) {
        c.setName(req.getName());
        c.setExchangeRate(req.getExchangeRate());
        c.setStatus(req.getStatus());
    }

    private CurrencyDetail toDetail(Currency c) {
        return new CurrencyDetail(c.getId(), c.getCode(), c.getName(), c.getExchangeRate(),
                c.getStatus(), c.getLegacyId());
    }

    private CurrencyListItem toList(Currency c) {
        return new CurrencyListItem(c.getId(), c.getCode(), c.getName(), c.getExchangeRate(),
                c.getStatus(), c.getLegacyId());
    }

    private Currency requireCurrency(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "币种不存在"));
    }
}
