package com.uten.imp.businesschain;

import com.uten.imp.application.port.InventoryMovementCostReference.WorkshopMaterialBin;
import com.uten.imp.application.port.InventoryMovementCostReference.WorkshopMaterialBinKind;
import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.dto.WorkshopMaterialDocumentCommand;
import com.uten.imp.features.stock.dto.WorkshopMaterialDocumentCommand.Kind;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 车间内料仓的库存侧 (包 S1): 内料仓单据的审核通道、来源核验、可动用量口径与 21/22 型估价。
 *
 * <p>领料单、其它耗用、期间、盘点单这些内料仓业务行在这里按内料仓服务 (包 S2) 将来的写法直接落库,
 * 库存单据、库存流水与估价一律走真实的 {@link StockDocService} / {@link StockService}; 每个事务提交时
 * V740 的延迟断言 (来源核对、流水合计 = 余额、期间用量、盘点过账净额) 全部生效。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopMaterialStockAuthorizationPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired StockDocService stock;
    @Autowired StockService stockService;
    @Autowired InventoryValueWorkService valueWork;
    @Autowired DocNumberService docNumbers;
    @Autowired LineSideWarehousePort lineSide;
    FullChainEndToEndTest fixture;

    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    /** 一个开启整批领料的车间: 叶仓 = 世界仓 (内料仓的主仓), 第 1 期从今天开始。 */
    private record Bin(FullChainEndToEndTest.World world,UUID user,UUID workshop,UUID worker,UUID kg,UUID leaf,UUID bin,UUID period){}
    private record Posting(UUID id,UUID movement){}

    @Test void transfersIntoTheBinKeepOnlyReservationsAndBinOutboundsKeepOnlyTheFloor(){
        Bin b=enabledBin("floor");
        UUID granule=granule(b,"颗粒甲","OWN",1000);
        otherIn(b,granule,"200","10");
        // 普通出库仍守可动用量(已扣安全库存 1000): 叶仓 200 公斤一公斤都动不了
        UUID ordinary=otherOutDraft(b,granule,"150");
        ApiException blocked=assertThrows(ApiException.class,()->stock.approve(ordinary));
        assertTrue(blocked.getMessage().contains("可动用库存不足"),blocked.getMessage());
        // 通用调拨选不到内料仓
        assertThrows(ApiException.class,()->transferDraft(b,granule,"10",b.bin()));

        // 发到内料仓: 调出一侧只扣有效预留, 不扣安全库存
        UUID issued=issue(b,granule,"150",b.period());
        settleValue(granule);
        balance(b.bin(),granule,"150","1500");
        balance(b.leaf(),granule,"50","500");

        // 内料仓出库 (其它耗用、退回) 只守非负底线; 其它耗用价值去外部
        UUID otherMovement=otherIssue(b,granule,"30",b.period());
        settleValue(granule);
        movementValue(otherMovement,"300","EXTERNAL",null);
        balance(b.bin(),granule,"120","1200");
        returnToLeaf(b,granule,"20",b.period());
        settleValue(granule);
        balance(b.bin(),granule,"100","1000");
        balance(b.leaf(),granule,"70","700");

        // 内料仓单据不能红冲 (服务端先给文案, 库内守卫兜底)
        ApiException reversed=assertThrows(ApiException.class,()->stock.reverse(issued));
        assertTrue(reversed.getMessage().contains("不能红冲"),reversed.getMessage());
        assertEquals(1,db.queryForObject("SELECT status FROM stock_documents WHERE id=?",Integer.class,issued));
    }

    @Test void countPostingsValueAtPoolAverageAndReverseAlongTheirOriginalPath(){
        Bin b=enabledBin("count");
        UUID granule=granule(b,"颗粒乙","OWN",1000);
        otherIn(b,granule,"200","10");
        issue(b,granule,"150",b.period());
        otherIssue(b,granule,"30",b.period());
        // This scenario requires a priced pool before freezing a count's gain price.
        settleValue(granule);
        UUID next=startCounting(b,b.period());

        // 第 1 版: 期初 0 + 领入 150 - 其它 30 - 期末 110 = 实际 10 → 21 型出到在制 (池均价 10)
        UUID line=UUID.randomUUID();
        Posting consume=inTx(()->{
            lock(granule);
            UUID count=submittedCount(b,b.period(),1,null);
            db.update("""
                    INSERT INTO workshop_material_period_lines(id,period_id,goods_id,unit_id,cost_basis,opening_qty,
                        transfer_in_qty,other_issue_qty,closing_qty)
                    VALUES (?,?,?,?,'OWN',0,150,30,110)""",line,b.period(),granule,b.kg());
            Posting posted=post(b,count,line,granule,"CONSUME","10",null,"SUBMIT");
            db.update("UPDATE workshop_material_periods SET status='COUNTED',row_version=row_version+1 WHERE id=?",b.period());
            return posted;
        });
        settleValue(granule);
        movementValue(consume.movement(),"100","WIP",line);
        balance(b.bin(),granule,"110","1100");

        // 更正为实盘比账上多 5: 先原路冲回 21 型, 再按池均价 (1200/120 = 10) 记 22 型盘盈
        Posting[] second=inTx(()->{
            lock(granule);
            UUID count=supersedeAndSubmit(b,"袋料少算了");
            db.update("UPDATE workshop_material_period_lines SET closing_qty=125,row_version=row_version+1 WHERE id=?",line);
            return new Posting[]{post(b,count,line,granule,"CONSUME_REVERSE","10",consume.id(),"CORRECTION"),
                    post(b,count,line,granule,"GAIN","5",null,"CORRECTION")};
        });
        settleValue(granule);
        movementValue(second[0].movement(),"100",null,null);
        movementValue(second[1].movement(),"50",null,null);
        balance(b.bin(),granule,"125","1250");

        // 新一期按更高的价发料进来, 池均价变了: 仓库另收 50 公斤单价 20, 再发 100 公斤进内料仓 (记下一期)
        otherIn(b,granule,"50","20");
        issue(b,granule,"100",next);
        settleValue(granule);
        balance(b.bin(),granule,"225","2750");

        // 再更正回多用 10: 22 型原路出按出库时池均价 (2750/225) 出到外部, 不是原盘盈价 10; 再出 21 型 10
        Posting[] third=inTx(()->{
            lock(granule);
            UUID count=supersedeAndSubmit(b,"再次核对袋料");
            db.update("UPDATE workshop_material_period_lines SET closing_qty=110,row_version=row_version+1 WHERE id=?",line);
            return new Posting[]{post(b,count,line,granule,"GAIN_REVERSE","5",second[1].id(),"CORRECTION"),
                    post(b,count,line,granule,"CONSUME","10",null,"CORRECTION")};
        });
        settleValue(granule);
        movementValue(third[0].movement(),"61.1111","EXTERNAL",line);
        movementValue(third[1].movement(),"122.2222","WIP",line);
        balance(b.bin(),granule,"210","2566.6667");
        // 三版盘点的过账净额: 净 21 型 = 实际 10, 净 22 型 = 0 (库内期间用量断言已在每次提交时核对)
        money("10",db.queryForObject("""
                SELECT sum(CASE kind WHEN 'CONSUME' THEN qty WHEN 'CONSUME_REVERSE' THEN -qty ELSE 0 END)
                FROM workshop_material_count_postings WHERE period_line_id=?""",BigDecimal.class,line));
        money("0",db.queryForObject("""
                SELECT sum(CASE kind WHEN 'GAIN' THEN qty WHEN 'GAIN_REVERSE' THEN -qty ELSE 0 END)
                FROM workshop_material_count_postings WHERE period_line_id=?""",BigDecimal.class,line));
    }

    @Test void gainFallsBackToTheLastTransferPriceThenToZero(){
        Bin b=enabledBin("gain");
        UUID used=granule(b,"颗粒丙","OWN",0);
        UUID unseen=granule(b,"颗粒丁","OWN",0);
        otherIn(b,used,"10","20");
        issue(b,used,"10",b.period());
        otherIssue(b,used,"10",b.period());
        // "Last transfer price" means a transfer whose real value worker has finalized it.
        settleValue(used);
        balance(b.bin(),used,"0","0");
        startCounting(b,b.period());

        UUID usedLine=UUID.randomUUID(),unseenLine=UUID.randomUUID();
        Posting[] gains=inTx(()->{
            lock(used,unseen);
            UUID count=submittedCount(b,b.period(),1,null);
            db.update("""
                    INSERT INTO workshop_material_period_lines(id,period_id,goods_id,unit_id,cost_basis,opening_qty,
                        transfer_in_qty,other_issue_qty,closing_qty)
                    VALUES (?,?,?,?,'OWN',0,10,10,2),(?,?,?,?,'OWN',0,0,0,3)""",
                    usedLine,b.period(),used,b.kg(),unseenLine,b.period(),unseen,b.kg());
            Posting first=post(b,count,usedLine,used,"GAIN","2",null,"SUBMIT");
            Posting second=post(b,count,unseenLine,unseen,"GAIN","3",null,"SUBMIT");
            db.update("UPDATE workshop_material_periods SET status='COUNTED',row_version=row_version+1 WHERE id=?",b.period());
            return new Posting[]{first,second};
        });
        settleValue(used,unseen);
        // 内料仓池已空: 取最近一次调入这种料的单价 (200/10 = 20)
        movementValue(gains[0].movement(),"40",null,null);
        // 从没调入过: 按 0 核定, 不留"成本未定"
        movementValue(gains[1].movement(),"0",null,null);
        balance(b.bin(),unseen,"3","0");
    }

    @Test void workshopMaterialMovementsWithoutTheirRegisteredSourceAreRejected(){
        Bin b=enabledBin("forged");
        UUID granule=granule(b,"颗粒戊","OWN",0);
        otherIn(b,granule,"10","10");
        UUID count=UUID.randomUUID(),line=UUID.randomUUID();
        // 21/22 型没有来源引用: 编码错误
        assertThrows(IllegalArgumentException.class,()->inTx(()->{
            lock(granule);
            return stockService.recordMovement(new StockService.MovementRequest(null,StockService.TYPE_WORKSHOP_MATERIAL_GAIN,
                    StockService.SRC_WORKSHOP_MATERIAL_COUNT,count,line,granule,null,b.bin(),StockService.DIR_IN,BigDecimal.ONE,
                    b.kg(),BigDecimal.ONE,null,"未登记的盘盈",null,null));
        }));
        // 种类与流水方向不一致: 编码错误
        assertThrows(IllegalArgumentException.class,()->inTx(()->{
            lock(granule);
            return stockService.recordMovement(countMovement(b,granule,count,line,StockService.TYPE_WORKSHOP_MATERIAL_GAIN,
                    StockService.DIR_OUT,BigDecimal.ONE,new WorkshopMaterialBin(UUID.randomUUID(),WorkshopMaterialBinKind.GAIN)));
        }));
        // 引用了本事务里并不存在的盘点过账
        ApiException forgedCount=assertThrows(ApiException.class,()->inTx(()->{
            lock(granule);
            return stockService.recordMovement(countMovement(b,granule,count,line,StockService.TYPE_WORKSHOP_MATERIAL_GAIN,
                    StockService.DIR_IN,BigDecimal.ONE,new WorkshopMaterialBin(UUID.randomUUID(),WorkshopMaterialBinKind.GAIN)));
        }));
        assertTrue(forgedCount.getMessage().contains("缺少本次登记的来源"),forgedCount.getMessage());
        // 冒充内料仓发料的调出: 没有本事务登记的单据
        ApiException forgedIssue=assertThrows(ApiException.class,()->inTx(()->{
            lock(granule);
            return stockService.recordMovement(new StockService.MovementRequest(null,(short)8,"STOCK_DOC",UUID.randomUUID(),
                    UUID.randomUUID(),granule,null,b.leaf(),StockService.DIR_OUT,BigDecimal.ONE,b.kg(),BigDecimal.ONE,null,
                    "冒充发料",null,new WorkshopMaterialBin(UUID.randomUUID(),WorkshopMaterialBinKind.ISSUE_OUT)));
        }));
        assertTrue(forgedIssue.getMessage().contains("缺少本次登记的来源"),forgedIssue.getMessage());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_movements WHERE warehouse_id=? AND goods_id=?",
                Integer.class,b.bin(),granule));
        balance(b.leaf(),granule,"10","100");
    }

    // ---------------------------------------------------------------------------------------------
    // 夹具
    // ---------------------------------------------------------------------------------------------

    private Bin enabledBin(String tag){
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String unique=tag+"-"+UUID.randomUUID().toString().substring(0,8);
        var world=fixture.seedWorld("wm-stock-"+unique);
        fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","wm-stock-"+unique);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");
        UUID worker=ReflectionTestUtils.invokeMethod(assignment,"workerId");
        UUID kg=UUID.randomUUID();
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES (?,?,?,'千克','使用')",
                kg,900_000_000+ThreadLocalRandom.current().nextInt(90_000_000),"KG-"+unique);
        db.update("""
                INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                VALUES (?, 'MASS', 'KG', 'MANUAL_GOVERNANCE')""",kg);
        UUID period=UUID.randomUUID();
        UUID bin=inTx(()->{
            UUID created=lineSide.ensure(workshop,world.warehouseId());
            db.update("""
                    INSERT INTO workshop_material_settings(workshop_department_id,periodic_enabled,periodic_bin_warehouse_id,
                        go_live_date,enabled_by,enabled_at,created_by)
                    VALUES (?,TRUE,?,?,?,now(),?)""",workshop,created,today(),world.superAdminUserId(),world.superAdminUserId());
            db.update("""
                    INSERT INTO workshop_material_periods(id,bin_warehouse_id,workshop_department_id,period_no,start_date,created_by)
                    VALUES (?,?,?,1,?,?)""",period,created,workshop,today(),world.superAdminUserId());
            return created;
        });
        return new Bin(world,world.superAdminUserId(),workshop,worker,kg,world.warehouseId(),bin,period);
    }

    private UUID granule(Bin b,String name,String basis,int safetyStock){
        UUID id=UUID.randomUUID();
        int legacy=db.queryForObject("SELECT legacy_id FROM units WHERE id=?",Integer.class,b.kg());
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,
                                  issue_method,periodic_cost_basis,min_qty)
                VALUES (?,?,?,'采购','使用',?,?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),'PERIODIC',?,?)""",
                id,"WM-"+id.toString().substring(0,8),name+"-"+id.toString().substring(0,4),b.kg(),legacy,basis,safetyStock);
        return id;
    }

    private void otherIn(Bin b,UUID goods,String qty,String price){
        fixture.loginAs(b.user());
        var request=new StockDocSaveRequest();
        request.setDocType("OTHER_IN");request.setWarehouseId(b.leaf());request.setBillDate(today());
        var line=line(b,goods,qty);
        line.setPrice(new BigDecimal(price));
        line.setAmountOriginal(new BigDecimal(qty).multiply(new BigDecimal(price)));
        line.setAmountLocal(line.getAmountOriginal());
        request.setItems(List.of(line));
        stock.approve(stock.create(request).getId());
    }

    private UUID otherOutDraft(Bin b,UUID goods,String qty){
        var request=new StockDocSaveRequest();
        request.setDocType("OTHER_OUT");request.setWarehouseId(b.leaf());request.setBillDate(today());
        request.setItems(List.of(line(b,goods,qty)));
        return stock.create(request).getId();
    }

    private UUID transferDraft(Bin b,UUID goods,String qty,UUID to){
        var request=new StockDocSaveRequest();
        request.setDocType("TRANSFER");request.setWarehouseId(b.leaf());request.setToWarehouseId(to);request.setBillDate(today());
        request.setItems(List.of(line(b,goods,qty)));
        return stock.create(request).getId();
    }

    private static StockDocItemLine line(Bin b,UUID goods,String qty){
        var line=new StockDocItemLine();
        line.setGoodsId(goods);line.setUnitId(b.kg());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));
        return line;
    }

    /** 仓库直接发料 (内料仓服务的写法): 领料单 → 建单审核 → 调拨关联 → 实发 → 办完。返回调拨单。 */
    private UUID issue(Bin b,UUID goods,String qty,UUID period){
        return inTx(()->{
            UUID requisition=UUID.randomUUID(),line=UUID.randomUUID();
            db.update("""
                    INSERT INTO workshop_material_requisitions(id,request_no,kind,origin,bin_warehouse_id,workshop_department_id,
                        receiver_employee_id,requested_by)
                    VALUES (?,?,'ISSUE','WAREHOUSE_DIRECT',?,?,?,?)""",
                    requisition,docNumbers.nextNumber(DocNumberPrefix.WORKSHOP_MATERIAL_ISSUE),b.bin(),b.workshop(),b.worker(),b.user());
            db.update("""
                    INSERT INTO workshop_material_requisition_lines(id,requisition_id,line_no,goods_id,unit_id,requested_qty)
                    VALUES (?,?,1,?,?,?)""",line,requisition,goods,b.kg(),new BigDecimal(qty));
            lock(goods);
            var posted=stock.createAndApproveWorkshopMaterialDocument(new WorkshopMaterialDocumentCommand(Kind.ISSUE,
                    b.bin(),b.leaf(),requisition,null,b.workshop(),b.worker(),null,"直接发料",
                    List.of(new WorkshopMaterialDocumentCommand.Line(goods,null,b.kg(),BigDecimal.ONE,new BigDecimal(qty),null))));
            assertEquals("TRANSFER",posted.docType());
            var row=posted.lines().getFirst();
            requisitionPosting(b,line,row,goods,period);
            db.update("""
                    UPDATE workshop_material_requisitions SET status='DONE',done_by=?,done_at=now(),row_version=row_version+1
                    WHERE id=?""",b.user(),requisition);
            return posted.documentId();
        });
    }

    /** 收车间退回: 内料仓 → 叶仓的调拨, 内料仓一侧是 8 型调出。 */
    private void returnToLeaf(Bin b,UUID goods,String qty,UUID period){
        inTx(()->{
            UUID requisition=UUID.randomUUID(),line=UUID.randomUUID();
            db.update("""
                    INSERT INTO workshop_material_requisitions(id,request_no,kind,origin,bin_warehouse_id,workshop_department_id,
                        requested_by)
                    VALUES (?,?,'RETURN','WORKSHOP_REQUEST',?,?,?)""",
                    requisition,docNumbers.nextNumber(DocNumberPrefix.WORKSHOP_MATERIAL_RETURN),b.bin(),b.workshop(),b.user());
            db.update("""
                    INSERT INTO workshop_material_requisition_lines(id,requisition_id,line_no,goods_id,unit_id,requested_qty)
                    VALUES (?,?,1,?,?,?)""",line,requisition,goods,b.kg(),new BigDecimal(qty));
            lock(goods);
            var posted=stock.createAndApproveWorkshopMaterialDocument(new WorkshopMaterialDocumentCommand(Kind.RETURN,
                    b.bin(),b.leaf(),requisition,null,b.workshop(),null,null,"收车间退回",
                    List.of(new WorkshopMaterialDocumentCommand.Line(goods,null,b.kg(),BigDecimal.ONE,new BigDecimal(qty),null))));
            var row=posted.lines().getFirst();
            assertEquals(8,db.queryForObject("SELECT movement_type FROM stock_movements WHERE id=?",Integer.class,row.binMovementId()));
            requisitionPosting(b,line,row,goods,period);
            db.update("""
                    UPDATE workshop_material_requisitions SET status='DONE',done_by=?,done_at=now(),row_version=row_version+1
                    WHERE id=?""",b.user(),requisition);
            return null;
        });
    }

    private void requisitionPosting(Bin b,UUID line,WorkshopMaterialDocumentCommand.PostedLine row,UUID goods,UUID period){
        db.update("""
                INSERT INTO workshop_material_requisition_postings(line_id,stock_document_item_id,leaf_warehouse_id,
                    bin_warehouse_id,goods_id,movement_id,qty,period_id,business_date,created_by)
                VALUES (?,?,?,?,?,?,?,?,?,?)""",
                line,row.itemId(),b.leaf(),b.bin(),goods,row.binMovementId(),row.baseQty(),period,today(),b.user());
        db.update("UPDATE workshop_material_requisition_lines SET fulfilled_qty=fulfilled_qty+? WHERE id=?",row.baseQty(),line);
    }

    /** 其它耗用: 先记耗用, 再建其它出库单审核, 回填明细与流水。返回内料仓一侧的 12 型流水。 */
    private UUID otherIssue(Bin b,UUID goods,String qty,UUID period){
        return inTx(()->{
            UUID other=UUID.randomUUID();
            db.update("""
                    INSERT INTO workshop_material_other_issues(id,bin_warehouse_id,workshop_department_id,goods_id,unit_id,qty,
                        reason,period_id,business_date,created_by)
                    VALUES (?,?,?,?,?,?,'PURGE',?,?,?)""",
                    other,b.bin(),b.workshop(),goods,b.kg(),new BigDecimal(qty),period,today(),b.user());
            lock(goods);
            var posted=stock.createAndApproveWorkshopMaterialDocument(new WorkshopMaterialDocumentCommand(Kind.OTHER_ISSUE,
                    b.bin(),null,null,other,b.workshop(),null,null,"清机",
                    List.of(new WorkshopMaterialDocumentCommand.Line(goods,null,b.kg(),BigDecimal.ONE,new BigDecimal(qty),null))));
            assertEquals("OTHER_OUT",posted.docType());
            var row=posted.lines().getFirst();
            db.update("UPDATE workshop_material_other_issues SET stock_document_item_id=?,movement_id=? WHERE id=?",
                    row.itemId(),row.binMovementId(),other);
            return row.binMovementId();
        });
    }

    /** 开始盘点 (截止今天) 并开出下一期。返回下一期。 */
    private UUID startCounting(Bin b,UUID period){
        UUID next=UUID.randomUUID();
        inTx(()->{
            db.update("""
                    UPDATE workshop_material_periods SET status='COUNTING',end_date=?,counting_started_by=?,
                        counting_started_at=now(),row_version=row_version+1 WHERE id=?""",today(),b.user(),period);
            db.update("""
                    INSERT INTO workshop_material_periods(id,bin_warehouse_id,workshop_department_id,period_no,start_date,created_by)
                    VALUES (?,?,?,2,?,?)""",next,b.bin(),b.workshop(),today().plusDays(1),b.user());
            return null;
        });
        return next;
    }

    private UUID submittedCount(Bin b,UUID period,int version,String reason){
        UUID count=UUID.randomUUID();
        db.update("INSERT INTO workshop_material_counts(id,period_id,version,correction_reason,created_by) VALUES (?,?,?,?,?)",
                count,period,version,reason,b.user());
        db.update("""
                UPDATE workshop_material_counts SET status='SUBMITTED',submitted_by=?,submitted_at=now(),row_version=row_version+1
                WHERE id=?""",b.user(),count);
        return count;
    }

    /** 更正盘点: 作废当前有效的那一版, 提交下一版。 */
    private UUID supersedeAndSubmit(Bin b,String reason){
        var current=db.queryForMap("SELECT id,version FROM workshop_material_counts WHERE period_id=? AND status='SUBMITTED'",b.period());
        db.update("UPDATE workshop_material_counts SET status='SUPERSEDED',row_version=row_version+1 WHERE id=?",current.get("id"));
        return submittedCount(b,b.period(),((Number)current.get("version")).intValue()+1,reason);
    }

    /** 盘点过账 (内料仓服务的写法): 先记过账行, 再以它为来源引用记 21/22 型流水, 回填流水。 */
    private Posting post(Bin b,UUID count,UUID line,UUID goods,String kind,String qty,UUID reverses,String reason){
        UUID posting=UUID.randomUUID();
        db.update("""
                INSERT INTO workshop_material_count_postings(id,period_line_id,count_id,bin_warehouse_id,goods_id,kind,
                    reverses_posting_id,qty,business_date,reason,created_by)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                posting,line,count,b.bin(),goods,kind,reverses,new BigDecimal(qty),today(),reason,b.user());
        short type=kind.startsWith("CONSUME")?StockService.TYPE_WORKSHOP_MATERIAL_CONSUME:StockService.TYPE_WORKSHOP_MATERIAL_GAIN;
        short direction="CONSUME".equals(kind)||"GAIN_REVERSE".equals(kind)?StockService.DIR_OUT:StockService.DIR_IN;
        UUID movement=stockService.recordMovement(countMovement(b,goods,count,line,type,direction,new BigDecimal(qty),
                new WorkshopMaterialBin(posting,WorkshopMaterialBinKind.valueOf(kind)))).movementId();
        db.update("UPDATE workshop_material_count_postings SET movement_id=? WHERE id=?",movement,posting);
        return new Posting(posting,movement);
    }

    /** 内料仓盘点流水请求: 来源 = 盘点单 + 期间用量行, 调用方不带单价。 */
    private static StockService.MovementRequest countMovement(Bin b,UUID goods,UUID count,UUID line,short type,short direction,
            BigDecimal qty,WorkshopMaterialBin reference){
        return new StockService.MovementRequest(null,type,StockService.SRC_WORKSHOP_MATERIAL_COUNT,count,line,goods,null,
                b.bin(),direction,qty,b.kg(),BigDecimal.ONE,null,"盘点过账",null,reference);
    }

    private void lock(UUID... goods){
        stockService.lockInventory(java.util.Arrays.stream(goods).map(id->new InventoryKey(id,null)).toList());
    }

    /** Drain durable valuation work after commit for this fixture only; never rewrite prices or states. */
    private void settleValue(UUID... goods){
        InventoryValueWorkTestSupport.drain(valueWork,db,List.of(goods));
    }

    private void balance(UUID warehouse,UUID goods,String qty,String amount){
        var row=db.queryForMap("SELECT qty,amount_local FROM stock_balances WHERE warehouse_id=? AND goods_id=? AND color_id IS NULL",
                warehouse,goods);
        money(qty,(BigDecimal)row.get("qty"));
        money(amount,(BigDecimal)row.get("amount_local"));
    }

    /** 这笔流水冻结的已知价值 (确定价) 与价值去向。 */
    private void movementValue(UUID movement,String value,String ownerKind,UUID ownerId){
        Map<String,Object> row=db.queryForMap("""
                SELECT event.known_value_local,event.result_state,node.owner_kind,node.owner_id
                FROM stock_value_events event JOIN stock_value_nodes node ON node.id=event.result_node_id
                WHERE event.movement_id=?""",movement);
        money(value,(BigDecimal)row.get("known_value_local"));
        assertEquals("FINAL",row.get("result_state"));
        if(ownerKind!=null)assertEquals(ownerKind,row.get("owner_kind"));
        if(ownerId!=null)assertEquals(ownerId,row.get("owner_id"));
    }

    private <T> T inTx(Supplier<T> work){
        return new TransactionTemplate(transactions).execute(status->work.get());
    }

    private static LocalDate today(){return BusinessTime.today();}

    private static void money(String expected,BigDecimal actual){
        assertNotNull(actual);
        assertEquals(0,new BigDecimal(expected).compareTo(actual),()->"expected "+expected+", actual "+actual);
    }
}
