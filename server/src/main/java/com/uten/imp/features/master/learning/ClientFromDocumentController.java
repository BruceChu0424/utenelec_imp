package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 用客户文件上的买方信息新建客户(ADR-134, 识别面板「用文件信息新建客户」)。
 *
 * <p>{@code POST /api/master/clients/from-document}(client:create): 先在全部客户里查重,
 * 命中看得到的客户返回 409 且 fieldErrors 带 {@code existingClientId}; 命中看不到的客户返回 409
 * 不带任何名称或 id; 否则建在系统「未分类」下, 负责人为本人, 返回新客户 id、编号与名称。
 */
@RestController
@RequestMapping("/api/master/clients/from-document")
@RequiredArgsConstructor
public class ClientFromDocumentController {

    private final MasterIntakeLookupPort lookup;

    @PostMapping
    @PreAuthorize("hasAuthority('client:create')")
    public CreatedClientResponse create(@Valid @RequestBody Request request) {
        MasterIntakeLookupPort.CreatedClient created = lookup.createClientFromDocument(
                new MasterIntakeLookupPort.NewClientRequest(request.name(), request.fullName(), request.nameEn(),
                        request.linkman(), request.email(), request.phone(), request.address(), request.taxId(),
                        request.placeId()));
        return new CreatedClientResponse(created.clientId(), created.code(), created.name());
    }

    /** 请求体(识别结果 client.newClientProposal 经用户确认后提交)。长度上限与客户资料补全同口径。 */
    public record Request(
            @NotBlank @Size(max = 500) String name,
            @Size(max = 200) String fullName,
            @Size(max = 255) String nameEn,
            @Size(max = 100) String linkman,
            @Size(max = 200) String email,
            @Size(max = 64) String phone,
            @Size(max = 500) String address,
            @Size(max = 64) String taxId,
            @Size(max = 64) String placeId) {
    }

    /** 新建成功的客户。 */
    public record CreatedClientResponse(UUID clientId, String code, String name) {
    }
}
