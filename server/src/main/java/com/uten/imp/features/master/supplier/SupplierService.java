package com.uten.imp.features.master.supplier;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.supplier.dto.SupplierDetail;
import com.uten.imp.features.master.supplier.dto.SupplierListItem;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 供应商主档：分类下分页列表（子树汇总）+ 详情 + 新建/编辑/删除（supplier:edit）。
 * 与 {@code ClientService} 同构。
 */
@Service
@RequiredArgsConstructor
public class SupplierService {

    private final SupplierRepository repo;
    private final SupplierCategoryRepository categoryRepo;
    private final TxSessionVars tx;

    /**
     * 分类下供应商分页（categoryId 为 null 时返回全部未软删供应商）。
     * categoryId 非空时返回该分类及其所有后代分类下的供应商（子树汇总）。
     */
    @Transactional(readOnly = true)
    public PageResponse<SupplierListItem> list(UUID categoryId, int page, int size) {
        Pageable pageable = Pageables.of(page, size);
        Page<Supplier> p;
        if (categoryId == null) {
            p = repo.findByDeletedFalseOrderById(pageable);
        } else {
            List<UUID> subtreeIds = categoryRepo.findSubtree(categoryId).stream()
                    .map(SupplierCategory::getId)
                    .toList();
            p = repo.findByCategoryIdInAndDeletedFalseOrderById(subtreeIds, pageable);
        }
        return new PageResponse<>(
                p.map(this::toList).getContent(),
                page,
                size,
                p.getTotalElements(),
                p.getTotalPages());
    }

    /** 供应商详情（含 category_id/category_name）。open-in-view=false，LAZY category 需在本事务内取。 */
    @Transactional(readOnly = true)
    public SupplierDetail detail(UUID id) {
        return toDetail(requireSupplier(id));
    }

    @Transactional
    public SupplierDetail create(SupplierSaveRequest req) {
        tx.bind();
        Supplier m = new Supplier();
        apply(req, m);
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
        m.setCode(req.getCode());
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
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getPlace(),
                m.getLinkman(), m.getLegacyId());
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
