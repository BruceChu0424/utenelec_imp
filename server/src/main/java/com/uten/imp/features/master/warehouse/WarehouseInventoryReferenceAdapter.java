package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.WarehouseInventoryReferencePort;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

@Component
public class WarehouseInventoryReferenceAdapter implements WarehouseInventoryReferencePort {
    private final WarehouseService warehouses;
    private final WarehouseKeeperService keepers;

    public WarehouseInventoryReferenceAdapter(WarehouseService warehouses, WarehouseKeeperService keepers) {
        this.warehouses = warehouses;
        this.keepers = keepers;
    }

    @Override @Transactional(readOnly = true)
    public List<WarehouseReference> warehouses() {
        return warehouses.dict().stream().map(w -> new WarehouseReference(w.getId(), w.getCode(),
                w.getName(), w.getParentId(), w.isAccountable(), w.isLineSide())).toList();
    }

    @Override @Transactional(readOnly = true)
    public Set<UUID> assignedWarehouseRoots() {
        return keepers.myScope().keeperWarehouses().stream().map(w -> w.id()).collect(Collectors.toUnmodifiableSet());
    }
}
