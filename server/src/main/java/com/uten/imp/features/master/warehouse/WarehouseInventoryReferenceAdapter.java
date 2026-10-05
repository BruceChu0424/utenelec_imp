package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.WarehouseInventoryReferencePort;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Component
public class WarehouseInventoryReferenceAdapter implements WarehouseInventoryReferencePort {
    private final WarehouseService warehouses;

    public WarehouseInventoryReferenceAdapter(WarehouseService warehouses) {
        this.warehouses = warehouses;
    }

    @Override @Transactional(readOnly = true)
    public List<WarehouseReference> warehouses() {
        return warehouses.dict().stream().map(w -> new WarehouseReference(w.getId(), w.getCode(),
                w.getName(), w.getParentId(), w.isAccountable(), w.isLineSide(), w.isDefective())).toList();
    }

}
