import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/attachments/attachment_delimited_text.dart';

void main() {
  test('逗号 CSV：按行列拆开，尾行没有换行也算一行', () {
    final table = parseDelimitedText('姓名,部门,金额\n张三,生产部,1200.50');
    expect(table.delimiter, ',');
    expect(table.totalRows, 2);
    expect(table.rows.first, ['姓名', '部门', '金额']);
    expect(table.rows[1], ['张三', '生产部', '1200.50']);
    expect(table.columnCount, 3);
    expect(table.truncated, isFalse);
  });

  test('引号规则：分隔符、换行与成对引号都在单元格里', () {
    final table = parseDelimitedText('备注,金额\n"含,逗号\n第二行","1,200"\n');
    expect(table.rows[1][0], '含,逗号\n第二行');
    expect(table.rows[1][1], '1,200');
    expect(table.totalRows, 2);

    final escaped = parseDelimitedText('a\n"他说""好"""\n');
    expect(escaped.rows[1].first, '他说"好"');
  });

  test('分隔符嗅探：分号与制表符导出同样能排成表', () {
    expect(sniffDelimiter('a;b;c\n1;2;3\n'), ';');
    expect(sniffDelimiter('a\tb\tc\n1\t2\t3\n'), '\t');
    expect(sniffDelimiter('单列\n只有一行\n'), ',', reason: '认不出就退回逗号');
    expect(parseDelimitedText('a;b\n1;2\n').rows[1], [
      '1',
      '2',
    ], reason: '嗅探结果要真正用于拆分');
  });

  test('CRLF / CR 换行都识别，且 CRLF 不算两行', () {
    expect(parseDelimitedText('a,b\r\n1,2\r\n').totalRows, 2);
    expect(parseDelimitedText('a,b\r1,2\r').totalRows, 2);
  });

  test('超过行数上限时只保留前若干行并标记截断', () {
    final text = List.generate(30, (index) => 'r$index,v$index').join('\n');
    final table = parseDelimitedText(text, maxRows: 10);
    expect(table.rows.length, 10);
    expect(table.totalRows, 30);
    expect(table.truncated, isTrue);
  });

  test('空内容不炸', () {
    final table = parseDelimitedText('');
    expect(table.rows, isEmpty);
    expect(table.totalRows, 0);
    expect(table.columnCount, 0);
  });
}
