package com.uten.imp.features.master.mould;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.mould.dto.MouldDetail;
import com.uten.imp.features.master.mould.dto.MouldListItem;
import com.uten.imp.features.master.mould.dto.MouldSaveRequest;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.mouldcategory.MouldCategoryRepository;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 模具主档：分类下分页列表 + 详情 + 新建/编辑/删除（mould:edit）。
 *
 * <p>读路径仿旧版（PageResponse/Pageable）；写路径仿 {@code MouldCategoryService}：
 * tx.bind 绑审计 actor → repo.save → 软删置 deleted/deletedAt。
 */
@Service
@RequiredArgsConstructor
public class MouldService {

    private final MouldRepository repo;
    private final MouldCategoryRepository categoryRepo;
    private final TxSessionVars tx;

    /**
     * 分类下模具分页（categoryId 为 null 时返回全部未软删模具）。
     * 对外页码从 1 起（Pageables.of 内部转 0-based）。
     */
    @Transactional(readOnly = true)
    public PageResponse<MouldListItem> list(UUID categoryId, int page, int size) {
        Pageable pageable = Pageables.of(page, size);
        Page<Mould> p = (categoryId == null)
                ? repo.findByDeletedFalseOrderById(pageable)
                : repo.findByCategoryIdAndDeletedFalseOrderById(categoryId, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(),
                page,
                size,
                p.getTotalElements(),
                p.getTotalPages());
    }

    /** 模具详情（含 category_id/category_name）。open-in-view=false，LAZY category 需在本事务内取。 */
    @Transactional(readOnly = true)
    public MouldDetail detail(UUID id) {
        return toDetail(requireMould(id));
    }

    @Transactional
    public MouldDetail create(MouldSaveRequest req) {
        tx.bind();
        Mould m = new Mould();
        apply(req, m);
        repo.save(m);
        return toDetail(m);
    }

    @Transactional
    public MouldDetail update(UUID id, MouldSaveRequest req) {
        tx.bind();
        Mould m = requireMould(id);
        apply(req, m);
        repo.save(m);
        return toDetail(m);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Mould m = requireMould(id);
        m.setDeleted(true);
        m.setDeletedAt(OffsetDateTime.now());
        repo.save(m);
    }

    /** 把请求字段覆写到实体（含 category 解析）。 */
    private void apply(MouldSaveRequest req, Mould m) {
        m.setCategory(requireCategory(req.getCategoryId()));
        m.setName(req.getName());
        m.setCode(req.getCode());
        m.setMnumber(req.getMnumber());
        m.setQty(req.getQty());
        m.setTqty(req.getTqty());
        m.setMstatus(req.getMstatus());
        m.setStatus(req.getStatus());
        m.setPlace(req.getPlace());
        m.setKeeper(req.getKeeper());
        m.setRemark(req.getRemark());
    }

    private MouldDetail toDetail(Mould m) {
        UUID categoryId = m.getCategory() == null ? null : m.getCategory().getId();
        String categoryName = m.getCategory() == null ? null : m.getCategory().getName();
        return new MouldDetail(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getPlace(),
                m.getKeeper(), m.getLegacyId(),
                categoryId, categoryName, m.getMnumber(), m.getQty(), m.getTqty(),
                m.getMstatus(), m.getRemark());
    }

    private MouldListItem toList(Mould m) {
        return new MouldListItem(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getPlace(),
                m.getKeeper(), m.getLegacyId());
    }

    private MouldCategory requireCategory(UUID id) {
        return categoryRepo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "模具分类不存在"));
    }

    private Mould requireMould(UUID id) {
        return repo.findById(id)
                .filter(m -> !m.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "模具不存在"));
    }
}
