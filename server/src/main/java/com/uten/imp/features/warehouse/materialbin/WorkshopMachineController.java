package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerBatchUpdate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineBatchCreate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineBatchUpdate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineList;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** 车间机台与机台容器 (盘点按机台录料斗、储料桶)。 */
@RestController
@RequestMapping("/api/workshop-material")
public class WorkshopMachineController {

    private final WorkshopMachineService machines;

    public WorkshopMachineController(WorkshopMachineService machines) {
        this.machines = machines;
    }

    @GetMapping("/machines")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public MachineList list(@RequestParam UUID workshopId) {
        return machines.list(workshopId);
    }

    @PostMapping("/machines/batch")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public MachineList createBatch(@RequestBody MachineBatchCreate request) {
        return machines.createBatch(request);
    }

    @PutMapping("/machines/batch")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public MachineList updateBatch(@RequestBody MachineBatchUpdate request) {
        return machines.updateBatch(request);
    }

    @PutMapping("/containers/batch")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public MachineList updateContainers(@RequestBody ContainerBatchUpdate request) {
        return machines.updateContainers(request);
    }

    @DeleteMapping("/machines/{machineId}")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public ResponseEntity<Void> deleteMachine(@PathVariable UUID machineId, @RequestParam Long expectedVersion) {
        machines.deleteMachine(machineId, expectedVersion);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/containers/{containerId}")
    @PreAuthorize("hasAuthority('workshop_material:setup')")
    public ResponseEntity<Void> deleteContainer(@PathVariable UUID containerId, @RequestParam Long expectedVersion) {
        machines.deleteContainer(containerId, expectedVersion);
        return ResponseEntity.noContent().build();
    }
}
