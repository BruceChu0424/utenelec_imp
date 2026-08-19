package com.uten.imp.features.master.client;

import com.uten.imp.features.master.client.dto.ClientShipAddressDto;
import com.uten.imp.features.master.client.dto.ClientShipAddressSaveRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * 客户收货地址簿 API（V300 出货开单学习能力）。
 *
 * <ul>
 *   <li>GET    /api/master/clients/{id}/ship-addresses               → 地址簿（最近使用优先）</li>
 *   <li>POST   /api/master/clients/{id}/ship-addresses               → 新增地址（重复=点选既有）</li>
 *   <li>DELETE /api/master/clients/{id}/ship-addresses/{addressId}   → 删除（client_address:delete）</li>
 * </ul>
 *
 * <p>出货/其它出货保存时的自动学习由
 * {@link ClientShipAddressService#learn} 在各单据服务同事务内调用，不开放独立端点。
 */
@RestController
@RequestMapping("/api/master/clients")
@RequiredArgsConstructor
public class ClientShipAddressController {

    private final ClientShipAddressService service;

    @GetMapping("/{id}/ship-addresses")
    @PreAuthorize("hasAuthority('client:view')")
    public List<ClientShipAddressDto> list(@PathVariable UUID id) {
        return service.list(id);
    }

    @PostMapping("/{id}/ship-addresses")
    @PreAuthorize("hasAuthority('client:edit')"
            + " or hasAuthority('sales_shipment:edit')"
            + " or hasAuthority('sales_other_shipment:edit')")
    public ClientShipAddressDto add(@PathVariable UUID id,
                                    @Valid @RequestBody ClientShipAddressSaveRequest req) {
        return service.add(id, req);
    }

    @DeleteMapping("/{id}/ship-addresses/{addressId}")
    @PreAuthorize("hasAuthority('client_address:delete')")
    public void delete(@PathVariable UUID id, @PathVariable UUID addressId) {
        service.delete(id, addressId);
    }
}
