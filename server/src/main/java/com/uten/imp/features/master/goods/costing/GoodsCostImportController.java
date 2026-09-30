package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.files.document.BoundedBodyReader;
import com.uten.imp.common.files.document.DocumentKind;
import com.uten.imp.common.files.document.DocumentSniffer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;
import java.io.IOException;
import java.util.UUID;
import static com.uten.imp.features.master.goods.costing.GoodsCostImportContracts.*;

@RestController
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('goods:cost:view') and hasAuthority('goods:cost:edit')")
public class GoodsCostImportController {
    private final GoodsCostImportService service;
    @PostMapping(value = "/api/master/goods/cost-sheets/import-preview", consumes = "multipart/form-data")
    public Preview preview(@RequestParam UUID goodsId, @RequestParam("file") MultipartFile file) throws IOException {
        byte[] bytes;
        try (var stream = file.getInputStream()) { bytes = BoundedBodyReader.read(stream, file.getSize(), 15L * 1024 * 1024); }
        if (DocumentSniffer.sniff(bytes, file.getOriginalFilename()) != DocumentKind.XLSX)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "成本导入支持未加密的 .xlsx 文件");
        return service.preview(goodsId, file.getOriginalFilename(), bytes);
    }
    @PostMapping("/api/master/goods/cost-sheets/import-apply")
    public Applied apply(@RequestBody Apply request) { return service.apply(request); }
}
