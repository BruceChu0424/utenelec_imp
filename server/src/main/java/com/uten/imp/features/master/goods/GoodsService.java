package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 货品主档：分类下分页列表 + 详情 + 新建/编辑/删除（goods:edit）。
 *
 * <p>price 在 entity 是 Double（DOUBLE PRECISION 列），DTO 用 BigDecimal 便于前端精度展示，
 * apply/toDetail 做双向转换。
 */
@Service
@RequiredArgsConstructor
public class GoodsService {

    private final GoodsRepository repo;
    private final MaterialCategoryRepository categoryRepo;
    private final TxSessionVars tx;

    /**
     * 分类下货品分页（categoryId 为 null 时返回全部未软删货品）。
     * 对外页码从 1 起（Pageables.of 内部转 0-based）。
     */
    @Transactional(readOnly = true)
    public PageResponse<GoodsListItem> list(UUID categoryId, int page, int size) {
        Pageable pageable = Pageables.of(page, size);
        Page<Goods> p = (categoryId == null)
                ? repo.findByDeletedFalseOrderById(pageable)
                : repo.findByCategoryIdAndDeletedFalseOrderById(categoryId, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(),
                page,
                size,
                p.getTotalElements(),
                p.getTotalPages());
    }

    /** 货品详情（含 category_id/category_name）。open-in-view=false，LAZY category 需在本事务内取。 */
    @Transactional(readOnly = true)
    public GoodsDetail detail(UUID id) {
        return toDetail(requireGoods(id));
    }

    @Transactional
    public GoodsDetail create(GoodsSaveRequest req) {
        tx.bind();
        Goods g = new Goods();
        apply(req, g);
        repo.save(g);
        return toDetail(g);
    }

    @Transactional
    public GoodsDetail update(UUID id, GoodsSaveRequest req) {
        tx.bind();
        Goods g = requireGoods(id);
        apply(req, g);
        repo.save(g);
        return toDetail(g);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Goods g = requireGoods(id);
        g.setDeleted(true);
        g.setDeletedAt(OffsetDateTime.now());
        repo.save(g);
    }

    /** 把请求字段覆写到实体（含 category 解析；BigDecimal price → Double）。 */
    private void apply(GoodsSaveRequest req, Goods g) {
        g.setCategory(requireCategory(req.getCategoryId()));
        g.setName(req.getName());
        g.setCode(req.getCode());
        g.setShortName(req.getShortName());
        g.setModel(req.getModel());
        g.setSpec(req.getSpec());
        g.setPrice(req.getPrice() == null ? null : req.getPrice().doubleValue());
        g.setMaterial(req.getMaterial());
        g.setThickness(req.getThickness());
        g.setMWeight(req.getMWeight());
        g.setPack(req.getPack());
        g.setPieces(req.getPieces());
        g.setStatus(req.getStatus());
    }

    private GoodsDetail toDetail(Goods g) {
        UUID categoryId = g.getCategory() == null ? null : g.getCategory().getId();
        String categoryName = g.getCategory() == null ? null : g.getCategory().getName();
        return new GoodsDetail(
                g.getId(), g.getCode(), g.getName(), g.getSpec(), g.getModel(),
                toPrice(g.getPrice()), g.getStatus(), g.getLegacyId(),
                g.getShortName(), categoryId, categoryName, g.getPack(),
                g.getMaterial(), g.getThickness(), g.getUnitLegacyId(),
                g.getMWeight(), g.getPieces());
    }

    private GoodsListItem toList(Goods g) {
        return new GoodsListItem(
                g.getId(), g.getCode(), g.getName(), g.getSpec(), g.getModel(),
                toPrice(g.getPrice()), g.getStatus(), g.getLegacyId());
    }

    /** 实体 price 为 Double（DOUBLE PRECISION 列），DTO 统一 BigDecimal 便于前端精度展示。 */
    private static BigDecimal toPrice(Double p) {
        return p == null ? null : BigDecimal.valueOf(p);
    }

    private MaterialCategory requireCategory(UUID id) {
        return categoryRepo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "货品分类不存在"));
    }

    private Goods requireGoods(UUID id) {
        return repo.findById(id)
                .filter(g -> !g.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "货品不存在"));
    }
}
