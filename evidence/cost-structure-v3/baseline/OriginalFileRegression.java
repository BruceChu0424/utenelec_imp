package independent;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.math.BigDecimal;
import com.uten.imp.features.master.goods.costing.GoodsCostWorkbookParser;
import com.uten.imp.common.web.ApiException;

/** Rereads preserved pre-fix workbook bytes. It never regenerates or rewrites inputs. */
public class OriginalFileRegression {
  public static void main(String[] args) throws Exception {
    Path originals=Path.of(args[0]); int passed=0,failed=0;
    for(String variant:List.of("ordinary-control","reserved-name-control","mixed-header-tail","subtotal-name-control")) {
      byte[] bytes=Files.readAllBytes(originals.resolve(variant+".xlsx"));
      String sha=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
      try {
        if(variant.equals("mixed-header-tail")) {
          ApiException refusal=null;
          try { GoodsCostWorkbookParser.parse(UUID.randomUUID(),variant+".xlsx",sha,bytes); }
          catch(ApiException expected) { refusal=expected; }
          if(refusal==null)throw new AssertionError("mixed material/header row accepted instead of located rejection");
          if(refusal.getMessage()==null||refusal.getMessage().isBlank())throw new AssertionError("refusal has no actionable message");
          System.out.println("PASS "+variant+" REJECTED code="+refusal.getCode()+" message="+refusal.getMessage()+" originalRawSha256="+sha);
        } else {
          var preview=GoodsCostWorkbookParser.parse(UUID.randomUUID(),variant+".xlsx",sha,bytes);
          var rows=preview.blocks().stream().flatMap(block->block.rows().stream()).toList();
          String expectedSecond=variant.equals("ordinary-control")?"铜片":variant.equals("subtotal-name-control")?"小计数器件":"材料名称";
          if(rows.size()!=2||!rows.get(0).name().equals("铜钉")||!rows.get(1).name().equals(expectedSecond))
            throw new AssertionError("expected two exact materials; actual="+rows.stream().map(row->row.name()).toList());
          for(var row:rows)if(new BigDecimal(row.quantity()).compareTo(BigDecimal.ONE)!=0||new BigDecimal(row.unitPrice()).compareTo(new BigDecimal("4"))!=0)
            throw new AssertionError("original material quantity/price changed");
          System.out.println("PASS "+variant+" rows="+rows.size()+" names="+rows.stream().map(row->row.name()).toList()+" originalRawSha256="+sha);
        }
        passed++;
      } catch(Throwable failure) { failed++;System.out.println("FAIL "+variant+" "+failure+" originalRawSha256="+sha); }
    }
    System.out.println("SUMMARY passed="+passed+" failed="+failed+" errors=0 skipped=0; parser-only/no database apply");
    if(failed!=0)System.exit(1);
  }
}
