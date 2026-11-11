import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/components/buttons/uten_edit_floating_actions.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import '../support/memory_form_draft_storage.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/layout/uten_doc_link_picker_sheet.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/buttons/uten_import_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_grid_columns.dart';
import 'package:uten_imp/shared/models/procurement_source_terms.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import '../support/document_scope_capability_overrides.dart';

class Session extends SessionNotifier {
  @override SessionState build() => userState('A');
  SessionState userState(String id)=>SessionState(status:AuthStatus.authenticated,
      user:AppUser(id:id,name:id,code:id,permissions:const ['purchase_return:view','purchase_return:create','subcontract_return:view','subcontract_return:create']));
  void switchOwner()=>state=userState('B');
}
class Api extends ApiClient {
  Api():super(Dio()); Map<String,dynamic>? sent;
  @override Future<Map<String,dynamic>> post(String path,{Object? body,Map<String,dynamic>? headers,Map<String,dynamic>? query}) async {if(path.endsWith('returns')){sent=body as Map<String,dynamic>;throw ApiException('VALIDATION_FAILED','audit transport captured',httpStatus:400,hasResponseCode:true);} return {};}
  @override Future<Map<String,dynamic>> get(String path,{Map<String,dynamic>? query}) async=>
    {'items':<Object>[],'page':1,'size':50,'total':0,'totalPages':0};
  @override Future<List<Map<String,dynamic>>> getList(String path,{Map<String,dynamic>? query}) async=>[];
}
class Names extends MasterNameService {
  Names(super.api); @override Future<void> ensureLoaded() async {}
  final proceed=Completer<void>();
  var detailEntered=false;
  @override Future<void> loadGoodsNamesWithCodes(Iterable<String> ids) async {}
  @override GoodsOption? goodsOptionOf(String? id)=>GoodsOption(id:id!,name:'来源A');
  @override Future<void> loadGoodsDetails(Iterable<String> ids) async {if(ids.contains('g-A')){detailEntered=true;await proceed.future;}}
}
void main(){
  for(final purchase in [true,false]){
    testWidgets('inspect actual save request from '+(purchase?'purchase':'subcontract')+' source',(t)async{
      await t.binding.setSurfaceSize(const Size(1800,1150));
      addTearDown(()=>t.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});final api=Api(), names=Names(api), nav=GlobalKey<NavigatorState>();
      final page=purchase ? const PurchaseDocEditPage(docType:PurchaseDocType.returnDoc)
                       : const SubcontractDocEditPage(docType:SubcontractDocType.returnDoc);
      final container=ProviderContainer(overrides:[
        sessionProvider.overrideWith(Session.new),formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        apiClientProvider.overrideWithValue(api),
        masterNameServiceProvider.overrideWithValue(names),
        writeAllDocumentScope(purchase?DocumentDataScope.purchase:DocumentDataScope.subcontract),
      ]);
      
      await t.pumpWidget(UncontrolledProviderScope(container:container,child:MaterialApp(navigatorKey:nav,home:page)));
      for(var tick=0; tick<12; tick++){await t.pump(const Duration(milliseconds:80));}
      final dynamic state=t.state(find.byWidget(page));
      final dynamic grid=purchase?t.widget<UtenEditableGrid<PurchaseGridRow>>(find.byType(UtenEditableGrid<PurchaseGridRow>)).controller
                            :t.widget<UtenEditableGrid<SubcontractGridRow>>(find.byType(UtenEditableGrid<SubcontractGridRow>)).controller;
      final head=Map<String,dynamic>.from(state.captureFormDraft() as Map)..['warehouseId']='warehouse-A';await state.restoreFormDraft(head);
      expect(state.formDraftIdentityIsCurrent,true);
      await t.tap(find.byType(UtenImportButton)); for(var tick=0; tick<12; tick++){await t.pump(const Duration(milliseconds:80));}
      const exactQty='7.125', exactPrice='1';final rows=[UtenDocLinkPickedItem(goodsId:'g-A',qty:double.parse(exactQty),qtyText:exactQty,maxQtyText:exactQty,price:double.parse(exactPrice),priceText:exactPrice,upstreamItemId:'approved-receipt-A',unitRate:1)];
      const terms=ProcurementSourceTerms(currencyId:'currency-A',exchangeRate:'1',taxRate:'0',settlementMethodId:'terms-A');
      if(purchase){nav.currentState!.pop(UtenDocLinkPickResult<PurchaseDocItem>(items:rows,partyId:'supplier-A',sourceTerms:terms));}
      else {nav.currentState!.pop(UtenDocLinkPickResult<SubcontractDocItem>(items:rows,partyId:'supplier-A',sourceTerms:terms));}
      for(var tick=0; tick<12; tick++){await t.pump(const Duration(milliseconds:80));}
      expect(names.detailEntered,true);
      // same owner holds the open editor
      await t.pump();
      expect(state.formDraftIdentityIsCurrent,true);
      names.proceed.complete();
      for(var tick=0; tick<12; tick++){await t.pump(const Duration(milliseconds:80));}
      final action=t.widget<UtenEditFloatingActions>(find.byType(UtenEditFloatingActions));action.onSave!();
      for(var tick=0;tick<30 && api.sent==null;tick++){await t.pump(const Duration(milliseconds:100));}
      print('audit purchase=$purchase actual save body=${api.sent}');
      expect(api.sent,isNotNull);
      final line=(api.sent!['items'] as List).single as Map;
      expect(line['receiptItemId'],'approved-receipt-A');
      expect(line.containsKey('orderItemId'),false);
      await t.pumpWidget(const SizedBox()); container.dispose();await t.pump(const Duration(seconds:20));
      await t.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await t.pump();
    });
  }
}









