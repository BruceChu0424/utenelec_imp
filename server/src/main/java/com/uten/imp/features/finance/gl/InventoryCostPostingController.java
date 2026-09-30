package com.uten.imp.features.finance.gl;

import com.uten.imp.application.port.InventoryCostPostingQueryPort;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/finance/gl/inventory-cost")
public class InventoryCostPostingController {
    private final InventoryCostPostingService service;
    public InventoryCostPostingController(InventoryCostPostingService service){this.service=service;}
    @GetMapping("/postings")
    @PreAuthorize("hasAuthority('finance_report:view') and hasAuthority('goods:cost:view')")
    public List<InventoryCostPostingQueryPort.Posting> postings(@RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate from,
            @RequestParam @DateTimeFormat(iso=DateTimeFormat.ISO.DATE) LocalDate to,@RequestParam(required=false) UUID goodsId){return service.postings(from,to,goodsId);}
    @GetMapping("/policy") @PreAuthorize("hasAuthority('finance_post:execute')")
    public InventoryCostPostingService.Policy policy(){return service.policy();}
    @GetMapping("/periods") @PreAuthorize("hasAuthority('finance_post:execute')")
    public List<InventoryCostPostingService.PeriodView> periods(@RequestParam String from,@RequestParam String to){return service.periods(from,to);}
    @PutMapping("/policy") @PreAuthorize("hasAuthority('finance_post:execute')")
    public InventoryCostPostingService.Policy configure(@RequestBody InventoryCostPostingService.PolicyChange request){return service.configure(request);}
    @PostMapping("/postings/{postingId}/period") @PreAuthorize("hasAuthority('finance_post:execute')")
    public InventoryCostPostingQueryPort.Posting choose(@PathVariable UUID postingId,@RequestBody InventoryCostPostingService.PeriodChoice request){return service.choosePeriod(postingId,request);}
    @PostMapping("/periods/{period}/post") @PreAuthorize("hasAuthority('finance_post:execute')")
    public InventoryCostPostingService.Posted post(@PathVariable String period){return service.post(period);}
    @PostMapping("/periods/{period}/close") @PreAuthorize("hasAuthority('finance_post:execute')")
    public void close(@PathVariable String period,@RequestBody InventoryCostPostingService.ClosePeriod request){service.close(period,request);}
}
