package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientListItem;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
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
 * 客户主档：分类下分页列表（子树汇总）+ 详情 + 新建/编辑/删除（client:edit）。
 *
 * <p>list 按 categoryId 查**子树全部**分类的客户——客户主档会直接挂在有子分类
 * 的分组节点上（如「外贸(钟)」既有子分类又直接挂 17 个客户），子树汇总才能一次看全。
 */
@Service
@RequiredArgsConstructor
public class ClientService {

    private final ClientRepository repo;
    private final ClientCategoryRepository categoryRepo;
    private final TxSessionVars tx;

    /**
     * 分类下客户分页（categoryId 为 null 时返回全部未软删客户）。
     * categoryId 非空时返回该分类及其所有后代分类下的客户（子树汇总）。
     */
    @Transactional(readOnly = true)
    public PageResponse<ClientListItem> list(UUID categoryId, int page, int size) {
        Pageable pageable = Pageables.of(page, size);
        Page<Client> p;
        if (categoryId == null) {
            p = repo.findByDeletedFalseOrderById(pageable);
        } else {
            List<UUID> subtreeIds = categoryRepo.findSubtree(categoryId).stream()
                    .map(ClientCategory::getId)
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

    /** 客户详情（含 category_id/category_name）。open-in-view=false，LAZY category 需在本事务内取。 */
    @Transactional(readOnly = true)
    public ClientDetail detail(UUID id) {
        return toDetail(requireClient(id));
    }

    @Transactional
    public ClientDetail create(ClientSaveRequest req) {
        tx.bind();
        Client m = new Client();
        apply(req, m);
        repo.save(m);
        return toDetail(m);
    }

    @Transactional
    public ClientDetail update(UUID id, ClientSaveRequest req) {
        tx.bind();
        Client m = requireClient(id);
        apply(req, m);
        repo.save(m);
        return toDetail(m);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Client m = requireClient(id);
        m.setDeleted(true);
        m.setDeletedAt(OffsetDateTime.now());
        repo.save(m);
    }

    private void apply(ClientSaveRequest req, Client m) {
        m.setCategory(requireCategory(req.getCategoryId()));
        m.setName(req.getName());
        m.setCode(req.getCode());
        m.setFullName(req.getFullName());
        m.setClientRank(req.getClientRank());
        m.setRegion(req.getRegion());
        m.setPlaceId(req.getPlaceId());
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
        m.setCredit(req.getCredit());
        m.setInitTotal(req.getInitTotal());
        m.setTday(req.getTday());
        m.setStatus(req.getStatus());
        m.setRemark(req.getRemark());
    }

    private ClientDetail toDetail(Client m) {
        UUID categoryId = m.getCategory() == null ? null : m.getCategory().getId();
        String categoryName = m.getCategory() == null ? null : m.getCategory().getName();
        return new ClientDetail(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getRegion(),
                m.getLinkman(), m.getLegacyId(),
                categoryId, categoryName, m.getFullName(), m.getClientRank(),
                m.getPlaceId(), m.getEmpId(), m.getLegalPerson(), m.getMobile(),
                m.getPhone(), m.getPhone2(), m.getFax(), m.getPostcode(), m.getAddress(),
                m.getEmail(), m.getWebsite(), m.getShipVia(), m.getShipAddress(),
                m.getBank(), m.getBankAccount(), m.getTaxId(), m.getCredit(),
                m.getInitTotal(), m.getTday(), m.getRemark());
    }

    private ClientListItem toList(Client m) {
        return new ClientListItem(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getRegion(),
                m.getLinkman(), m.getLegacyId());
    }

    private ClientCategory requireCategory(UUID id) {
        return categoryRepo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "客户分类不存在"));
    }

    private Client requireClient(UUID id) {
        return repo.findById(id)
                .filter(m -> !m.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "客户不存在"));
    }
}
