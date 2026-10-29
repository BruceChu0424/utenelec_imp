package com.uten.imp.features.clientupdates;

import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.StepUpExempt;
import jakarta.servlet.http.HttpServletRequest;
import java.io.IOException;
import java.util.List;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/admin/client-releases")
@PreAuthorize(ClientReleaseService.PUBLISH_EXPRESSION)
@RequiredArgsConstructor
public class ClientReleaseAdminController {
    private final ClientReleaseService service;

    @GetMapping
    public List<ClientReleaseDto.Release> list() { return service.list(); }

    /** Recovery metadata for one immutable queue identity. PUBLISHED alone does not
     * prove Windows retention succeeded: an uncertain publish must explicitly retry
     * the same ID/publish operation, never create or upload a replacement identity. */
    @GetMapping("/{id}")
    public ResponseEntity<ClientReleaseDto.Release> get(@PathVariable("id") UUID id) {
        return ResponseEntity.ok().header("Cache-Control", "private, no-store").body(service.get(id));
    }

    @PostMapping
    @StepUpExempt("只创建登录用户不可见的客户端版本草稿，不发布、不执行软件；最终发布另须密码再认证")
    @ResponseStatus(HttpStatus.CREATED)
    public ClientReleaseDto.Release create(@RequestBody ClientReleaseDto.Create request) { return service.create(request); }

    /** Raw streaming deliberately avoids multipart's small attachment limit and heap buffering. */
    @PutMapping(value = "/{id}/package", consumes = MediaType.APPLICATION_OCTET_STREAM_VALUE)
    @StepUpExempt("只向不可见草稿流式上传并校验软件包，不发布、不执行软件；最终发布另须密码再认证")
    public ClientReleaseDto.Release upload(@PathVariable("id") UUID id, HttpServletRequest request) throws IOException {
        return service.upload(id, request.getInputStream(), request.getContentLengthLong());
    }

    @PostMapping("/{id}/publish")
    @RequiresStepUp
    public ClientReleaseDto.Release publish(@PathVariable("id") UUID id) { return service.publish(id); }

    @PostMapping("/{id}/withdraw")
    @RequiresStepUp
    public ClientReleaseDto.Release withdraw(@PathVariable("id") UUID id) { return service.withdraw(id); }
}
