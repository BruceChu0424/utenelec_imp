import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';

void main() {
  testWidgets('行内编号检查阻止保存并忽略失效回包，取消不写入', (tester) async {
    final form = MasterInlineEditController<String>()..begin();
    final requests = <String, Completer<String?>>{};
    final field = MasterInlineField<String>(
      key: 'code',
      read: (row) => row,
      asyncValidate: (id, value) =>
          (requests[value.toString()] = Completer<String?>()).future,
    );
    var writes = 0;
    form.setValue('id', field, 'FIRST', originalValue: 'OLD');
    expect(
      await form.save((_, _) async {
        writes++;
      }),
      isFalse,
    );
    await tester.pump(const Duration(milliseconds: 300));
    form.setValue('id', field, 'SECOND', originalValue: 'OLD');
    await tester.pump(const Duration(milliseconds: 300));
    requests['FIRST']!.complete(null);
    requests['SECOND']!.complete('编号已存在');
    await tester.pump();
    expect(form.validationError('id', 'code'), '编号已存在');
    expect(
      await form.save((_, _) async {
        writes++;
      }),
      isFalse,
    );
    form.retryValidation('id', field);
    await tester.pump(const Duration(milliseconds: 300));
    form.cancel();
    requests['SECOND']!.complete(null);
    await tester.pump();
    expect(form.dirty, isFalse);
    expect(writes, 0);
    form.dispose();
  });

  MasterEditFormController controller({String code = ''}) =>
      MasterEditFormController(
        fields: const [
          MasterFieldDef(key: 'name', label: '名称', required: true),
          MasterFieldDef(key: 'code', label: '编号', identifierDomain: 'GOODS'),
        ],
        initialValues: {'name': '塑胶件', 'code': code},
      );

  testWidgets('空白自动编号和原号不探测、不预留，编辑新号防抖且检查中不可保存', (tester) async {
    final form = controller(code: 'HP01');
    addTearDown(form.dispose);
    final calls = <String>[];
    form.configureIdentifierChecker((code) async {
      calls.add(code);
      return null;
    });
    await tester.pump(const Duration(milliseconds: 310));
    expect(calls, isEmpty);
    form.controllers['code']!.text = 'CUSTOM-A';
    expect(form.buildBody(), isNull);
    form.controllers['code']!.text = 'CUSTOM-B';
    await tester.pump(const Duration(milliseconds: 299));
    expect(calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, ['CUSTOM-B']);
    expect(form.buildBody()?['code'], 'CUSTOM-B');
    form.controllers['code']!.text = '';
    expect(form.buildBody()?['code'], isNull);
    await tester.pump(const Duration(milliseconds: 310));
    expect(calls, ['CUSTOM-B']);
  });

  testWidgets('过时查重结果不能覆盖最新编号，冲突不允许保存', (tester) async {
    final form = controller();
    addTearDown(form.dispose);
    final requests = <String, Completer<String?>>{};
    form.configureIdentifierChecker(
      (code) => (requests[code] = Completer<String?>()).future,
    );
    form.controllers['code']!.text = 'FIRST';
    await tester.pump(const Duration(milliseconds: 300));
    form.controllers['code']!.text = 'SECOND';
    await tester.pump(const Duration(milliseconds: 300));
    requests['SECOND']!.complete('编号已存在');
    await tester.pump();
    requests['FIRST']!.complete(null);
    await tester.pump();
    expect(form.identifierError, '编号已存在');
    expect(form.buildBody(), isNull);
    expect(form.errorFieldKey, 'code');
    form.retryIdentifierCheck();
    await tester.pump(const Duration(milliseconds: 300));
    requests['SECOND']!.complete(null);
    await tester.pump();
    expect(form.buildBody()?['code'], 'SECOND');
  });

  testWidgets('网络检查失败阻止提交并能原值重试，销毁后忽略回包', (tester) async {
    final form = controller();
    var fails = true;
    final inFlight = Completer<String?>();
    form.configureIdentifierChecker((code) async {
      if (fails) throw StateError('offline');
      return inFlight.future;
    });
    form.controllers['code']!.text = 'RESTORE';
    await tester.pump(const Duration(milliseconds: 300));
    expect(form.identifierError, '编号检查失败，请重试');
    expect(form.buildBody(), isNull);
    fails = false;
    form.retryIdentifierCheck();
    await tester.pump(const Duration(milliseconds: 300));
    form.dispose();
    inFlight.complete(null);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
