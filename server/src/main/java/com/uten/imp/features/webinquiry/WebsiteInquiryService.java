package com.uten.imp.features.webinquiry;

import com.uten.imp.audit.AuditService;
import com.uten.imp.application.port.EmployeeNameLookupPort;
import com.uten.imp.application.port.WebsiteInquiryClientPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.webinquiry.dto.IngestRequest;
import com.uten.imp.features.webinquiry.dto.StatusUpdateRequest;
import com.uten.imp.features.webinquiry.dto.WebsiteInquiryDetail;
import com.uten.imp.features.webinquiry.dto.WebsiteInquiryListItem;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 官网询盘业务：接收（幂等）/ 查询 / 跟进状态机 / 一键转客户。
 *
 * <p>状态机：new → following → converted / closed；converted 仅由
 * {@link #convert(UUID)} 到达（必须已成功关联客户），不可手工选。
 */
@Service
@RequiredArgsConstructor
public class WebsiteInquiryService {

    private static final Set<String> STATUSES = Set.of("new", "following", "converted", "closed");

    private final WebsiteInquiryRepository repository;
    private final WebsiteInquiryClientPort clientPort;
    private final EmployeeNameLookupPort employeeNames;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;

    /** 官网推送落库；sourceId 已存在时幂等返回 false（不重复建行、不报错）。 */
    @Transactional
    public boolean ingest(IngestRequest request) {
        if (repository.findBySourceId(request.sourceId()).isPresent()) {
            return false;
        }
        WebsiteInquiry inquiry = new WebsiteInquiry();
        inquiry.setSourceId(request.sourceId());
        inquiry.setName(request.name());
        inquiry.setPhone(request.phone());
        inquiry.setEmail(request.email());
        inquiry.setCompany(request.company());
        inquiry.setMarket(request.market());
        inquiry.setCustomerType(request.customerType());
        inquiry.setRequiredStandard(request.requiredStandard());
        inquiry.setProductInterest(request.productInterest());
        inquiry.setRequestType(request.requestType());
        inquiry.setEstimatedQuantity(request.estimatedQuantity());
        inquiry.setTargetSchedule(request.targetSchedule());
        inquiry.setPreferredContact(request.preferredContact());
        inquiry.setMessage(request.message());
        inquiry.setSource(request.source() == null || request.source().isBlank() ? "contact" : request.source());
        inquiry.setLocale(request.locale() == null || request.locale().isBlank() ? "zh" : request.locale());
        repository.save(inquiry);
        return true;
    }

    @Transactional(readOnly = true)
    public PageResponse<WebsiteInquiryListItem> list(String status, String keyword, int page, int size) {
        if (status != null && !status.isBlank() && !STATUSES.contains(status)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知状态: " + status);
        }
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 100);
        Page<WebsiteInquiry> result = repository.search(
                status == null || status.isBlank() ? null : status,
                keyword == null ? "" : keyword.trim(),
                PageRequest.of(safePage - 1, safeSize, Sort.by(Sort.Direction.DESC, "receivedAt")));
        Map<UUID, String> names = assigneeNames(result.getContent());
        return new PageResponse<>(
                result.getContent().stream().map(item -> toListItem(item, names)).toList(),
                safePage, safeSize, result.getTotalElements(), result.getTotalPages());
    }

    @Transactional(readOnly = true)
    public WebsiteInquiryDetail detail(UUID id) {
        return toDetail(require(id));
    }

    /** 跟进状态推进；assignToMe=true 时把当前登录员工记为跟进人。 */
    @PreAuthorize("hasAuthority(#request.requiredPermission()) and (#request.assignToMe() != true or hasAuthority('webinquiry:claim'))")
    @Transactional
    public WebsiteInquiryDetail updateStatus(UUID id, StatusUpdateRequest request) {
        WebsiteInquiry inquiry = require(id);
        if ("converted".equals(inquiry.getStatus())) {
            throw new ApiException(ErrorCode.CONFLICT, "已转客户的询盘不能再改状态");
        }
        inquiry.setStatus(request.status());
        if (request.note() != null && !request.note().isBlank()) {
            inquiry.setNote(request.note().trim());
        }
        if (Boolean.TRUE.equals(request.assignToMe())) {
            inquiry.setAssigneeEmployeeId(currentUser.requireEmployeeId());
        }
        repository.save(inquiry);
        audit.logCommitted(currentUser.requireId(), currentAccount(),
                "webinquiry_status", "website_inquiry",
                "询价=" + inquiry.getId() + "；状态已更新", "success");
        return toDetail(inquiry);
    }

    /**
     * 一键转客户：按询盘快照创建最小客户主档（名称=公司或联系人），
     * 归属当前操作员工，备注留溯源；随后状态置 converted 并关联。
     */
    @PreAuthorize("hasAuthority('webinquiry:convert_client')")
    @Transactional
    public WebsiteInquiryDetail convert(UUID id) {
        WebsiteInquiry inquiry = require(id);
        if ("converted".equals(inquiry.getStatus()) && inquiry.getClientId() != null) {
            return toDetail(inquiry); // 幂等：重复点击直接回详情
        }
        String company = inquiry.getCompany() == null ? "" : inquiry.getCompany().trim();
        WebsiteInquiryClientPort.CreatedClient client = clientPort.createFromInquiry(
                new WebsiteInquiryClientPort.CreateRequest(
                        company.isEmpty() ? inquiry.getName() : company,
                        inquiry.getName(), inquiry.getPhone(), inquiry.getEmail(), inquiry.getMarket(),
                        currentUser.requireEmployeeId(), inquiry.getSourceId()));

        inquiry.setClientId(client.id());
        inquiry.setStatus("converted");
        if (inquiry.getAssigneeEmployeeId() == null) {
            inquiry.setAssigneeEmployeeId(currentUser.employeeId().orElse(null));
        }
        repository.save(inquiry);
        audit.logCommitted(currentUser.requireId(), currentAccount(),
                "webinquiry_convert", "website_inquiry",
                "询价=" + inquiry.getId() + "；客户=" + client.id(), "success");
        return toDetail(inquiry);
    }

    @Transactional(readOnly = true)
    public long countNew() {
        return repository.countByStatus("new");
    }

    private WebsiteInquiry require(UUID id) {
        return repository.findById(id).orElseThrow(
                () -> new ApiException(ErrorCode.NOT_FOUND, "询盘不存在"));
    }

    private String currentAccount() {
        return currentUser.get().map(user -> user.getLoginAccount()).orElse("unknown");
    }

    private Map<UUID, String> assigneeNames(java.util.List<WebsiteInquiry> items) {
        Set<UUID> ids = items.stream()
                .map(WebsiteInquiry::getAssigneeEmployeeId)
                .filter(java.util.Objects::nonNull)
                .collect(java.util.stream.Collectors.toSet());
        if (ids.isEmpty()) return Map.of();
        return employeeNames.findNames(ids);
    }

    private WebsiteInquiryListItem toListItem(WebsiteInquiry item, Map<UUID, String> names) {
        return new WebsiteInquiryListItem(
                item.getId(), item.getName(), item.getCompany(), item.getPhone(), item.getEmail(),
                item.getMarket(), item.getCustomerType(), item.getProductInterest(), item.getRequestType(),
                item.getSource(), item.getLocale(), item.getStatus(),
                item.getAssigneeEmployeeId(),
                item.getAssigneeEmployeeId() == null ? null : names.get(item.getAssigneeEmployeeId()),
                item.getClientId(),
                item.getReceivedAt());
    }

    private WebsiteInquiryDetail toDetail(WebsiteInquiry item) {
        String assigneeName = item.getAssigneeEmployeeId() == null ? null
                : employeeNames.findName(item.getAssigneeEmployeeId()).orElse(null);
        String clientName = item.getClientId() == null ? null
                : clientPort.findName(item.getClientId()).orElse(null);
        return new WebsiteInquiryDetail(
                item.getId(), item.getSourceId(), item.getName(), item.getPhone(), item.getEmail(),
                item.getCompany(), item.getMarket(), item.getCustomerType(), item.getRequiredStandard(),
                item.getProductInterest(), item.getRequestType(), item.getEstimatedQuantity(),
                item.getTargetSchedule(), item.getPreferredContact(), item.getMessage(),
                item.getSource(), item.getLocale(), item.getStatus(),
                item.getAssigneeEmployeeId(), assigneeName,
                item.getClientId(), clientName,
                item.getNote(), item.getReceivedAt());
    }
}
