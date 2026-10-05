import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh'),
    Locale('en'),
    Locale('ko'),
  ];

  /// No description provided for @businessColumnAmountUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前账号暂不能让此列参与金额计算。请恢复价格权限，或明确改选文字、数字记录。'**
  String get businessColumnAmountUnavailable;

  /// No description provided for @businessColumnEditorSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'为单据补充信息，或让输入值参与每行正式金额计算。'**
  String get businessColumnEditorSubtitle;

  /// No description provided for @businessColumnBrowse.
  ///
  /// In zh, this message translates to:
  /// **'选择已有列'**
  String get businessColumnBrowse;

  /// No description provided for @businessColumnNew.
  ///
  /// In zh, this message translates to:
  /// **'新建列'**
  String get businessColumnNew;

  /// No description provided for @businessColumnManage.
  ///
  /// In zh, this message translates to:
  /// **'本单已添加'**
  String get businessColumnManage;

  /// No description provided for @businessColumnNoResults.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的列，可以切换到“新建列”。'**
  String get businessColumnNoResults;

  /// No description provided for @businessColumnNewHint.
  ///
  /// In zh, this message translates to:
  /// **'先填写名称，再选择这列的用途。每行的实际数值在表格里填写。'**
  String get businessColumnNewHint;

  /// No description provided for @businessColumnOfficialAmount.
  ///
  /// In zh, this message translates to:
  /// **'参与正式金额'**
  String get businessColumnOfficialAmount;

  /// No description provided for @businessColumnAmountTarget.
  ///
  /// In zh, this message translates to:
  /// **'计算目标'**
  String get businessColumnAmountTarget;

  /// No description provided for @businessColumnRowAmount.
  ///
  /// In zh, this message translates to:
  /// **'本行金额'**
  String get businessColumnRowAmount;

  /// No description provided for @businessColumnRecordHint.
  ///
  /// In zh, this message translates to:
  /// **'每行分别填写，保存为单据补充信息。'**
  String get businessColumnRecordHint;

  /// No description provided for @businessColumnOfficialHint.
  ///
  /// In zh, this message translates to:
  /// **'输入值会计入本行金额；保存、财务审核和后续业务沿用计算后的金额。'**
  String get businessColumnOfficialHint;

  /// No description provided for @businessColumnExampleTitle.
  ///
  /// In zh, this message translates to:
  /// **'试算一下'**
  String get businessColumnExampleTitle;

  /// No description provided for @businessColumnExampleBase.
  ///
  /// In zh, this message translates to:
  /// **'原金额（示例）'**
  String get businessColumnExampleBase;

  /// No description provided for @businessColumnExampleValue.
  ///
  /// In zh, this message translates to:
  /// **'本列输入值（示例）'**
  String get businessColumnExampleValue;

  /// No description provided for @businessColumnExampleHint.
  ///
  /// In zh, this message translates to:
  /// **'示例只帮助理解计算，不会填入单据。留空不参与计算，填写 0 则按 0 计算。'**
  String get businessColumnExampleHint;

  /// No description provided for @businessColumnExampleInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请填写有效数值；不能除以 0，结果须为非负的精确有限小数。'**
  String get businessColumnExampleInvalid;

  /// No description provided for @businessColumnFixedFeeHint.
  ///
  /// In zh, this message translates to:
  /// **'此值按每行收取一次。例如本行金额 100，填 20 后加到 120。'**
  String get businessColumnFixedFeeHint;

  /// No description provided for @businessColumnFactorHint.
  ///
  /// In zh, this message translates to:
  /// **'乘除填写倍率，例如乘 0.9 表示按原金额的 90% 计算。'**
  String get businessColumnFactorHint;

  /// No description provided for @businessColumnRemove.
  ///
  /// In zh, this message translates to:
  /// **'从本单移除'**
  String get businessColumnRemove;

  /// No description provided for @businessColumnRemoveHint.
  ///
  /// In zh, this message translates to:
  /// **'移除后，本单各行的该列内容会清除，金额会重新计算。保存单据后生效；其他单据和可复用列不受影响。'**
  String get businessColumnRemoveHint;

  /// No description provided for @businessColumnUseExisting.
  ///
  /// In zh, this message translates to:
  /// **'使用已有列'**
  String get businessColumnUseExisting;

  /// No description provided for @businessColumnAlreadyAdded.
  ///
  /// In zh, this message translates to:
  /// **'本单已经添加了相同定义的列，可到“本单已添加”查看。'**
  String get businessColumnAlreadyAdded;

  /// No description provided for @businessColumnOrderHint.
  ///
  /// In zh, this message translates to:
  /// **'金额按列的添加顺序计算。拖动表头只改变显示顺序；有值的费用列保持可见。'**
  String get businessColumnOrderHint;

  /// No description provided for @businessColumnNoAdded.
  ///
  /// In zh, this message translates to:
  /// **'本单还没有添加自定义列。'**
  String get businessColumnNoAdded;

  /// No description provided for @businessColumnNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入列名称'**
  String get businessColumnNameRequired;

  /// No description provided for @businessColumnAmountRule.
  ///
  /// In zh, this message translates to:
  /// **'金额运算'**
  String get businessColumnAmountRule;

  /// No description provided for @businessColumnSubtractHint.
  ///
  /// In zh, this message translates to:
  /// **'填写要从本行金额扣减的数值，例如 100 减 20 等于 80。'**
  String get businessColumnSubtractHint;

  /// No description provided for @bomLearningTitle.
  ///
  /// In zh, this message translates to:
  /// **'BOM 学习记录'**
  String get bomLearningTitle;

  /// No description provided for @bomLearningHelp.
  ///
  /// In zh, this message translates to:
  /// **'真实使用数量 = 已完工且核清余料的生产累计净耗料 ÷ 用到该物料的累计产量。物料分析和车间领料优先按真实使用数量计算，没有数据时按设计使用数量；已下达的任务仍按下达时的用量执行。日报登记的不良数只作记录，不计入产量；实产单耗按良品加不良算。'**
  String get bomLearningHelp;

  /// No description provided for @bomLearningInactive.
  ///
  /// In zh, this message translates to:
  /// **'还没有学习记录。本厂生产的货品完工并核清余料后开始累计。'**
  String get bomLearningInactive;

  /// No description provided for @bomLearningPaused.
  ///
  /// In zh, this message translates to:
  /// **'没有自动建立学习组件：{reason}。真实使用数量照常累计。'**
  String bomLearningPaused(String reason);

  /// No description provided for @bomDesignQty.
  ///
  /// In zh, this message translates to:
  /// **'设计使用数量'**
  String get bomDesignQty;

  /// No description provided for @bomActualQty.
  ///
  /// In zh, this message translates to:
  /// **'真实使用数量'**
  String get bomActualQty;

  /// No description provided for @bomLearnedEdge.
  ///
  /// In zh, this message translates to:
  /// **'系统学习'**
  String get bomLearnedEdge;

  /// No description provided for @bomActualTipActual.
  ///
  /// In zh, this message translates to:
  /// **'按 {samples} 批已完工生产累计：净耗 {net} / 产量 {output}'**
  String bomActualTipActual(int samples, String net, String output);

  /// No description provided for @bomActualTipAverage.
  ///
  /// In zh, this message translates to:
  /// **'实际平均每件用 {qty}'**
  String bomActualTipAverage(String qty);

  /// No description provided for @bomActualTipUsed.
  ///
  /// In zh, this message translates to:
  /// **'物料分析和车间领料按真实使用数量计算'**
  String get bomActualTipUsed;

  /// No description provided for @bomUsesDesignBecause.
  ///
  /// In zh, this message translates to:
  /// **'{reason}，计算按设计使用数量'**
  String bomUsesDesignBecause(String reason);

  /// No description provided for @bomDesignReasonNoData.
  ///
  /// In zh, this message translates to:
  /// **'还没有已完工且核清余料的生产数据'**
  String get bomDesignReasonNoData;

  /// No description provided for @bomDesignReasonNotLinear.
  ///
  /// In zh, this message translates to:
  /// **'整包或固定批次不能按平均用量算'**
  String get bomDesignReasonNotLinear;

  /// No description provided for @bomDesignReasonOutputUnitChanged.
  ///
  /// In zh, this message translates to:
  /// **'父件单位变了，需重新学习'**
  String get bomDesignReasonOutputUnitChanged;

  /// No description provided for @bomDesignReasonSubcontractOutbound.
  ///
  /// In zh, this message translates to:
  /// **'上级委外件按领料把这个物料发给委外商，按委外合同(设计)用量'**
  String get bomDesignReasonSubcontractOutbound;

  /// No description provided for @bomDesignReasonOther.
  ///
  /// In zh, this message translates to:
  /// **'没有可用的真实数据'**
  String get bomDesignReasonOther;

  /// No description provided for @bomRelearnedSince.
  ///
  /// In zh, this message translates to:
  /// **'从 {date} 起重新累计'**
  String bomRelearnedSince(String date);

  /// No description provided for @bomDesignQtyRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写设计使用数量'**
  String get bomDesignQtyRequired;

  /// No description provided for @bomDesignQtyInvalid.
  ///
  /// In zh, this message translates to:
  /// **'设计使用数量必须是大于 0 的数字'**
  String get bomDesignQtyInvalid;

  /// No description provided for @bomLearnedEdgeEditHint.
  ///
  /// In zh, this message translates to:
  /// **'这是系统按真实用料学出的组件；改设计使用数量后转为人工维护，真实使用数量照常累计'**
  String get bomLearnedEdgeEditHint;

  /// No description provided for @bomLearnedEdgeDeleteNote.
  ///
  /// In zh, this message translates to:
  /// **'其中 {count} 个是系统学出的组件，删除后系统不会再自动加回'**
  String bomLearnedEdgeDeleteNote(int count);

  /// No description provided for @bomLearningMaterial.
  ///
  /// In zh, this message translates to:
  /// **'物料'**
  String get bomLearningMaterial;

  /// No description provided for @bomLearningExposure.
  ///
  /// In zh, this message translates to:
  /// **'累计产量'**
  String get bomLearningExposure;

  /// No description provided for @bomLearningSampleCount.
  ///
  /// In zh, this message translates to:
  /// **'有效批次'**
  String get bomLearningSampleCount;

  /// No description provided for @bomLearningBasis.
  ///
  /// In zh, this message translates to:
  /// **'计算采用'**
  String get bomLearningBasis;

  /// No description provided for @bomLearningOutsideBom.
  ///
  /// In zh, this message translates to:
  /// **'BOM 外实际用过的料'**
  String get bomLearningOutsideBom;

  /// No description provided for @bomLearningReleased.
  ///
  /// In zh, this message translates to:
  /// **'已删除，不再自动加入'**
  String get bomLearningReleased;

  /// No description provided for @bomLearningRelearn.
  ///
  /// In zh, this message translates to:
  /// **'从现在起重新学习'**
  String get bomLearningRelearn;

  /// No description provided for @bomLearningRelearnConfirm.
  ///
  /// In zh, this message translates to:
  /// **'「{name}」从现在起重新学习？\n之前的累计不再参与计算；新的生产数据出来前，计算按设计使用数量。'**
  String bomLearningRelearnConfirm(String name);

  /// No description provided for @bomLearningRelearnDone.
  ///
  /// In zh, this message translates to:
  /// **'已从现在起重新学习'**
  String get bomLearningRelearnDone;

  /// No description provided for @bomLearningRelearnFailed.
  ///
  /// In zh, this message translates to:
  /// **'重新学习失败，请稍后重试'**
  String get bomLearningRelearnFailed;

  /// No description provided for @bomLearningLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'学习记录加载失败，请重试'**
  String get bomLearningLoadFailed;

  /// No description provided for @bomLearningEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有组件，也没有实际用过的料'**
  String get bomLearningEmpty;

  /// No description provided for @bomLearningAction.
  ///
  /// In zh, this message translates to:
  /// **'操作'**
  String get bomLearningAction;

  /// No description provided for @bomLearningBlockedOutputIdentity.
  ///
  /// In zh, this message translates to:
  /// **'父件单位或身份变了'**
  String get bomLearningBlockedOutputIdentity;

  /// No description provided for @bomLearningBlockedMaterialIdentity.
  ///
  /// In zh, this message translates to:
  /// **'物料已删除或单位变了'**
  String get bomLearningBlockedMaterialIdentity;

  /// No description provided for @bomLearningBlockedColorConflict.
  ///
  /// In zh, this message translates to:
  /// **'同一物料领过多种颜色，请人工在组装信息里确定'**
  String get bomLearningBlockedColorConflict;

  /// No description provided for @bomLearningBlockedPrecision.
  ///
  /// In zh, this message translates to:
  /// **'用量超出可记录范围'**
  String get bomLearningBlockedPrecision;

  /// No description provided for @bomLearningBlockedCycle.
  ///
  /// In zh, this message translates to:
  /// **'会形成组装环路'**
  String get bomLearningBlockedCycle;

  /// No description provided for @bomLearningBlockedOther.
  ///
  /// In zh, this message translates to:
  /// **'请人工在组装信息里维护'**
  String get bomLearningBlockedOther;

  /// No description provided for @materialDiscoveryBatchHelp.
  ///
  /// In zh, this message translates to:
  /// **'请先选择持续生产或齐套生产，登记实际物料后再安排分批'**
  String get materialDiscoveryBatchHelp;

  /// No description provided for @materialDiscoveryCancel.
  ///
  /// In zh, this message translates to:
  /// **'撤回待登记领料申请'**
  String get materialDiscoveryCancel;

  /// No description provided for @bomLearningOutput.
  ///
  /// In zh, this message translates to:
  /// **'累计实际产量'**
  String get bomLearningOutput;

  /// No description provided for @bomLearningSamples.
  ///
  /// In zh, this message translates to:
  /// **'有效生产批次'**
  String get bomLearningSamples;

  /// No description provided for @bomLearningNet.
  ///
  /// In zh, this message translates to:
  /// **'累计净耗料'**
  String get bomLearningNet;

  /// No description provided for @bomActualTipDefect.
  ///
  /// In zh, this message translates to:
  /// **'另有不良 {defect}：按实产(良品+不良)算用量为 {perProduced}，不良率 {rate}'**
  String bomActualTipDefect(String defect, String perProduced, String rate);

  /// No description provided for @bomLearningDefect.
  ///
  /// In zh, this message translates to:
  /// **'不良数'**
  String get bomLearningDefect;

  /// No description provided for @bomLearningPerProduced.
  ///
  /// In zh, this message translates to:
  /// **'实产单耗'**
  String get bomLearningPerProduced;

  /// No description provided for @bomLearningDefectRate.
  ///
  /// In zh, this message translates to:
  /// **'不良率'**
  String get bomLearningDefectRate;

  /// No description provided for @bomLearningTotalDefect.
  ///
  /// In zh, this message translates to:
  /// **'累计不良'**
  String get bomLearningTotalDefect;

  /// No description provided for @materialDiscoveryTitle.
  ///
  /// In zh, this message translates to:
  /// **'填写实际领料'**
  String get materialDiscoveryTitle;

  /// No description provided for @materialDiscoveryHelp.
  ///
  /// In zh, this message translates to:
  /// **'请与领料人核对，为本工单添加一种或多种材料，填写数量和实际发料仓。保存后进入领料单办理实际出库。'**
  String get materialDiscoveryHelp;

  /// No description provided for @materialDiscoveryRequestHelp.
  ///
  /// In zh, this message translates to:
  /// **'这些自制件尚未登记底层材料。知道用料时可按工单选填材料和申请数量；不填也可提交，由仓库补充。仓库会带入已填内容，核对实际发料仓后办理领料，实际发料后才能开工。'**
  String get materialDiscoveryRequestHelp;

  /// No description provided for @materialDiscoveryPrefilledHelp.
  ///
  /// In zh, this message translates to:
  /// **'已带入车间填写的材料和申请数量，无需重复选料。请核对实际发料仓和数量；如有变化，可在表内调整。'**
  String get materialDiscoveryPrefilledHelp;

  /// No description provided for @materialDiscoveryPending.
  ///
  /// In zh, this message translates to:
  /// **'待仓库填写物料'**
  String get materialDiscoveryPending;

  /// No description provided for @materialDiscoveryNeeded.
  ///
  /// In zh, this message translates to:
  /// **'需要登记领料物料'**
  String get materialDiscoveryNeeded;

  /// No description provided for @materialDiscoverySend.
  ///
  /// In zh, this message translates to:
  /// **'提交领料申请'**
  String get materialDiscoverySend;

  /// No description provided for @materialDiscoverySave.
  ///
  /// In zh, this message translates to:
  /// **'保存并生成领料单'**
  String get materialDiscoverySave;

  /// No description provided for @materialDiscoverySaved.
  ///
  /// In zh, this message translates to:
  /// **'物料已登记，请在领料单核对并实际出库'**
  String get materialDiscoverySaved;

  /// No description provided for @materialDiscoveryInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请逐行选择材料和实际仓库，填写大于0且最多4位小数的数量；单位采用货品基本单位'**
  String get materialDiscoveryInvalid;

  /// No description provided for @materialDiscoveryUncertain.
  ///
  /// In zh, this message translates to:
  /// **'回执尚未确认，输入已保留。请核对结果或使用相同内容重试'**
  String get materialDiscoveryUncertain;

  /// No description provided for @materialDiscoveryCheck.
  ///
  /// In zh, this message translates to:
  /// **'核对提交结果'**
  String get materialDiscoveryCheck;

  /// No description provided for @materialDiscoveryPick.
  ///
  /// In zh, this message translates to:
  /// **'选择材料'**
  String get materialDiscoveryPick;

  /// No description provided for @materialDiscoveryWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'实际发料仓'**
  String get materialDiscoveryWarehouse;

  /// No description provided for @materialDiscoveryQuantity.
  ///
  /// In zh, this message translates to:
  /// **'本次领料数量'**
  String get materialDiscoveryQuantity;

  /// No description provided for @materialDiscoveryUnit.
  ///
  /// In zh, this message translates to:
  /// **'单位'**
  String get materialDiscoveryUnit;

  /// No description provided for @materialDiscoveryCode.
  ///
  /// In zh, this message translates to:
  /// **'编号'**
  String get materialDiscoveryCode;

  /// No description provided for @materialDiscoveryColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色'**
  String get materialDiscoveryColor;

  /// No description provided for @materialDiscoveryLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'领料申请加载失败，请重试'**
  String get materialDiscoveryLoadFailed;

  /// No description provided for @materialDiscoveryNoPermission.
  ///
  /// In zh, this message translates to:
  /// **'当前账号没有填写领料物料的权限'**
  String get materialDiscoveryNoPermission;

  /// No description provided for @materialDiscoveryDone.
  ///
  /// In zh, this message translates to:
  /// **'该申请已办理，请查看对应领料单'**
  String get materialDiscoveryDone;

  /// No description provided for @materialDiscoveryOpenDraw.
  ///
  /// In zh, this message translates to:
  /// **'打开领料单'**
  String get materialDiscoveryOpenDraw;

  /// No description provided for @materialDiscoveryRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get materialDiscoveryRetry;

  /// No description provided for @materialDiscoveryRequestSent.
  ///
  /// In zh, this message translates to:
  /// **'领料申请已提交，等待仓库核对并办理领料'**
  String get materialDiscoveryRequestSent;

  /// No description provided for @materialDiscoveryMissingUnit.
  ///
  /// In zh, this message translates to:
  /// **'该材料没有基本单位，请先完善货品资料'**
  String get materialDiscoveryMissingUnit;

  /// No description provided for @materialDiscoveryRequestTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认领料申请'**
  String get materialDiscoveryRequestTitle;

  /// No description provided for @productionDailyReportLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载详情失败，请重试'**
  String get productionDailyReportLoadFailed;

  /// No description provided for @productionDailyReportReverseConfirmation.
  ///
  /// In zh, this message translates to:
  /// **'红冲将反向冲销，确认？'**
  String get productionDailyReportReverseConfirmation;

  /// No description provided for @productionDailyReportDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除日报'**
  String get productionDailyReportDeleteTitle;

  /// No description provided for @productionDailyReportDeleteConfirmation.
  ///
  /// In zh, this message translates to:
  /// **'确定删除该草稿日报吗？'**
  String get productionDailyReportDeleteConfirmation;

  /// No description provided for @productionDailyReportDeleteAction.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get productionDailyReportDeleteAction;

  /// No description provided for @productionDailyReportApprovedStateVerified.
  ///
  /// In zh, this message translates to:
  /// **'当前已审核，页面已刷新。'**
  String get productionDailyReportApprovedStateVerified;

  /// No description provided for @productionDailyReportReversedStateVerified.
  ///
  /// In zh, this message translates to:
  /// **'当前已红冲，页面已刷新。'**
  String get productionDailyReportReversedStateVerified;

  /// No description provided for @productionDailyReportStateChangedReview.
  ///
  /// In zh, this message translates to:
  /// **'日报状态已变化，页面已刷新，请核对当前状态。'**
  String get productionDailyReportStateChangedReview;

  /// 应用标题
  ///
  /// In zh, this message translates to:
  /// **'优腾·综合管理平台'**
  String get appTitle;

  /// No description provided for @commonConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get commonConfirm;

  /// No description provided for @commonCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get commonSave;

  /// No description provided for @commonRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get commonRefresh;

  /// No description provided for @commonRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get commonRetry;

  /// No description provided for @connectionReconnecting.
  ///
  /// In zh, this message translates to:
  /// **'网络暂时不稳定，正在自动连接…'**
  String get connectionReconnecting;

  /// No description provided for @connectionDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'暂时连不上服务器，系统会继续自动连接'**
  String get connectionDisconnected;

  /// No description provided for @connectionRestored.
  ///
  /// In zh, this message translates to:
  /// **'网络已恢复，可以继续使用'**
  String get connectionRestored;

  /// No description provided for @connectionRetryNow.
  ///
  /// In zh, this message translates to:
  /// **'立即重试'**
  String get connectionRetryNow;

  /// No description provided for @commonBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get commonBack;

  /// No description provided for @commonLoading.
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get commonLoading;

  /// No description provided for @commonNoData.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据'**
  String get commonNoData;

  /// No description provided for @commonError.
  ///
  /// In zh, this message translates to:
  /// **'出错了，请稍后重试'**
  String get commonError;

  /// No description provided for @commonSuccess.
  ///
  /// In zh, this message translates to:
  /// **'操作成功'**
  String get commonSuccess;

  /// No description provided for @loginAccountHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入员工工号或手机号'**
  String get loginAccountHint;

  /// No description provided for @loginAccountRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入账号'**
  String get loginAccountRequired;

  /// No description provided for @loginPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码'**
  String get loginPasswordHint;

  /// No description provided for @loginPasswordRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码'**
  String get loginPasswordRequired;

  /// No description provided for @loginButton.
  ///
  /// In zh, this message translates to:
  /// **'登 录'**
  String get loginButton;

  /// No description provided for @loginLoggingIn.
  ///
  /// In zh, this message translates to:
  /// **'登录中…'**
  String get loginLoggingIn;

  /// No description provided for @loginServerRecoveryAction.
  ///
  /// In zh, this message translates to:
  /// **'恢复自动选择服务器'**
  String get loginServerRecoveryAction;

  /// No description provided for @loginServerRecoveryHint.
  ///
  /// In zh, this message translates to:
  /// **'登录异常或更换网络时使用；只会在此安装包内置的公司与云端地址之间自动选择。'**
  String get loginServerRecoveryHint;

  /// No description provided for @loginServerRecoverySuccess.
  ///
  /// In zh, this message translates to:
  /// **'已恢复自动选择，请重新登录'**
  String get loginServerRecoverySuccess;

  /// No description provided for @loginServerRecoveryFailed.
  ///
  /// In zh, this message translates to:
  /// **'服务器选择恢复失败，请稍后重试或联系管理员'**
  String get loginServerRecoveryFailed;

  /// No description provided for @loginFooter.
  ///
  /// In zh, this message translates to:
  /// **'© {year} 优腾 · 综合管理平台'**
  String loginFooter(int year);

  /// No description provided for @navDashboard.
  ///
  /// In zh, this message translates to:
  /// **'工作台'**
  String get navDashboard;

  /// No description provided for @navNotice.
  ///
  /// In zh, this message translates to:
  /// **'通知'**
  String get navNotice;

  /// No description provided for @navProfile.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get navProfile;

  /// No description provided for @navSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get navSettings;

  /// No description provided for @navCollapse.
  ///
  /// In zh, this message translates to:
  /// **'收起导航栏'**
  String get navCollapse;

  /// No description provided for @navExpand.
  ///
  /// In zh, this message translates to:
  /// **'展开导航栏'**
  String get navExpand;

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settingsTitle;

  /// No description provided for @settingsSectionAppearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get settingsSectionAppearance;

  /// No description provided for @settingsThemeMode.
  ///
  /// In zh, this message translates to:
  /// **'主题模式'**
  String get settingsThemeMode;

  /// No description provided for @settingsLanguage.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settingsLanguage;

  /// No description provided for @settingsFontSize.
  ///
  /// In zh, this message translates to:
  /// **'字号'**
  String get settingsFontSize;

  /// No description provided for @settingsFontSizeHint.
  ///
  /// In zh, this message translates to:
  /// **'整体等比缩放：文字、图标、卡片与间距一起变大变小；手机上只放大文字'**
  String get settingsFontSizeHint;

  /// No description provided for @settingsSectionPerformance.
  ///
  /// In zh, this message translates to:
  /// **'性能'**
  String get settingsSectionPerformance;

  /// No description provided for @settingsPerformanceTier.
  ///
  /// In zh, this message translates to:
  /// **'性能模式'**
  String get settingsPerformanceTier;

  /// No description provided for @settingsPerformanceHint.
  ///
  /// In zh, this message translates to:
  /// **'性能差的设备建议选省电模式'**
  String get settingsPerformanceHint;

  /// No description provided for @settingsSectionAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settingsSectionAbout;

  /// No description provided for @settingsVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本'**
  String get settingsVersion;

  /// No description provided for @settingsLogout.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get settingsLogout;

  /// No description provided for @settingsLogoutConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要退出登录吗？'**
  String get settingsLogoutConfirm;

  /// No description provided for @profileChangePassword.
  ///
  /// In zh, this message translates to:
  /// **'修改密码'**
  String get profileChangePassword;

  /// No description provided for @visitorLoginTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客登录'**
  String get visitorLoginTitle;

  /// No description provided for @visitorLoginSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'输入手机号获取验证码'**
  String get visitorLoginSubtitle;

  /// No description provided for @visitorPhoneLabel.
  ///
  /// In zh, this message translates to:
  /// **'手机号'**
  String get visitorPhoneLabel;

  /// No description provided for @visitorPhoneHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入手机号'**
  String get visitorPhoneHint;

  /// No description provided for @visitorCodeLabel.
  ///
  /// In zh, this message translates to:
  /// **'验证码'**
  String get visitorCodeLabel;

  /// No description provided for @visitorCodeHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入验证码'**
  String get visitorCodeHint;

  /// No description provided for @visitorCodeRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入验证码'**
  String get visitorCodeRequired;

  /// No description provided for @visitorGetCode.
  ///
  /// In zh, this message translates to:
  /// **'获取验证码'**
  String get visitorGetCode;

  /// No description provided for @visitorCodeCountdown.
  ///
  /// In zh, this message translates to:
  /// **'{seconds}s 后重发'**
  String visitorCodeCountdown(Object seconds);

  /// No description provided for @visitorLoginButton.
  ///
  /// In zh, this message translates to:
  /// **'登 录'**
  String get visitorLoginButton;

  /// No description provided for @visitorLoggingIn.
  ///
  /// In zh, this message translates to:
  /// **'登录中…'**
  String get visitorLoggingIn;

  /// No description provided for @visitorCodeSentDev.
  ///
  /// In zh, this message translates to:
  /// **'验证码：{code}(开发期)'**
  String visitorCodeSentDev(Object code);

  /// No description provided for @visitorIsEmployee.
  ///
  /// In zh, this message translates to:
  /// **'该手机号为优腾员工账号，请走员工通道登录'**
  String get visitorIsEmployee;

  /// No description provided for @visitorPhoneInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入正确的手机号'**
  String get visitorPhoneInvalid;

  /// No description provided for @visitorHomeTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的访客预约'**
  String get visitorHomeTitle;

  /// No description provided for @visitorSettingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客设置'**
  String get visitorSettingsTitle;

  /// No description provided for @visitorSettingsTooltip.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get visitorSettingsTooltip;

  /// No description provided for @visitorApplyNew.
  ///
  /// In zh, this message translates to:
  /// **'预约来访'**
  String get visitorApplyNew;

  /// No description provided for @visitorFilterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get visitorFilterAll;

  /// No description provided for @visitorFilterPending.
  ///
  /// In zh, this message translates to:
  /// **'申请中'**
  String get visitorFilterPending;

  /// No description provided for @visitorFilterApproved.
  ///
  /// In zh, this message translates to:
  /// **'已批准'**
  String get visitorFilterApproved;

  /// No description provided for @visitorFilterRejected.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝'**
  String get visitorFilterRejected;

  /// No description provided for @visitorApplyTitle.
  ///
  /// In zh, this message translates to:
  /// **'来访预约'**
  String get visitorApplyTitle;

  /// No description provided for @visitorApplyName.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get visitorApplyName;

  /// No description provided for @visitorApplyNameHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入真实姓名'**
  String get visitorApplyNameHint;

  /// No description provided for @visitorApplyIdCard.
  ///
  /// In zh, this message translates to:
  /// **'身份证号'**
  String get visitorApplyIdCard;

  /// No description provided for @visitorApplyIdCardHint.
  ///
  /// In zh, this message translates to:
  /// **'选填'**
  String get visitorApplyIdCardHint;

  /// No description provided for @visitorApplyCompany.
  ///
  /// In zh, this message translates to:
  /// **'来访单位'**
  String get visitorApplyCompany;

  /// No description provided for @visitorApplyCompanyHint.
  ///
  /// In zh, this message translates to:
  /// **'选填'**
  String get visitorApplyCompanyHint;

  /// No description provided for @visitorApplyPurpose.
  ///
  /// In zh, this message translates to:
  /// **'来访事由'**
  String get visitorApplyPurpose;

  /// No description provided for @visitorApplyPurposeHint.
  ///
  /// In zh, this message translates to:
  /// **'请说明来访目的'**
  String get visitorApplyPurposeHint;

  /// No description provided for @visitorApplyVehicle.
  ///
  /// In zh, this message translates to:
  /// **'是否开车'**
  String get visitorApplyVehicle;

  /// No description provided for @visitorApplyPlate.
  ///
  /// In zh, this message translates to:
  /// **'车牌号'**
  String get visitorApplyPlate;

  /// No description provided for @visitorApplyPlateHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入车牌号'**
  String get visitorApplyPlateHint;

  /// No description provided for @visitorApplyHost.
  ///
  /// In zh, this message translates to:
  /// **'接待人'**
  String get visitorApplyHost;

  /// No description provided for @visitorApplyVisitTime.
  ///
  /// In zh, this message translates to:
  /// **'计划到访时间'**
  String get visitorApplyVisitTime;

  /// No description provided for @visitorApplySubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交预约'**
  String get visitorApplySubmit;

  /// No description provided for @visitorApplySubmitting.
  ///
  /// In zh, this message translates to:
  /// **'提交中…'**
  String get visitorApplySubmitting;

  /// No description provided for @visitorApplyValidateName.
  ///
  /// In zh, this message translates to:
  /// **'请输入姓名'**
  String get visitorApplyValidateName;

  /// No description provided for @visitorApplyValidateIdCard.
  ///
  /// In zh, this message translates to:
  /// **'请输入正确的 18 位居民身份证号'**
  String get visitorApplyValidateIdCard;

  /// No description provided for @visitorApplyValidatePurpose.
  ///
  /// In zh, this message translates to:
  /// **'请填写来访事由'**
  String get visitorApplyValidatePurpose;

  /// No description provided for @visitorApplyValidateHost.
  ///
  /// In zh, this message translates to:
  /// **'请选择接待人'**
  String get visitorApplyValidateHost;

  /// No description provided for @visitorApplyValidateVisitTime.
  ///
  /// In zh, this message translates to:
  /// **'请选择到访时间'**
  String get visitorApplyValidateVisitTime;

  /// No description provided for @visitorApplyValidateVisitTimeFuture.
  ///
  /// In zh, this message translates to:
  /// **'到访时间需晚于当前时间'**
  String get visitorApplyValidateVisitTimeFuture;

  /// No description provided for @visitorApplyValidatePlate.
  ///
  /// In zh, this message translates to:
  /// **'开车来访时请填写车牌号'**
  String get visitorApplyValidatePlate;

  /// No description provided for @visitorApplyDuplicateTime.
  ///
  /// In zh, this message translates to:
  /// **'您已有相同时段的进行中预约，请换一个时间'**
  String get visitorApplyDuplicateTime;

  /// No description provided for @visitorApplySuccess.
  ///
  /// In zh, this message translates to:
  /// **'预约已提交，等待审批'**
  String get visitorApplySuccess;

  /// No description provided for @visitorStatusPending.
  ///
  /// In zh, this message translates to:
  /// **'申请中'**
  String get visitorStatusPending;

  /// No description provided for @visitorStatusHostReviewing.
  ///
  /// In zh, this message translates to:
  /// **'待接待人确认'**
  String get visitorStatusHostReviewing;

  /// No description provided for @visitorStatusApproved.
  ///
  /// In zh, this message translates to:
  /// **'已批准'**
  String get visitorStatusApproved;

  /// No description provided for @visitorStatusRejected.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝'**
  String get visitorStatusRejected;

  /// No description provided for @visitorStatusCheckedIn.
  ///
  /// In zh, this message translates to:
  /// **'已签到'**
  String get visitorStatusCheckedIn;

  /// No description provided for @visitorStatusCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get visitorStatusCancelled;

  /// No description provided for @visitorDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'预约详情'**
  String get visitorDetailTitle;

  /// No description provided for @visitorDetailHost.
  ///
  /// In zh, this message translates to:
  /// **'接待人'**
  String get visitorDetailHost;

  /// No description provided for @visitorDetailPurpose.
  ///
  /// In zh, this message translates to:
  /// **'来访事由'**
  String get visitorDetailPurpose;

  /// No description provided for @visitorDetailVisitTime.
  ///
  /// In zh, this message translates to:
  /// **'到访时间'**
  String get visitorDetailVisitTime;

  /// No description provided for @visitorDetailAppliedAt.
  ///
  /// In zh, this message translates to:
  /// **'提交时间'**
  String get visitorDetailAppliedAt;

  /// No description provided for @visitorDetailApprovedAt.
  ///
  /// In zh, this message translates to:
  /// **'批准时间'**
  String get visitorDetailApprovedAt;

  /// No description provided for @visitorDetailRejectReason.
  ///
  /// In zh, this message translates to:
  /// **'拒绝原因'**
  String get visitorDetailRejectReason;

  /// No description provided for @visitorDetailQr.
  ///
  /// In zh, this message translates to:
  /// **'入厂凭证'**
  String get visitorDetailQr;

  /// No description provided for @visitorDetailQrHint.
  ///
  /// In zh, this message translates to:
  /// **'请向保安出示此二维码核验入厂'**
  String get visitorDetailQrHint;

  /// No description provided for @visitorDetailTimeline.
  ///
  /// In zh, this message translates to:
  /// **'审批轨迹'**
  String get visitorDetailTimeline;

  /// No description provided for @visitorLogout.
  ///
  /// In zh, this message translates to:
  /// **'退出访客'**
  String get visitorLogout;

  /// No description provided for @visitorApprovalTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客审批'**
  String get visitorApprovalTitle;

  /// No description provided for @visitorApprovalPending.
  ///
  /// In zh, this message translates to:
  /// **'待审批'**
  String get visitorApprovalPending;

  /// No description provided for @visitorApprovalApprove.
  ///
  /// In zh, this message translates to:
  /// **'批准'**
  String get visitorApprovalApprove;

  /// No description provided for @visitorApprovalReject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get visitorApprovalReject;

  /// No description provided for @visitorApprovalForward.
  ///
  /// In zh, this message translates to:
  /// **'转接待人确认'**
  String get visitorApprovalForward;

  /// No description provided for @visitorApprovalRejectReasonHint.
  ///
  /// In zh, this message translates to:
  /// **'请填写拒绝原因(选填)'**
  String get visitorApprovalRejectReasonHint;

  /// No description provided for @visitorApprovalConfirmApprove.
  ///
  /// In zh, this message translates to:
  /// **'确认批准该访客来访？'**
  String get visitorApprovalConfirmApprove;

  /// No description provided for @visitorApprovalEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无待审批的访客'**
  String get visitorApprovalEmpty;

  /// No description provided for @myVisitorsTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的访客'**
  String get myVisitorsTitle;

  /// No description provided for @myVisitorsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无需要您确认的访客'**
  String get myVisitorsEmpty;

  /// No description provided for @myVisitorsConfirm.
  ///
  /// In zh, this message translates to:
  /// **'同意接待'**
  String get myVisitorsConfirm;

  /// No description provided for @myVisitorsReject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝接待'**
  String get myVisitorsReject;

  /// No description provided for @securityTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客核验'**
  String get securityTitle;

  /// No description provided for @securityScanHint.
  ///
  /// In zh, this message translates to:
  /// **'将访客二维码对准扫码框'**
  String get securityScanHint;

  /// No description provided for @securityScanManual.
  ///
  /// In zh, this message translates to:
  /// **'手动输入凭证'**
  String get securityScanManual;

  /// No description provided for @securityPasscodeHint.
  ///
  /// In zh, this message translates to:
  /// **'输入6位通行码'**
  String get securityPasscodeHint;

  /// No description provided for @securityPasscodeInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入6位数字通行码'**
  String get securityPasscodeInvalid;

  /// No description provided for @visitorPasscodeLabel.
  ///
  /// In zh, this message translates to:
  /// **'通行码'**
  String get visitorPasscodeLabel;

  /// No description provided for @securityPass.
  ///
  /// In zh, this message translates to:
  /// **'允许通行'**
  String get securityPass;

  /// No description provided for @securityReject.
  ///
  /// In zh, this message translates to:
  /// **'禁止通行'**
  String get securityReject;

  /// No description provided for @securityReasonOk.
  ///
  /// In zh, this message translates to:
  /// **'凭证有效'**
  String get securityReasonOk;

  /// No description provided for @securityReasonInvalid.
  ///
  /// In zh, this message translates to:
  /// **'二维码无效'**
  String get securityReasonInvalid;

  /// No description provided for @securityReasonExpired.
  ///
  /// In zh, this message translates to:
  /// **'凭证已过期'**
  String get securityReasonExpired;

  /// No description provided for @securityReasonUsed.
  ///
  /// In zh, this message translates to:
  /// **'该凭证已使用'**
  String get securityReasonUsed;

  /// No description provided for @securityReasonRejected.
  ///
  /// In zh, this message translates to:
  /// **'该访客已被拒绝'**
  String get securityReasonRejected;

  /// No description provided for @securityCheckIn.
  ///
  /// In zh, this message translates to:
  /// **'确认签到'**
  String get securityCheckIn;

  /// No description provided for @securityCheckInDone.
  ///
  /// In zh, this message translates to:
  /// **'签到成功'**
  String get securityCheckInDone;

  /// No description provided for @securityVisitor.
  ///
  /// In zh, this message translates to:
  /// **'访客'**
  String get securityVisitor;

  /// No description provided for @securityPurpose.
  ///
  /// In zh, this message translates to:
  /// **'事由'**
  String get securityPurpose;

  /// No description provided for @securityHost.
  ///
  /// In zh, this message translates to:
  /// **'接待人'**
  String get securityHost;

  /// No description provided for @securityPlate.
  ///
  /// In zh, this message translates to:
  /// **'车牌'**
  String get securityPlate;

  /// No description provided for @securityVisitTime.
  ///
  /// In zh, this message translates to:
  /// **'到访时间'**
  String get securityVisitTime;

  /// No description provided for @employeeTitle.
  ///
  /// In zh, this message translates to:
  /// **'员工档案'**
  String get employeeTitle;

  /// No description provided for @employeeFabOnboard.
  ///
  /// In zh, this message translates to:
  /// **'入职'**
  String get employeeFabOnboard;

  /// No description provided for @employeeSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索工号 / 姓名 / 车牌'**
  String get employeeSearchHint;

  /// No description provided for @employeeEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无员工'**
  String get employeeEmpty;

  /// No description provided for @employeeDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'员工详情'**
  String get employeeDetailTitle;

  /// No description provided for @employeeDetailBasic.
  ///
  /// In zh, this message translates to:
  /// **'基本信息'**
  String get employeeDetailBasic;

  /// No description provided for @employeeDetailOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织与用工'**
  String get employeeDetailOrg;

  /// No description provided for @employeeDetailContract.
  ///
  /// In zh, this message translates to:
  /// **'合同 / 薪资(按权限可见)'**
  String get employeeDetailContract;

  /// No description provided for @employeeDetailEmergency.
  ///
  /// In zh, this message translates to:
  /// **'紧急联系人'**
  String get employeeDetailEmergency;

  /// No description provided for @employeeDetailHistory.
  ///
  /// In zh, this message translates to:
  /// **'任职轨迹'**
  String get employeeDetailHistory;

  /// No description provided for @employeeFieldCode.
  ///
  /// In zh, this message translates to:
  /// **'工号'**
  String get employeeFieldCode;

  /// No description provided for @employeeFieldName.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get employeeFieldName;

  /// No description provided for @employeeFieldGender.
  ///
  /// In zh, this message translates to:
  /// **'性别'**
  String get employeeFieldGender;

  /// No description provided for @employeeFieldIdType.
  ///
  /// In zh, this message translates to:
  /// **'证件类型'**
  String get employeeFieldIdType;

  /// No description provided for @employeeFieldIdNumber.
  ///
  /// In zh, this message translates to:
  /// **'证件号码'**
  String get employeeFieldIdNumber;

  /// No description provided for @employeeFieldBirthDate.
  ///
  /// In zh, this message translates to:
  /// **'出生日期'**
  String get employeeFieldBirthDate;

  /// No description provided for @employeeFieldEthnicity.
  ///
  /// In zh, this message translates to:
  /// **'民族'**
  String get employeeFieldEthnicity;

  /// No description provided for @employeeFieldPoliticalStatus.
  ///
  /// In zh, this message translates to:
  /// **'政治面貌'**
  String get employeeFieldPoliticalStatus;

  /// No description provided for @employeeFieldMaritalStatus.
  ///
  /// In zh, this message translates to:
  /// **'婚姻状况'**
  String get employeeFieldMaritalStatus;

  /// No description provided for @employeeFieldPhone.
  ///
  /// In zh, this message translates to:
  /// **'手机号'**
  String get employeeFieldPhone;

  /// No description provided for @employeeFieldOfficePhone.
  ///
  /// In zh, this message translates to:
  /// **'办公电话'**
  String get employeeFieldOfficePhone;

  /// No description provided for @employeeFieldEmail.
  ///
  /// In zh, this message translates to:
  /// **'企业邮箱'**
  String get employeeFieldEmail;

  /// No description provided for @employeeFieldHujiAddress.
  ///
  /// In zh, this message translates to:
  /// **'户籍地址'**
  String get employeeFieldHujiAddress;

  /// No description provided for @employeeFieldResidenceAddress.
  ///
  /// In zh, this message translates to:
  /// **'现居住地'**
  String get employeeFieldResidenceAddress;

  /// No description provided for @employeeFieldDepartment.
  ///
  /// In zh, this message translates to:
  /// **'所属部门'**
  String get employeeFieldDepartment;

  /// No description provided for @employeeFieldPosition.
  ///
  /// In zh, this message translates to:
  /// **'岗位'**
  String get employeeFieldPosition;

  /// No description provided for @employeeFieldSupervisor.
  ///
  /// In zh, this message translates to:
  /// **'直属上级'**
  String get employeeFieldSupervisor;

  /// No description provided for @employeeFieldHireDate.
  ///
  /// In zh, this message translates to:
  /// **'入职日期'**
  String get employeeFieldHireDate;

  /// No description provided for @employeeFieldWorkYears.
  ///
  /// In zh, this message translates to:
  /// **'工龄'**
  String get employeeFieldWorkYears;

  /// No description provided for @employeeWorkYearsYandM.
  ///
  /// In zh, this message translates to:
  /// **'{years} 年 {months} 个月'**
  String employeeWorkYearsYandM(int years, int months);

  /// No description provided for @employeeWorkYearsMonths.
  ///
  /// In zh, this message translates to:
  /// **'{months} 个月'**
  String employeeWorkYearsMonths(int months);

  /// No description provided for @employeeWorkYearsUnderOneMonth.
  ///
  /// In zh, this message translates to:
  /// **'不足 1 个月'**
  String get employeeWorkYearsUnderOneMonth;

  /// No description provided for @employeeFieldConfirmedDate.
  ///
  /// In zh, this message translates to:
  /// **'转正日期'**
  String get employeeFieldConfirmedDate;

  /// No description provided for @employeeFieldStatus.
  ///
  /// In zh, this message translates to:
  /// **'工作状态'**
  String get employeeFieldStatus;

  /// No description provided for @employeeFieldEmploymentType.
  ///
  /// In zh, this message translates to:
  /// **'用工形式'**
  String get employeeFieldEmploymentType;

  /// No description provided for @employeeFieldWorkLocation.
  ///
  /// In zh, this message translates to:
  /// **'办公地点'**
  String get employeeFieldWorkLocation;

  /// No description provided for @employeeFieldSeatNo.
  ///
  /// In zh, this message translates to:
  /// **'工位号'**
  String get employeeFieldSeatNo;

  /// No description provided for @employeeFieldContractType.
  ///
  /// In zh, this message translates to:
  /// **'合同类型'**
  String get employeeFieldContractType;

  /// No description provided for @employeeFieldContractPeriod.
  ///
  /// In zh, this message translates to:
  /// **'合同起止'**
  String get employeeFieldContractPeriod;

  /// No description provided for @employeeFieldProbation.
  ///
  /// In zh, this message translates to:
  /// **'试用期'**
  String get employeeFieldProbation;

  /// No description provided for @employeeFieldRenewCount.
  ///
  /// In zh, this message translates to:
  /// **'续签次数'**
  String get employeeFieldRenewCount;

  /// No description provided for @employeeFieldBaseSalary.
  ///
  /// In zh, this message translates to:
  /// **'基本工资'**
  String get employeeFieldBaseSalary;

  /// No description provided for @employeeFieldPerfSalary.
  ///
  /// In zh, this message translates to:
  /// **'绩效/补贴'**
  String get employeeFieldPerfSalary;

  /// No description provided for @employeeFieldSocialBase.
  ///
  /// In zh, this message translates to:
  /// **'社保基数'**
  String get employeeFieldSocialBase;

  /// No description provided for @employeeFieldHousingBase.
  ///
  /// In zh, this message translates to:
  /// **'公积金基数'**
  String get employeeFieldHousingBase;

  /// No description provided for @employeeFieldBankBranch.
  ///
  /// In zh, this message translates to:
  /// **'开户银行'**
  String get employeeFieldBankBranch;

  /// No description provided for @employeeFieldBankAccount.
  ///
  /// In zh, this message translates to:
  /// **'银行卡号'**
  String get employeeFieldBankAccount;

  /// No description provided for @employeeContractPeriodValue.
  ///
  /// In zh, this message translates to:
  /// **'{start} ~ {end}'**
  String employeeContractPeriodValue(Object end, Object start);

  /// No description provided for @employeeProbationValue.
  ///
  /// In zh, this message translates to:
  /// **'{months} 个月(至 {end})'**
  String employeeProbationValue(Object end, Object months);

  /// No description provided for @employeeRenewCountValue.
  ///
  /// In zh, this message translates to:
  /// **'{count}'**
  String employeeRenewCountValue(Object count);

  /// No description provided for @employeeFieldAccountStatus.
  ///
  /// In zh, this message translates to:
  /// **'登录账号'**
  String get employeeFieldAccountStatus;

  /// No description provided for @accountStatusActive.
  ///
  /// In zh, this message translates to:
  /// **'正常'**
  String get accountStatusActive;

  /// No description provided for @accountStatusLocked.
  ///
  /// In zh, this message translates to:
  /// **'已锁定'**
  String get accountStatusLocked;

  /// No description provided for @accountStatusDisabled.
  ///
  /// In zh, this message translates to:
  /// **'已停用'**
  String get accountStatusDisabled;

  /// No description provided for @accountStatusNone.
  ///
  /// In zh, this message translates to:
  /// **'未开通'**
  String get accountStatusNone;

  /// No description provided for @employeeProbationExpiring.
  ///
  /// In zh, this message translates to:
  /// **'试用期将于 {date} 到期(剩 {days} 天)，请及时办理转正'**
  String employeeProbationExpiring(Object date, Object days);

  /// No description provided for @employeeProbationExpired.
  ///
  /// In zh, this message translates to:
  /// **'试用期已于 {date} 到期，请尽快办理转正或离职'**
  String employeeProbationExpired(Object date);

  /// No description provided for @employeeContractExpiring.
  ///
  /// In zh, this message translates to:
  /// **'劳动合同将于 {date} 到期(剩 {days} 天)，请及时续签'**
  String employeeContractExpiring(Object date, Object days);

  /// No description provided for @employeeContractExpired.
  ///
  /// In zh, this message translates to:
  /// **'劳动合同已于 {date} 到期，请尽快处理'**
  String employeeContractExpired(Object date);

  /// No description provided for @employeeEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑员工'**
  String get employeeEditTitle;

  /// No description provided for @employeeEditBasic.
  ///
  /// In zh, this message translates to:
  /// **'基本信息'**
  String get employeeEditBasic;

  /// No description provided for @employeeEditOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织信息'**
  String get employeeEditOrg;

  /// No description provided for @employeeEditContact.
  ///
  /// In zh, this message translates to:
  /// **'联系方式'**
  String get employeeEditContact;

  /// No description provided for @employeeEditSalary.
  ///
  /// In zh, this message translates to:
  /// **'薪资与银行'**
  String get employeeEditSalary;

  /// No description provided for @employeeEditSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get employeeEditSaved;

  /// No description provided for @employeeEditSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请重试'**
  String get employeeEditSaveFailed;

  /// No description provided for @employeeEditLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败：{error}'**
  String employeeEditLoadFailed(Object error);

  /// No description provided for @employeeEditRequired.
  ///
  /// In zh, this message translates to:
  /// **'必填'**
  String get employeeEditRequired;

  /// No description provided for @employeeOnboardTitle.
  ///
  /// In zh, this message translates to:
  /// **'新员工入职'**
  String get employeeOnboardTitle;

  /// No description provided for @employeeOnboardGroupProfile.
  ///
  /// In zh, this message translates to:
  /// **'档案'**
  String get employeeOnboardGroupProfile;

  /// No description provided for @employeeOnboardGroupOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织'**
  String get employeeOnboardGroupOrg;

  /// No description provided for @employeeOnboardGroupPay.
  ///
  /// In zh, this message translates to:
  /// **'薪资 / 银行(可选，仅 HR/管理员可见)'**
  String get employeeOnboardGroupPay;

  /// No description provided for @employeeOnboardSubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交入职'**
  String get employeeOnboardSubmit;

  /// No description provided for @employeeOnboardSuccess.
  ///
  /// In zh, this message translates to:
  /// **'入职成功，一次性临时密码已交付'**
  String get employeeOnboardSuccess;

  /// No description provided for @employeeOnboardSubmitFailed.
  ///
  /// In zh, this message translates to:
  /// **'提交失败，请重试'**
  String get employeeOnboardSubmitFailed;

  /// No description provided for @employeeOnboardNote.
  ///
  /// In zh, this message translates to:
  /// **'提交后将自动生成工号(UT 前缀)、以手机号作为登录账号，并由系统随机生成一次性临时密码(只显示一次，限时有效)；首次登录必须修改密码。'**
  String get employeeOnboardNote;

  /// No description provided for @employeeOnboardCodeAutoNote.
  ///
  /// In zh, this message translates to:
  /// **'工号提交后自动生成(UT 前缀，唯一递增)'**
  String get employeeOnboardCodeAutoNote;

  /// No description provided for @positionPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择或填写岗位'**
  String get positionPickerTitle;

  /// No description provided for @positionPickerHint.
  ///
  /// In zh, this message translates to:
  /// **'请选择或填写岗位'**
  String get positionPickerHint;

  /// No description provided for @positionPickerDepartmentFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先选择部门'**
  String get positionPickerDepartmentFirst;

  /// No description provided for @positionPickerSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'输入岗位名称、编码或职级'**
  String get positionPickerSearchHint;

  /// No description provided for @positionPickerUseCustom.
  ///
  /// In zh, this message translates to:
  /// **'使用“{name}”作为新岗位'**
  String positionPickerUseCustom(Object name);

  /// No description provided for @positionPickerCustomDescription.
  ///
  /// In zh, this message translates to:
  /// **'确认后将按当前部门保存'**
  String get positionPickerCustomDescription;

  /// No description provided for @positionPickerNoPositions.
  ///
  /// In zh, this message translates to:
  /// **'该部门暂无岗位，可直接填写新岗位'**
  String get positionPickerNoPositions;

  /// No description provided for @positionPickerLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'岗位加载失败，可重试或直接填写新岗位'**
  String get positionPickerLoadFailed;

  /// No description provided for @positionPickerClear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get positionPickerClear;

  /// No description provided for @employeeOnboardCredentialTitle.
  ///
  /// In zh, this message translates to:
  /// **'账号已创建'**
  String get employeeOnboardCredentialTitle;

  /// No description provided for @employeeOnboardCredentialWarning.
  ///
  /// In zh, this message translates to:
  /// **'临时密码只显示这一次。请立即通过安全方式交给员工；关闭后系统不会再次显示或保存明文。'**
  String get employeeOnboardCredentialWarning;

  /// No description provided for @employeeOnboardAccountLabel.
  ///
  /// In zh, this message translates to:
  /// **'登录账号'**
  String get employeeOnboardAccountLabel;

  /// No description provided for @employeeOnboardTemporaryPasswordLabel.
  ///
  /// In zh, this message translates to:
  /// **'一次性临时密码'**
  String get employeeOnboardTemporaryPasswordLabel;

  /// No description provided for @employeeOnboardCopyTemporaryPassword.
  ///
  /// In zh, this message translates to:
  /// **'复制密码'**
  String get employeeOnboardCopyTemporaryPassword;

  /// No description provided for @employeeOnboardTemporaryPasswordCopied.
  ///
  /// In zh, this message translates to:
  /// **'临时密码已复制'**
  String get employeeOnboardTemporaryPasswordCopied;

  /// No description provided for @employeeOnboardCredentialSaved.
  ///
  /// In zh, this message translates to:
  /// **'我已妥善保存'**
  String get employeeOnboardCredentialSaved;

  /// No description provided for @employeeOnboardHintName.
  ///
  /// In zh, this message translates to:
  /// **'张三'**
  String get employeeOnboardHintName;

  /// No description provided for @employeeOnboardHintIdNumber.
  ///
  /// In zh, this message translates to:
  /// **'请输入身份证号'**
  String get employeeOnboardHintIdNumber;

  /// No description provided for @employeeOnboardIdNumberInvalid.
  ///
  /// In zh, this message translates to:
  /// **'身份证号格式不正确'**
  String get employeeOnboardIdNumberInvalid;

  /// No description provided for @employeeOnboardHintPhone.
  ///
  /// In zh, this message translates to:
  /// **'11 位手机号'**
  String get employeeOnboardHintPhone;

  /// No description provided for @employeeOnboardPhoneRequired.
  ///
  /// In zh, this message translates to:
  /// **'手机号不能为空'**
  String get employeeOnboardPhoneRequired;

  /// No description provided for @employeeOnboardPhoneInvalid.
  ///
  /// In zh, this message translates to:
  /// **'手机号格式不正确'**
  String get employeeOnboardPhoneInvalid;

  /// No description provided for @employeeOnboardEmailOptional.
  ///
  /// In zh, this message translates to:
  /// **'可选'**
  String get employeeOnboardEmailOptional;

  /// No description provided for @employeeOnboardHireDateHint.
  ///
  /// In zh, this message translates to:
  /// **'yyyy-MM-dd'**
  String get employeeOnboardHireDateHint;

  /// No description provided for @employeeOnboardPickHireDate.
  ///
  /// In zh, this message translates to:
  /// **'请选择入职日期'**
  String get employeeOnboardPickHireDate;

  /// No description provided for @employeeOnboardPickDepartment.
  ///
  /// In zh, this message translates to:
  /// **'请选择部门'**
  String get employeeOnboardPickDepartment;

  /// No description provided for @employeeOnboardFieldRequired.
  ///
  /// In zh, this message translates to:
  /// **'{field}不能为空'**
  String employeeOnboardFieldRequired(Object field);

  /// No description provided for @employeeOnboardLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get employeeOnboardLoadFailed;

  /// No description provided for @idTypeIdCard.
  ///
  /// In zh, this message translates to:
  /// **'身份证'**
  String get idTypeIdCard;

  /// No description provided for @idTypePassport.
  ///
  /// In zh, this message translates to:
  /// **'护照'**
  String get idTypePassport;

  /// No description provided for @idTypeHmtPermit.
  ///
  /// In zh, this message translates to:
  /// **'港澳台通行证'**
  String get idTypeHmtPermit;

  /// No description provided for @idTypeOther.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get idTypeOther;

  /// No description provided for @employeeOffboardLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get employeeOffboardLoadFailed;

  /// No description provided for @employeeActionTransfer.
  ///
  /// In zh, this message translates to:
  /// **'调岗'**
  String get employeeActionTransfer;

  /// No description provided for @employeeActionConfirm.
  ///
  /// In zh, this message translates to:
  /// **'转正'**
  String get employeeActionConfirm;

  /// No description provided for @employeeActionOffboard.
  ///
  /// In zh, this message translates to:
  /// **'办理离职'**
  String get employeeActionOffboard;

  /// No description provided for @employeeActionRehire.
  ///
  /// In zh, this message translates to:
  /// **'复职'**
  String get employeeActionRehire;

  /// No description provided for @employeeActionProvision.
  ///
  /// In zh, this message translates to:
  /// **'开通登录账号'**
  String get employeeActionProvision;

  /// No description provided for @employeeActionLockAccount.
  ///
  /// In zh, this message translates to:
  /// **'锁定账号'**
  String get employeeActionLockAccount;

  /// No description provided for @employeeActionUnlockAccount.
  ///
  /// In zh, this message translates to:
  /// **'解锁账号'**
  String get employeeActionUnlockAccount;

  /// No description provided for @employeeLockAccountSuccess.
  ///
  /// In zh, this message translates to:
  /// **'账号已锁定'**
  String get employeeLockAccountSuccess;

  /// No description provided for @employeeUnlockAccountSuccess.
  ///
  /// In zh, this message translates to:
  /// **'账号已解锁'**
  String get employeeUnlockAccountSuccess;

  /// No description provided for @employeeProvisionConfirm.
  ///
  /// In zh, this message translates to:
  /// **'将为该员工开通登录账号：账号默认为手机号，初始密码由系统随机生成(只显示一次，限时有效)，首次登录需修改。是否继续？'**
  String get employeeProvisionConfirm;

  /// No description provided for @employeeTransferTitle.
  ///
  /// In zh, this message translates to:
  /// **'员工调岗'**
  String get employeeTransferTitle;

  /// No description provided for @employeeTransferFieldDate.
  ///
  /// In zh, this message translates to:
  /// **'生效日期'**
  String get employeeTransferFieldDate;

  /// No description provided for @employeeTransferFieldRemark.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get employeeTransferFieldRemark;

  /// No description provided for @employeeTransferSuccess.
  ///
  /// In zh, this message translates to:
  /// **'调岗完成'**
  String get employeeTransferSuccess;

  /// No description provided for @employeeConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认转正？'**
  String get employeeConfirmTitle;

  /// No description provided for @employeeConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'登记实际转正日期。试用期员工状态将变为「在职」；已是正式员工的补登转正日期。'**
  String get employeeConfirmBody;

  /// No description provided for @employeeConfirmSuccess.
  ///
  /// In zh, this message translates to:
  /// **'转正完成'**
  String get employeeConfirmSuccess;

  /// No description provided for @employeeRehireTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认复职？'**
  String get employeeRehireTitle;

  /// No description provided for @employeeRehireBody.
  ///
  /// In zh, this message translates to:
  /// **'复职后员工状态将恢复为「在职」，登录账号重新启用。离职时原密码已作废，需请账号支持人员为其重置密码，并把新的临时密码当面交给员工。'**
  String get employeeRehireBody;

  /// No description provided for @employeeRehireSuccess.
  ///
  /// In zh, this message translates to:
  /// **'复职完成'**
  String get employeeRehireSuccess;

  /// No description provided for @employeeStatusActive.
  ///
  /// In zh, this message translates to:
  /// **'在职'**
  String get employeeStatusActive;

  /// No description provided for @employeeStatusProbation.
  ///
  /// In zh, this message translates to:
  /// **'试用'**
  String get employeeStatusProbation;

  /// No description provided for @employeeStatusOnLeave.
  ///
  /// In zh, this message translates to:
  /// **'休假'**
  String get employeeStatusOnLeave;

  /// No description provided for @employeeStatusResigned.
  ///
  /// In zh, this message translates to:
  /// **'离职'**
  String get employeeStatusResigned;

  /// No description provided for @employeeStatusUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get employeeStatusUnknown;

  /// No description provided for @genderMale.
  ///
  /// In zh, this message translates to:
  /// **'男'**
  String get genderMale;

  /// No description provided for @genderFemale.
  ///
  /// In zh, this message translates to:
  /// **'女'**
  String get genderFemale;

  /// No description provided for @employmentTypeRegular.
  ///
  /// In zh, this message translates to:
  /// **'正式'**
  String get employmentTypeRegular;

  /// No description provided for @employmentTypeDispatch.
  ///
  /// In zh, this message translates to:
  /// **'劳务派遣'**
  String get employmentTypeDispatch;

  /// No description provided for @employmentTypeIntern.
  ///
  /// In zh, this message translates to:
  /// **'实习'**
  String get employmentTypeIntern;

  /// No description provided for @employmentTypeOutsource.
  ///
  /// In zh, this message translates to:
  /// **'外包'**
  String get employmentTypeOutsource;

  /// No description provided for @contractTypeFixed.
  ///
  /// In zh, this message translates to:
  /// **'固定期限'**
  String get contractTypeFixed;

  /// No description provided for @contractTypeOpen.
  ///
  /// In zh, this message translates to:
  /// **'无固定期限'**
  String get contractTypeOpen;

  /// No description provided for @contractTypeTask.
  ///
  /// In zh, this message translates to:
  /// **'任务'**
  String get contractTypeTask;

  /// No description provided for @contractTypeIntern.
  ///
  /// In zh, this message translates to:
  /// **'实习'**
  String get contractTypeIntern;

  /// No description provided for @historyEventOnboard.
  ///
  /// In zh, this message translates to:
  /// **'入职'**
  String get historyEventOnboard;

  /// No description provided for @historyEventTransfer.
  ///
  /// In zh, this message translates to:
  /// **'调岗'**
  String get historyEventTransfer;

  /// No description provided for @historyEventResign.
  ///
  /// In zh, this message translates to:
  /// **'离职'**
  String get historyEventResign;

  /// No description provided for @historyEventRehire.
  ///
  /// In zh, this message translates to:
  /// **'复职'**
  String get historyEventRehire;

  /// No description provided for @departmentTitle.
  ///
  /// In zh, this message translates to:
  /// **'部门管理'**
  String get departmentTitle;

  /// No description provided for @departmentEmpty.
  ///
  /// In zh, this message translates to:
  /// **'选择部门'**
  String get departmentEmpty;

  /// No description provided for @departmentEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'点右上角图标打开部门树'**
  String get departmentEmptyHint;

  /// No description provided for @departmentEmptySelect.
  ///
  /// In zh, this message translates to:
  /// **'请选择左侧部门'**
  String get departmentEmptySelect;

  /// No description provided for @departmentTooltipRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get departmentTooltipRefresh;

  /// No description provided for @departmentTooltipTree.
  ///
  /// In zh, this message translates to:
  /// **'部门树'**
  String get departmentTooltipTree;

  /// No description provided for @departmentDialogDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除部门'**
  String get departmentDialogDeleteTitle;

  /// No description provided for @departmentCreate.
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get departmentCreate;

  /// No description provided for @departmentDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get departmentDelete;

  /// No description provided for @departmentCreated.
  ///
  /// In zh, this message translates to:
  /// **'已创建'**
  String get departmentCreated;

  /// No description provided for @departmentDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get departmentDeleted;

  /// No description provided for @departmentDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认删除「{name}」？仅无子部门且无员工的叶子部门可删。'**
  String departmentDeleteConfirm(Object name);

  /// No description provided for @departmentLevelAndCode.
  ///
  /// In zh, this message translates to:
  /// **'{level} · 编码 {code}'**
  String departmentLevelAndCode(Object level, Object code);

  /// No description provided for @departmentEmployeesEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该部门(含子部门)暂无员工'**
  String get departmentEmployeesEmpty;

  /// No description provided for @departmentLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get departmentLoadFailed;

  /// No description provided for @payrollGenerateTitle.
  ///
  /// In zh, this message translates to:
  /// **'工资条生成'**
  String get payrollGenerateTitle;

  /// No description provided for @payrollStepScope.
  ///
  /// In zh, this message translates to:
  /// **'选择范围'**
  String get payrollStepScope;

  /// No description provided for @payrollStepItems.
  ///
  /// In zh, this message translates to:
  /// **'配置薪酬项'**
  String get payrollStepItems;

  /// No description provided for @payrollStepPreview.
  ///
  /// In zh, this message translates to:
  /// **'预览计算'**
  String get payrollStepPreview;

  /// No description provided for @payrollStepSubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交审核'**
  String get payrollStepSubmit;

  /// No description provided for @payrollFieldMonth.
  ///
  /// In zh, this message translates to:
  /// **'工资月份'**
  String get payrollFieldMonth;

  /// No description provided for @payrollFieldScope.
  ///
  /// In zh, this message translates to:
  /// **'生成范围'**
  String get payrollFieldScope;

  /// No description provided for @payrollItemOvertime.
  ///
  /// In zh, this message translates to:
  /// **'加班费 (+15%)'**
  String get payrollItemOvertime;

  /// No description provided for @payrollItemBonus.
  ///
  /// In zh, this message translates to:
  /// **'绩效奖金 (+10%)'**
  String get payrollItemBonus;

  /// No description provided for @payrollItemSocial.
  ///
  /// In zh, this message translates to:
  /// **'社保公积金 (-10.5%)'**
  String get payrollItemSocial;

  /// No description provided for @payrollItemTax.
  ///
  /// In zh, this message translates to:
  /// **'个人所得税 (-5%)'**
  String get payrollItemTax;

  /// No description provided for @payrollSubmitNote.
  ///
  /// In zh, this message translates to:
  /// **'提交后将进入财务审核流程，审核通过后由人事发布给员工。'**
  String get payrollSubmitNote;

  /// No description provided for @payrollSubmitButton.
  ///
  /// In zh, this message translates to:
  /// **'提交审核'**
  String get payrollSubmitButton;

  /// No description provided for @payrollNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get payrollNext;

  /// No description provided for @payrollBack.
  ///
  /// In zh, this message translates to:
  /// **'上一步'**
  String get payrollBack;

  /// No description provided for @payrollDeptAll.
  ///
  /// In zh, this message translates to:
  /// **'全员'**
  String get payrollDeptAll;

  /// No description provided for @noticePublishTitle.
  ///
  /// In zh, this message translates to:
  /// **'发布通知'**
  String get noticePublishTitle;

  /// No description provided for @noticePublishPublishButton.
  ///
  /// In zh, this message translates to:
  /// **'发布'**
  String get noticePublishPublishButton;

  /// No description provided for @noticePublishTopPriority.
  ///
  /// In zh, this message translates to:
  /// **'置顶'**
  String get noticePublishTopPriority;

  /// No description provided for @noticePublishTitleHint.
  ///
  /// In zh, this message translates to:
  /// **'通知标题(必填)'**
  String get noticePublishTitleHint;

  /// No description provided for @noticePublishContentHint.
  ///
  /// In zh, this message translates to:
  /// **'通知正文……'**
  String get noticePublishContentHint;

  /// No description provided for @noticePublishScopeTitle.
  ///
  /// In zh, this message translates to:
  /// **'可见范围'**
  String get noticePublishScopeTitle;

  /// No description provided for @noticePublishScopeAll.
  ///
  /// In zh, this message translates to:
  /// **'全员'**
  String get noticePublishScopeAll;

  /// No description provided for @noticePublishScopeAllHint.
  ///
  /// In zh, this message translates to:
  /// **'将通知到全公司所有员工'**
  String get noticePublishScopeAllHint;

  /// No description provided for @noticePublishValidateTitle.
  ///
  /// In zh, this message translates to:
  /// **'请填写标题'**
  String get noticePublishValidateTitle;

  /// No description provided for @noticePublishValidateContent.
  ///
  /// In zh, this message translates to:
  /// **'请填写正文'**
  String get noticePublishValidateContent;

  /// No description provided for @noticePublishConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认发布？'**
  String get noticePublishConfirmTitle;

  /// No description provided for @noticePublishConfirmBodyAll.
  ///
  /// In zh, this message translates to:
  /// **'将通知到全员'**
  String get noticePublishConfirmBodyAll;

  /// No description provided for @noticePublishPublished.
  ///
  /// In zh, this message translates to:
  /// **'通知已发布'**
  String get noticePublishPublished;

  /// No description provided for @noticePublishPublishing.
  ///
  /// In zh, this message translates to:
  /// **'发布中…'**
  String get noticePublishPublishing;

  /// No description provided for @noticePublishContentSection.
  ///
  /// In zh, this message translates to:
  /// **'通知内容'**
  String get noticePublishContentSection;

  /// No description provided for @noticePublishTypeLabel.
  ///
  /// In zh, this message translates to:
  /// **'通知类型'**
  String get noticePublishTypeLabel;

  /// No description provided for @noticePublishTitleLabel.
  ///
  /// In zh, this message translates to:
  /// **'标题'**
  String get noticePublishTitleLabel;

  /// No description provided for @noticePublishContentLabel.
  ///
  /// In zh, this message translates to:
  /// **'正文'**
  String get noticePublishContentLabel;

  /// No description provided for @noticePublishUrgentHint.
  ///
  /// In zh, this message translates to:
  /// **'紧急通知会使用高优先级提醒，请只用于必须立即关注的事项。'**
  String get noticePublishUrgentHint;

  /// No description provided for @noticePublishTopPriorityHint.
  ///
  /// In zh, this message translates to:
  /// **'置顶后会优先显示，并按重要通知提醒接收人。'**
  String get noticePublishTopPriorityHint;

  /// No description provided for @noticePublishScopeSelected.
  ///
  /// In zh, this message translates to:
  /// **'指定范围'**
  String get noticePublishScopeSelected;

  /// No description provided for @noticePublishScopeSelectedHint.
  ///
  /// In zh, this message translates to:
  /// **'部门与人员可以同时选择；部门包含其下级组织，重复接收人会自动去重。'**
  String get noticePublishScopeSelectedHint;

  /// No description provided for @noticePublishDepartmentsLabel.
  ///
  /// In zh, this message translates to:
  /// **'接收部门(可多选)'**
  String get noticePublishDepartmentsLabel;

  /// No description provided for @noticePublishDepartmentsHint.
  ///
  /// In zh, this message translates to:
  /// **'选择一个或多个部门'**
  String get noticePublishDepartmentsHint;

  /// No description provided for @noticePublishEmployeesLabel.
  ///
  /// In zh, this message translates to:
  /// **'单独添加人员'**
  String get noticePublishEmployeesLabel;

  /// No description provided for @noticePublishEmployeesHint.
  ///
  /// In zh, this message translates to:
  /// **'选择指定人员(可多选)'**
  String get noticePublishEmployeesHint;

  /// No description provided for @noticePublishEmployeePickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择接收人员'**
  String get noticePublishEmployeePickerTitle;

  /// No description provided for @noticePublishEmployeeSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索姓名 / 工号'**
  String get noticePublishEmployeeSearchHint;

  /// No description provided for @noticePublishEmployeeEmpty.
  ///
  /// In zh, this message translates to:
  /// **'未找到可接收通知的在职账号'**
  String get noticePublishEmployeeEmpty;

  /// No description provided for @noticePublishEmployeeSelectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 人'**
  String noticePublishEmployeeSelectedCount(int count);

  /// No description provided for @noticePublishEmployeeClear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get noticePublishEmployeeClear;

  /// No description provided for @noticePublishEmployeeConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get noticePublishEmployeeConfirm;

  /// No description provided for @noticePublishValidateAudience.
  ///
  /// In zh, this message translates to:
  /// **'请至少选择一个部门或人员'**
  String get noticePublishValidateAudience;

  /// No description provided for @noticePublishAudienceSummary.
  ///
  /// In zh, this message translates to:
  /// **'已选 {departmentCount} 个部门、{employeeCount} 人'**
  String noticePublishAudienceSummary(
    Object departmentCount,
    Object employeeCount,
  );

  /// No description provided for @noticePublishAudienceRecalculateHint.
  ///
  /// In zh, this message translates to:
  /// **'发布前会按当前组织与账号状态重新核算实际接收人数。'**
  String get noticePublishAudienceRecalculateHint;

  /// No description provided for @noticePublishConfirmAudience.
  ///
  /// In zh, this message translates to:
  /// **'将发送给 {summary}，实际接收 {count} 人。'**
  String noticePublishConfirmAudience(Object summary, Object count);

  /// No description provided for @noticePublishPublishedTo.
  ///
  /// In zh, this message translates to:
  /// **'通知已发布给 {count} 人'**
  String noticePublishPublishedTo(Object count);

  /// No description provided for @noticeTypeAnnouncement.
  ///
  /// In zh, this message translates to:
  /// **'公告'**
  String get noticeTypeAnnouncement;

  /// No description provided for @noticeTypePolicy.
  ///
  /// In zh, this message translates to:
  /// **'制度'**
  String get noticeTypePolicy;

  /// No description provided for @noticeTypeBenefit.
  ///
  /// In zh, this message translates to:
  /// **'福利'**
  String get noticeTypeBenefit;

  /// No description provided for @noticeTypeSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统'**
  String get noticeTypeSystem;

  /// No description provided for @noticeTypeUrgent.
  ///
  /// In zh, this message translates to:
  /// **'紧急'**
  String get noticeTypeUrgent;

  /// No description provided for @noticeTypeBirthday.
  ///
  /// In zh, this message translates to:
  /// **'生日'**
  String get noticeTypeBirthday;

  /// No description provided for @noticeTypeAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'入职周年'**
  String get noticeTypeAnniversary;

  /// No description provided for @noticeTypeWedding.
  ///
  /// In zh, this message translates to:
  /// **'新婚'**
  String get noticeTypeWedding;

  /// No description provided for @noticeTypeNewborn.
  ///
  /// In zh, this message translates to:
  /// **'新生儿'**
  String get noticeTypeNewborn;

  /// No description provided for @noticeTypeAnnouncementDesc.
  ///
  /// In zh, this message translates to:
  /// **'公司公告，全员可「点击收到」'**
  String get noticeTypeAnnouncementDesc;

  /// No description provided for @noticeTypePolicyDesc.
  ///
  /// In zh, this message translates to:
  /// **'制度发布，全员可「点击收到」'**
  String get noticeTypePolicyDesc;

  /// No description provided for @noticeTypeBenefitDesc.
  ///
  /// In zh, this message translates to:
  /// **'福利通知，全员可「点击收到」'**
  String get noticeTypeBenefitDesc;

  /// No description provided for @noticeTypeSystemDesc.
  ///
  /// In zh, this message translates to:
  /// **'系统通知，全员可「点击收到」'**
  String get noticeTypeSystemDesc;

  /// No description provided for @noticeTypeUrgentDesc.
  ///
  /// In zh, this message translates to:
  /// **'紧急通知，高优先级强提醒'**
  String get noticeTypeUrgentDesc;

  /// No description provided for @noticeTypeBirthdayDesc.
  ///
  /// In zh, this message translates to:
  /// **'为同事庆生，大家可「送上祝福」'**
  String get noticeTypeBirthdayDesc;

  /// No description provided for @noticeTypeAnniversaryDesc.
  ///
  /// In zh, this message translates to:
  /// **'入职周年纪念，大家可「送上祝福」'**
  String get noticeTypeAnniversaryDesc;

  /// No description provided for @noticeTypeWeddingDesc.
  ///
  /// In zh, this message translates to:
  /// **'新婚祝福，大家可「送上祝福」'**
  String get noticeTypeWeddingDesc;

  /// No description provided for @noticeTypeNewbornDesc.
  ///
  /// In zh, this message translates to:
  /// **'喜添新丁，大家可「送上祝福」'**
  String get noticeTypeNewbornDesc;

  /// No description provided for @noticeGroupBroadcast.
  ///
  /// In zh, this message translates to:
  /// **'公告广播'**
  String get noticeGroupBroadcast;

  /// No description provided for @noticeGroupCelebration.
  ///
  /// In zh, this message translates to:
  /// **'庆典祝福'**
  String get noticeGroupCelebration;

  /// No description provided for @noticeInteractionReceive.
  ///
  /// In zh, this message translates to:
  /// **'收到'**
  String get noticeInteractionReceive;

  /// No description provided for @noticeInteractionReceived.
  ///
  /// In zh, this message translates to:
  /// **'已收到'**
  String get noticeInteractionReceived;

  /// No description provided for @noticeClickToReceive.
  ///
  /// In zh, this message translates to:
  /// **'点击收到'**
  String get noticeClickToReceive;

  /// No description provided for @noticeAckCount.
  ///
  /// In zh, this message translates to:
  /// **'{count}人已收到'**
  String noticeAckCount(int count);

  /// No description provided for @noticeAckYouAndCount.
  ///
  /// In zh, this message translates to:
  /// **'你已收到 · 共 {count} 人收到'**
  String noticeAckYouAndCount(int count);

  /// No description provided for @noticeSendBlessing.
  ///
  /// In zh, this message translates to:
  /// **'送上祝福'**
  String get noticeSendBlessing;

  /// No description provided for @noticeBlessingSent.
  ///
  /// In zh, this message translates to:
  /// **'已送祝福'**
  String get noticeBlessingSent;

  /// No description provided for @noticeBlessingCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条祝福'**
  String noticeBlessingCount(int count);

  /// No description provided for @noticeBlessingWall.
  ///
  /// In zh, this message translates to:
  /// **'祝福墙'**
  String get noticeBlessingWall;

  /// No description provided for @noticeBlessingReceivedCount.
  ///
  /// In zh, this message translates to:
  /// **'收到 {count} 条祝福'**
  String noticeBlessingReceivedCount(int count);

  /// No description provided for @noticeBlessingWallEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有祝福，送上第一份祝福吧'**
  String get noticeBlessingWallEmpty;

  /// No description provided for @noticeBlessingPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'写下你的祝福…'**
  String get noticeBlessingPlaceholder;

  /// No description provided for @noticeBlessingSendButton.
  ///
  /// In zh, this message translates to:
  /// **'发送祝福'**
  String get noticeBlessingSendButton;

  /// No description provided for @noticeBlessingSending.
  ///
  /// In zh, this message translates to:
  /// **'发送中…'**
  String get noticeBlessingSending;

  /// No description provided for @noticeBlessingViewAll.
  ///
  /// In zh, this message translates to:
  /// **'查看全部 {count} 条'**
  String noticeBlessingViewAll(int count);

  /// No description provided for @noticeBlessingTemplatesTitle.
  ///
  /// In zh, this message translates to:
  /// **'选一句祝福'**
  String get noticeBlessingTemplatesTitle;

  /// No description provided for @noticeBlessingValidateEmpty.
  ///
  /// In zh, this message translates to:
  /// **'请输入祝福内容'**
  String get noticeBlessingValidateEmpty;

  /// No description provided for @noticeCelebrationSubjectLabel.
  ///
  /// In zh, this message translates to:
  /// **'祝福对象'**
  String get noticeCelebrationSubjectLabel;

  /// No description provided for @noticeCelebrationSubjectHint.
  ///
  /// In zh, this message translates to:
  /// **'选择要祝福的同事'**
  String get noticeCelebrationSubjectHint;

  /// No description provided for @noticeCelebrationSubjectRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择祝福对象'**
  String get noticeCelebrationSubjectRequired;

  /// No description provided for @noticeQuickCelebrationTitle.
  ///
  /// In zh, this message translates to:
  /// **'快捷发布祝福'**
  String get noticeQuickCelebrationTitle;

  /// No description provided for @noticeQuickCelebrationSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'选择类型，系统自动套用模板'**
  String get noticeQuickCelebrationSubtitle;

  /// No description provided for @noticeQuickPublish.
  ///
  /// In zh, this message translates to:
  /// **'发通知'**
  String get noticeQuickPublish;

  /// No description provided for @noticeQuickWedding.
  ///
  /// In zh, this message translates to:
  /// **'新婚'**
  String get noticeQuickWedding;

  /// No description provided for @noticeQuickNewborn.
  ///
  /// In zh, this message translates to:
  /// **'新生儿'**
  String get noticeQuickNewborn;

  /// No description provided for @celebrationPopupBirthday.
  ///
  /// In zh, this message translates to:
  /// **'{name}，今天是你的生日！\n小优祝你生日快乐！'**
  String celebrationPopupBirthday(Object name);

  /// No description provided for @celebrationPopupAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'{name}，今天是你的入职周年！\n小优祝你{label}！'**
  String celebrationPopupAnniversary(Object name, Object label);

  /// No description provided for @celebrationPopupWedding.
  ///
  /// In zh, this message translates to:
  /// **'{name}，新婚大喜！\n小优祝你们百年好合！'**
  String celebrationPopupWedding(Object name);

  /// No description provided for @celebrationPopupNewborn.
  ///
  /// In zh, this message translates to:
  /// **'{name}，恭喜喜添新丁！\n小优祝宝宝健康成长！'**
  String celebrationPopupNewborn(Object name);

  /// No description provided for @celebrationDismiss.
  ///
  /// In zh, this message translates to:
  /// **'谢谢小优'**
  String get celebrationDismiss;

  /// No description provided for @celebrationCardBirthday.
  ///
  /// In zh, this message translates to:
  /// **'今天是 {name} 的生日'**
  String celebrationCardBirthday(Object name);

  /// No description provided for @celebrationCardAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'今天是 {name} 的{label}'**
  String celebrationCardAnniversary(Object name, Object label);

  /// No description provided for @celebrationCardWedding.
  ///
  /// In zh, this message translates to:
  /// **'今天是 {name} 的新婚大喜'**
  String celebrationCardWedding(Object name);

  /// No description provided for @celebrationCardNewborn.
  ///
  /// In zh, this message translates to:
  /// **'{name} 喜添新丁'**
  String celebrationCardNewborn(Object name);

  /// No description provided for @celebrationCardWall.
  ///
  /// In zh, this message translates to:
  /// **'查看祝福墙'**
  String get celebrationCardWall;

  /// No description provided for @profileChangeEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'修改个人信息'**
  String get profileChangeEditTitle;

  /// No description provided for @profileChangeEditCta.
  ///
  /// In zh, this message translates to:
  /// **'修改我的信息'**
  String get profileChangeEditCta;

  /// No description provided for @profileChangeFieldDirect.
  ///
  /// In zh, this message translates to:
  /// **'可直接修改'**
  String get profileChangeFieldDirect;

  /// No description provided for @profileChangeFieldReview.
  ///
  /// In zh, this message translates to:
  /// **'需 HR 审核后生效'**
  String get profileChangeFieldReview;

  /// No description provided for @profileChangeFieldHrOnly.
  ///
  /// In zh, this message translates to:
  /// **'请联系人事修改'**
  String get profileChangeFieldHrOnly;

  /// No description provided for @profileChangePasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'为安全起见，请输入当前登录密码'**
  String get profileChangePasswordHint;

  /// No description provided for @profileChangePasswordLabel.
  ///
  /// In zh, this message translates to:
  /// **'当前密码'**
  String get profileChangePasswordLabel;

  /// No description provided for @profileChangePasswordWrong.
  ///
  /// In zh, this message translates to:
  /// **'密码错误，请重试'**
  String get profileChangePasswordWrong;

  /// No description provided for @profileChangeSubmitSuccess.
  ///
  /// In zh, this message translates to:
  /// **'修改已提交，HR 审核后生效'**
  String get profileChangeSubmitSuccess;

  /// No description provided for @profileChangeSubmitApplied.
  ///
  /// In zh, this message translates to:
  /// **'修改已保存'**
  String get profileChangeSubmitApplied;

  /// No description provided for @profileChangeSubmitFailed.
  ///
  /// In zh, this message translates to:
  /// **'提交失败，请稍后重试'**
  String get profileChangeSubmitFailed;

  /// No description provided for @profileChangeConflict.
  ///
  /// In zh, this message translates to:
  /// **'档案已被他人更新，请刷新后再试'**
  String get profileChangeConflict;

  /// No description provided for @profileChangeRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'24h 内已提交过该字段的修改，请等待处理'**
  String get profileChangeRateLimited;

  /// No description provided for @profileChangeListTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的修改申请'**
  String get profileChangeListTitle;

  /// No description provided for @profileChangeListEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无修改申请'**
  String get profileChangeListEmpty;

  /// No description provided for @profileChangeFilterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get profileChangeFilterAll;

  /// No description provided for @profileChangeFilterPending.
  ///
  /// In zh, this message translates to:
  /// **'待审核'**
  String get profileChangeFilterPending;

  /// No description provided for @profileChangeFilterApplied.
  ///
  /// In zh, this message translates to:
  /// **'已生效'**
  String get profileChangeFilterApplied;

  /// No description provided for @profileChangeFilterRejected.
  ///
  /// In zh, this message translates to:
  /// **'已驳回'**
  String get profileChangeFilterRejected;

  /// No description provided for @profileChangeStatusPending.
  ///
  /// In zh, this message translates to:
  /// **'待 HR 审核'**
  String get profileChangeStatusPending;

  /// No description provided for @profileChangeStatusApplied.
  ///
  /// In zh, this message translates to:
  /// **'已生效'**
  String get profileChangeStatusApplied;

  /// No description provided for @profileChangeStatusApproved.
  ///
  /// In zh, this message translates to:
  /// **'已通过'**
  String get profileChangeStatusApproved;

  /// No description provided for @profileChangeStatusRejected.
  ///
  /// In zh, this message translates to:
  /// **'已驳回'**
  String get profileChangeStatusRejected;

  /// No description provided for @profileChangeStatusCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已撤销'**
  String get profileChangeStatusCancelled;

  /// No description provided for @profileChangeCancel.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get profileChangeCancel;

  /// No description provided for @profileChangeCancelledByMe.
  ///
  /// In zh, this message translates to:
  /// **'已由我撤销'**
  String get profileChangeCancelledByMe;

  /// No description provided for @profileChangeBefore.
  ///
  /// In zh, this message translates to:
  /// **'修改前'**
  String get profileChangeBefore;

  /// No description provided for @profileChangeAfter.
  ///
  /// In zh, this message translates to:
  /// **'修改后'**
  String get profileChangeAfter;

  /// No description provided for @profileChangeSubmittedAt.
  ///
  /// In zh, this message translates to:
  /// **'提交时间'**
  String get profileChangeSubmittedAt;

  /// No description provided for @profileChangeReviewer.
  ///
  /// In zh, this message translates to:
  /// **'审核人'**
  String get profileChangeReviewer;

  /// No description provided for @profileChangeReviewComment.
  ///
  /// In zh, this message translates to:
  /// **'审核意见'**
  String get profileChangeReviewComment;

  /// No description provided for @profileChangeDiffTitle.
  ///
  /// In zh, this message translates to:
  /// **'本次修改'**
  String get profileChangeDiffTitle;

  /// No description provided for @profileChangeBatchItems.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 项'**
  String profileChangeBatchItems(Object count);

  /// No description provided for @profileChangeHrQueueTitle.
  ///
  /// In zh, this message translates to:
  /// **'员工修改审批'**
  String get profileChangeHrQueueTitle;

  /// No description provided for @profileChangeHrQueueEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无待审申请'**
  String get profileChangeHrQueueEmpty;

  /// No description provided for @profileChangeReviewApprove.
  ///
  /// In zh, this message translates to:
  /// **'批准'**
  String get profileChangeReviewApprove;

  /// No description provided for @profileChangeReviewReject.
  ///
  /// In zh, this message translates to:
  /// **'驳回'**
  String get profileChangeReviewReject;

  /// No description provided for @profileChangeRejectDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'驳回申请'**
  String get profileChangeRejectDialogTitle;

  /// No description provided for @profileChangeRejectReasonRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写驳回原因'**
  String get profileChangeRejectReasonRequired;

  /// No description provided for @profileChangeRejectReasonHint.
  ///
  /// In zh, this message translates to:
  /// **'请说明驳回原因，员工会看到'**
  String get profileChangeRejectReasonHint;

  /// No description provided for @profileChangeApproveDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认批准？'**
  String get profileChangeApproveDialogTitle;

  /// No description provided for @profileChangeApproveDialogBody.
  ///
  /// In zh, this message translates to:
  /// **'批准后将立即合并到员工档案'**
  String get profileChangeApproveDialogBody;

  /// No description provided for @profileChangeConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get profileChangeConfirm;

  /// No description provided for @profileChangeCancel2.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get profileChangeCancel2;

  /// No description provided for @profileChangeRejectSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已驳回'**
  String get profileChangeRejectSuccess;

  /// No description provided for @profileChangeApproveSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已批准'**
  String get profileChangeApproveSuccess;

  /// No description provided for @profileChangeFieldPhone.
  ///
  /// In zh, this message translates to:
  /// **'手机'**
  String get profileChangeFieldPhone;

  /// No description provided for @profileChangeFieldFullName.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get profileChangeFieldFullName;

  /// No description provided for @profileChangeFieldEmergencyName.
  ///
  /// In zh, this message translates to:
  /// **'紧急联系人姓名'**
  String get profileChangeFieldEmergencyName;

  /// No description provided for @profileChangeFieldEmergencyPhone.
  ///
  /// In zh, this message translates to:
  /// **'紧急联系人电话'**
  String get profileChangeFieldEmergencyPhone;

  /// No description provided for @profileChangeFieldEmergencyRelationship.
  ///
  /// In zh, this message translates to:
  /// **'与本人关系'**
  String get profileChangeFieldEmergencyRelationship;

  /// No description provided for @profilePendingBadge.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项待审'**
  String profilePendingBadge(Object count);

  /// No description provided for @profilePendingSectionTitle.
  ///
  /// In zh, this message translates to:
  /// **'待我审核的修改申请'**
  String get profilePendingSectionTitle;

  /// No description provided for @profilePendingSectionViewAll.
  ///
  /// In zh, this message translates to:
  /// **'全部 →'**
  String get profilePendingSectionViewAll;

  /// No description provided for @profileFieldGroupContact.
  ///
  /// In zh, this message translates to:
  /// **'联系方式'**
  String get profileFieldGroupContact;

  /// No description provided for @profileFieldGroupAddress.
  ///
  /// In zh, this message translates to:
  /// **'地址'**
  String get profileFieldGroupAddress;

  /// No description provided for @profileFieldGroupEmergency.
  ///
  /// In zh, this message translates to:
  /// **'紧急联系人'**
  String get profileFieldGroupEmergency;

  /// No description provided for @profileFieldGroupOrganization.
  ///
  /// In zh, this message translates to:
  /// **'组织信息'**
  String get profileFieldGroupOrganization;

  /// No description provided for @profileEditPolicyHint.
  ///
  /// In zh, this message translates to:
  /// **'绿色「可直接修改」提交后立即生效；黄色「需 HR 审核」由人事核对后生效；其余字段由人事统一维护。'**
  String get profileEditPolicyHint;

  /// No description provided for @profileEditPendingConflictHint.
  ///
  /// In zh, this message translates to:
  /// **'你有 {count} 条待审申请；相关字段在审核通过前再次修改，可能与在途申请冲突。'**
  String profileEditPendingConflictHint(int count);

  /// No description provided for @profileEditFieldAction.
  ///
  /// In zh, this message translates to:
  /// **'修改'**
  String get profileEditFieldAction;

  /// No description provided for @profileFieldWorkLocation.
  ///
  /// In zh, this message translates to:
  /// **'工作地'**
  String get profileFieldWorkLocation;

  /// No description provided for @profileFieldSeatNo.
  ///
  /// In zh, this message translates to:
  /// **'工位'**
  String get profileFieldSeatNo;

  /// No description provided for @profileFieldOfficePhone.
  ///
  /// In zh, this message translates to:
  /// **'办公电话'**
  String get profileFieldOfficePhone;

  /// No description provided for @profileFieldEmail.
  ///
  /// In zh, this message translates to:
  /// **'邮箱'**
  String get profileFieldEmail;

  /// No description provided for @profileFieldResidenceAddress.
  ///
  /// In zh, this message translates to:
  /// **'现住址'**
  String get profileFieldResidenceAddress;

  /// No description provided for @profileFieldHujiAddress.
  ///
  /// In zh, this message translates to:
  /// **'户籍地址'**
  String get profileFieldHujiAddress;

  /// No description provided for @profileFieldEthnicity.
  ///
  /// In zh, this message translates to:
  /// **'民族'**
  String get profileFieldEthnicity;

  /// No description provided for @profileFieldPoliticalStatus.
  ///
  /// In zh, this message translates to:
  /// **'政治面貌'**
  String get profileFieldPoliticalStatus;

  /// No description provided for @profileFieldMaritalStatus.
  ///
  /// In zh, this message translates to:
  /// **'婚姻状况'**
  String get profileFieldMaritalStatus;

  /// No description provided for @profileFieldBirthDate.
  ///
  /// In zh, this message translates to:
  /// **'出生日期'**
  String get profileFieldBirthDate;

  /// No description provided for @profileFieldGender.
  ///
  /// In zh, this message translates to:
  /// **'性别'**
  String get profileFieldGender;

  /// 未启用单据卡片上的角标
  ///
  /// In zh, this message translates to:
  /// **'未启用'**
  String get hubDisabledChip;

  /// No description provided for @hubSectionTaskCenter.
  ///
  /// In zh, this message translates to:
  /// **'任务中心'**
  String get hubSectionTaskCenter;

  /// 明细报表共享副标题：一行一货品
  ///
  /// In zh, this message translates to:
  /// **'一行一货品'**
  String get hubSubDetailPerItem;

  /// 汇总报表共享副标题：一行一整单
  ///
  /// In zh, this message translates to:
  /// **'一行一单'**
  String get hubSubSummaryPerDoc;

  /// No description provided for @hubSubPendingReturnQty.
  ///
  /// In zh, this message translates to:
  /// **'待入库的退货量'**
  String get hubSubPendingReturnQty;

  /// No description provided for @hubSubReadOnlyPlan.
  ///
  /// In zh, this message translates to:
  /// **'计划只读'**
  String get hubSubReadOnlyPlan;

  /// No description provided for @salesHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'销售管理'**
  String get salesHubTitle;

  /// No description provided for @salesHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'销售报表'**
  String get salesHubSectionReports;

  /// No description provided for @salesHubSectionScarcity.
  ///
  /// In zh, this message translates to:
  /// **'稀缺仲裁'**
  String get salesHubSectionScarcity;

  /// No description provided for @salesHubTaskOrderProgress.
  ///
  /// In zh, this message translates to:
  /// **'订单进度查询'**
  String get salesHubTaskOrderProgress;

  /// No description provided for @salesHubTaskOrderProgressSub.
  ///
  /// In zh, this message translates to:
  /// **'出货与完工进度'**
  String get salesHubTaskOrderProgressSub;

  /// No description provided for @salesHubDocQuote.
  ///
  /// In zh, this message translates to:
  /// **'销售报价单'**
  String get salesHubDocQuote;

  /// No description provided for @salesHubDocQuoteSub.
  ///
  /// In zh, this message translates to:
  /// **'报价·有效期'**
  String get salesHubDocQuoteSub;

  /// No description provided for @salesHubDocOrder.
  ///
  /// In zh, this message translates to:
  /// **'销售订货单'**
  String get salesHubDocOrder;

  /// No description provided for @salesHubDocOrderSub.
  ///
  /// In zh, this message translates to:
  /// **'客户下单'**
  String get salesHubDocOrderSub;

  /// No description provided for @salesHubDocShipment.
  ///
  /// In zh, this message translates to:
  /// **'销售出货单'**
  String get salesHubDocShipment;

  /// No description provided for @salesHubDocShipmentSub.
  ///
  /// In zh, this message translates to:
  /// **'发货·立应收'**
  String get salesHubDocShipmentSub;

  /// No description provided for @salesHubDocOtherShipment.
  ///
  /// In zh, this message translates to:
  /// **'其它出货单'**
  String get salesHubDocOtherShipment;

  /// No description provided for @salesHubDocOtherShipmentSub.
  ///
  /// In zh, this message translates to:
  /// **'直接出库'**
  String get salesHubDocOtherShipmentSub;

  /// No description provided for @salesHubDocReturn.
  ///
  /// In zh, this message translates to:
  /// **'销售退货单'**
  String get salesHubDocReturn;

  /// No description provided for @salesHubDocReturnSub.
  ///
  /// In zh, this message translates to:
  /// **'退货·红字应收'**
  String get salesHubDocReturnSub;

  /// No description provided for @salesHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'销售明细报表'**
  String get salesHubReportDetail;

  /// No description provided for @salesHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'销售汇总报表'**
  String get salesHubReportSummary;

  /// No description provided for @salesHubScarcity.
  ///
  /// In zh, this message translates to:
  /// **'稀缺库存让单'**
  String get salesHubScarcity;

  /// No description provided for @salesHubScarcitySub.
  ///
  /// In zh, this message translates to:
  /// **'释放低优先级占用'**
  String get salesHubScarcitySub;

  /// No description provided for @purchaseHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'采购管理'**
  String get purchaseHubTitle;

  /// No description provided for @purchaseHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'采购报表'**
  String get purchaseHubSectionReports;

  /// No description provided for @purchaseHubTaskCenter.
  ///
  /// In zh, this message translates to:
  /// **'采购任务中心'**
  String get purchaseHubTaskCenter;

  /// No description provided for @purchaseHubTaskCenterSub.
  ///
  /// In zh, this message translates to:
  /// **'按供应商拆订货'**
  String get purchaseHubTaskCenterSub;

  /// No description provided for @purchaseHubReturnVendor.
  ///
  /// In zh, this message translates to:
  /// **'待退回供应商'**
  String get purchaseHubReturnVendor;

  /// No description provided for @purchaseHubDocRequest.
  ///
  /// In zh, this message translates to:
  /// **'计划下达的采购申请'**
  String get purchaseHubDocRequest;

  /// No description provided for @purchaseHubDocOrder.
  ///
  /// In zh, this message translates to:
  /// **'采购订货单'**
  String get purchaseHubDocOrder;

  /// No description provided for @purchaseHubDocOrderSub.
  ///
  /// In zh, this message translates to:
  /// **'下单·跟踪到货'**
  String get purchaseHubDocOrderSub;

  /// No description provided for @purchaseHubDocReceipt.
  ///
  /// In zh, this message translates to:
  /// **'采购收货单'**
  String get purchaseHubDocReceipt;

  /// No description provided for @purchaseHubDocReceiptSub.
  ///
  /// In zh, this message translates to:
  /// **'收货·入库'**
  String get purchaseHubDocReceiptSub;

  /// No description provided for @purchaseHubDocReturn.
  ///
  /// In zh, this message translates to:
  /// **'采购退货单'**
  String get purchaseHubDocReturn;

  /// No description provided for @purchaseHubDocReturnSub.
  ///
  /// In zh, this message translates to:
  /// **'退货·出库'**
  String get purchaseHubDocReturnSub;

  /// No description provided for @purchaseHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'采购明细报表'**
  String get purchaseHubReportDetail;

  /// No description provided for @purchaseHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'采购汇总报表'**
  String get purchaseHubReportSummary;

  /// No description provided for @purchaseHubReportExpediting.
  ///
  /// In zh, this message translates to:
  /// **'采购催料单'**
  String get purchaseHubReportExpediting;

  /// No description provided for @purchaseHubReportExpeditingSub.
  ///
  /// In zh, this message translates to:
  /// **'订货未收·库存'**
  String get purchaseHubReportExpeditingSub;

  /// No description provided for @subcontractHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'委外管理'**
  String get subcontractHubTitle;

  /// No description provided for @subcontractHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'委外报表'**
  String get subcontractHubSectionReports;

  /// No description provided for @subcontractHubTaskCenter.
  ///
  /// In zh, this message translates to:
  /// **'委外任务中心'**
  String get subcontractHubTaskCenter;

  /// No description provided for @subcontractHubTaskCenterSub.
  ///
  /// In zh, this message translates to:
  /// **'按委外商拆订货'**
  String get subcontractHubTaskCenterSub;

  /// No description provided for @subcontractHubReturnVendor.
  ///
  /// In zh, this message translates to:
  /// **'待退回供应商'**
  String get subcontractHubReturnVendor;

  /// No description provided for @subcontractHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'委外明细报表'**
  String get subcontractHubReportDetail;

  /// No description provided for @subcontractHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'委外汇总报表'**
  String get subcontractHubReportSummary;

  /// No description provided for @subcontractHubReportInOut.
  ///
  /// In zh, this message translates to:
  /// **'委外出入状况表'**
  String get subcontractHubReportInOut;

  /// No description provided for @subcontractHubReportInOutSub.
  ///
  /// In zh, this message translates to:
  /// **'进出综合状况'**
  String get subcontractHubReportInOutSub;

  /// No description provided for @productionHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'生产管理'**
  String get productionHubTitle;

  /// No description provided for @productionHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'生产报表'**
  String get productionHubSectionReports;

  /// No description provided for @productionHubSchedule.
  ///
  /// In zh, this message translates to:
  /// **'生产调度与进度'**
  String get productionHubSchedule;

  /// No description provided for @productionHubScheduleSub.
  ///
  /// In zh, this message translates to:
  /// **'待排产·在产·完工'**
  String get productionHubScheduleSub;

  /// No description provided for @productionHubPlan.
  ///
  /// In zh, this message translates to:
  /// **'新建生产计划单'**
  String get productionHubPlan;

  /// No description provided for @productionHubPlanSub.
  ///
  /// In zh, this message translates to:
  /// **'手工新建排产计划，可引用销售订单'**
  String get productionHubPlanSub;

  /// No description provided for @productionHubPlanHistory.
  ///
  /// In zh, this message translates to:
  /// **'生产计划历史'**
  String get productionHubPlanHistory;

  /// No description provided for @productionHubPlanHistorySub.
  ///
  /// In zh, this message translates to:
  /// **'查看计划、审批与分批记录'**
  String get productionHubPlanHistorySub;

  /// No description provided for @productionHubMaterialAnalysis.
  ///
  /// In zh, this message translates to:
  /// **'物料分析准备'**
  String get productionHubMaterialAnalysis;

  /// No description provided for @productionHubDaily.
  ///
  /// In zh, this message translates to:
  /// **'生产日报表'**
  String get productionHubDaily;

  /// No description provided for @productionHubDailySub.
  ///
  /// In zh, this message translates to:
  /// **'完工日报·红冲'**
  String get productionHubDailySub;

  /// No description provided for @productionHubReportPlanDetail.
  ///
  /// In zh, this message translates to:
  /// **'计划明细'**
  String get productionHubReportPlanDetail;

  /// No description provided for @productionHubReportPlanDetailSub.
  ///
  /// In zh, this message translates to:
  /// **'日期·货品·状态'**
  String get productionHubReportPlanDetailSub;

  /// No description provided for @productionHubReportPlanSummary.
  ///
  /// In zh, this message translates to:
  /// **'计划汇总'**
  String get productionHubReportPlanSummary;

  /// No description provided for @productionHubReportPlanSummarySub.
  ///
  /// In zh, this message translates to:
  /// **'单号·制单·审核'**
  String get productionHubReportPlanSummarySub;

  /// No description provided for @productionHubWhereUsed.
  ///
  /// In zh, this message translates to:
  /// **'物料反查产成品'**
  String get productionHubWhereUsed;

  /// No description provided for @productionHubWhereUsedSub.
  ///
  /// In zh, this message translates to:
  /// **'材料用在哪些产品'**
  String get productionHubWhereUsedSub;

  /// No description provided for @financeHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'钱流管理'**
  String get financeHubTitle;

  /// No description provided for @financeHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'钱流报表'**
  String get financeHubSectionReports;

  /// No description provided for @financeHubTaskApproval.
  ///
  /// In zh, this message translates to:
  /// **'订货审批任务中心'**
  String get financeHubTaskApproval;

  /// No description provided for @financeSalesAllQueueLabel.
  ///
  /// In zh, this message translates to:
  /// **'销售订单财务确认'**
  String get financeSalesAllQueueLabel;

  /// No description provided for @financeSalesInitialQueueLabel.
  ///
  /// In zh, this message translates to:
  /// **'销售订单首次财务确认'**
  String get financeSalesInitialQueueLabel;

  /// No description provided for @financeSalesChangesQueueLabel.
  ///
  /// In zh, this message translates to:
  /// **'销售订单修改'**
  String get financeSalesChangesQueueLabel;

  /// No description provided for @financeSalesQueueCountLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载{queue}待办数量'**
  String financeSalesQueueCountLoading(String queue);

  /// No description provided for @financeSalesQueueCountFailed.
  ///
  /// In zh, this message translates to:
  /// **'{queue}待办数量加载失败，请进入任务页重试'**
  String financeSalesQueueCountFailed(String queue);

  /// No description provided for @financeSalesQueueCountEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有待处理的{queue}'**
  String financeSalesQueueCountEmpty(String queue);

  /// No description provided for @financeSalesQueueCountPending.
  ///
  /// In zh, this message translates to:
  /// **'待处理{queue}：{count}项'**
  String financeSalesQueueCountPending(String queue, int count);

  /// No description provided for @financeHubTaskApprovalSub.
  ///
  /// In zh, this message translates to:
  /// **'采购与委外订货审批'**
  String get financeHubTaskApprovalSub;

  /// No description provided for @financeHubTaskOverDelivery.
  ///
  /// In zh, this message translates to:
  /// **'超量到货审批'**
  String get financeHubTaskOverDelivery;

  /// No description provided for @financeHubTaskOverDeliverySub.
  ///
  /// In zh, this message translates to:
  /// **'审核超量到货'**
  String get financeHubTaskOverDeliverySub;

  /// No description provided for @financeHubDocReceipt.
  ///
  /// In zh, this message translates to:
  /// **'销售收款'**
  String get financeHubDocReceipt;

  /// No description provided for @financeHubDocReceiptSub.
  ///
  /// In zh, this message translates to:
  /// **'登记客户付款，核对尚未收清的款项'**
  String get financeHubDocReceiptSub;

  /// No description provided for @financeHubDocPayment.
  ///
  /// In zh, this message translates to:
  /// **'采购付款'**
  String get financeHubDocPayment;

  /// No description provided for @financeHubDocPaymentSub.
  ///
  /// In zh, this message translates to:
  /// **'支付供应商欠款，核对付款记录'**
  String get financeHubDocPaymentSub;

  /// No description provided for @financeHubDocExpense.
  ///
  /// In zh, this message translates to:
  /// **'一般费用'**
  String get financeHubDocExpense;

  /// No description provided for @financeHubSubAllocatedByDept.
  ///
  /// In zh, this message translates to:
  /// **'按部门分摊'**
  String get financeHubSubAllocatedByDept;

  /// No description provided for @financeHubDocIncome.
  ///
  /// In zh, this message translates to:
  /// **'其它收入'**
  String get financeHubDocIncome;

  /// No description provided for @financeHubDocBankTransfer.
  ///
  /// In zh, this message translates to:
  /// **'银行存取款'**
  String get financeHubDocBankTransfer;

  /// No description provided for @financeHubDocBankTransferSub.
  ///
  /// In zh, this message translates to:
  /// **'账户之间转账'**
  String get financeHubDocBankTransferSub;

  /// No description provided for @financeHubDocCheck.
  ///
  /// In zh, this message translates to:
  /// **'支票管理'**
  String get financeHubDocCheck;

  /// No description provided for @financeHubDocCheckSub.
  ///
  /// In zh, this message translates to:
  /// **'支票账户视图'**
  String get financeHubDocCheckSub;

  /// No description provided for @financeHubDocAssets.
  ///
  /// In zh, this message translates to:
  /// **'资产与待摊'**
  String get financeHubDocAssets;

  /// No description provided for @financeHubDocAssetsSub.
  ///
  /// In zh, this message translates to:
  /// **'管理资产价值及每月费用'**
  String get financeHubDocAssetsSub;

  /// No description provided for @financeHubReportArAp.
  ///
  /// In zh, this message translates to:
  /// **'应收应付'**
  String get financeHubReportArAp;

  /// No description provided for @financeHubReportArApSub.
  ///
  /// In zh, this message translates to:
  /// **'客户·供应商余额'**
  String get financeHubReportArApSub;

  /// No description provided for @financeHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'明细报表'**
  String get financeHubReportDetail;

  /// No description provided for @financeHubReportDetailSub.
  ///
  /// In zh, this message translates to:
  /// **'收款·付款·费用'**
  String get financeHubReportDetailSub;

  /// No description provided for @financeHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'汇总报表'**
  String get financeHubReportSummary;

  /// No description provided for @financeHubReportSummarySub.
  ///
  /// In zh, this message translates to:
  /// **'收支汇总'**
  String get financeHubReportSummarySub;

  /// No description provided for @financeHubReportStatement.
  ///
  /// In zh, this message translates to:
  /// **'往来对帐单'**
  String get financeHubReportStatement;

  /// No description provided for @financeHubReportStatementSub.
  ///
  /// In zh, this message translates to:
  /// **'客户·供应商对账'**
  String get financeHubReportStatementSub;

  /// No description provided for @financeHubReportAccountFlow.
  ///
  /// In zh, this message translates to:
  /// **'账户流水'**
  String get financeHubReportAccountFlow;

  /// No description provided for @financeHubReportAccountFlowSub.
  ///
  /// In zh, this message translates to:
  /// **'账户进出流水'**
  String get financeHubReportAccountFlowSub;

  /// No description provided for @financeHubReportRecon.
  ///
  /// In zh, this message translates to:
  /// **'对账单'**
  String get financeHubReportRecon;

  /// No description provided for @financeHubReportReconSub.
  ///
  /// In zh, this message translates to:
  /// **'月结对账'**
  String get financeHubReportReconSub;

  /// No description provided for @financeHubReportCost.
  ///
  /// In zh, this message translates to:
  /// **'成本核算'**
  String get financeHubReportCost;

  /// No description provided for @financeHubReportCostSub.
  ///
  /// In zh, this message translates to:
  /// **'产品·销售成本'**
  String get financeHubReportCostSub;

  /// No description provided for @financeHubReportGl.
  ///
  /// In zh, this message translates to:
  /// **'总账报表'**
  String get financeHubReportGl;

  /// No description provided for @financeHubReportGlSub.
  ///
  /// In zh, this message translates to:
  /// **'科目·资产·利润'**
  String get financeHubReportGlSub;

  /// No description provided for @warehouseHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'仓库管理'**
  String get warehouseHubTitle;

  /// No description provided for @warehouseHubSectionDocs.
  ///
  /// In zh, this message translates to:
  /// **'出入库单据'**
  String get warehouseHubSectionDocs;

  /// No description provided for @warehouseHubSectionInventory.
  ///
  /// In zh, this message translates to:
  /// **'库存查询'**
  String get warehouseHubSectionInventory;

  /// No description provided for @warehouseHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'仓库报表'**
  String get warehouseHubSectionReports;

  /// No description provided for @warehouseHubSectionReportsDesc.
  ///
  /// In zh, this message translates to:
  /// **'明细(一行一货品)·汇总(一行一单)'**
  String get warehouseHubSectionReportsDesc;

  /// No description provided for @warehouseHubDocTransfer.
  ///
  /// In zh, this message translates to:
  /// **'仓库调拨'**
  String get warehouseHubDocTransfer;

  /// No description provided for @warehouseHubDocTransferSub.
  ///
  /// In zh, this message translates to:
  /// **'仓库间调拨'**
  String get warehouseHubDocTransferSub;

  /// No description provided for @warehouseHubDocCheck.
  ///
  /// In zh, this message translates to:
  /// **'盘点'**
  String get warehouseHubDocCheck;

  /// No description provided for @warehouseHubDocCheckSub.
  ///
  /// In zh, this message translates to:
  /// **'盘点盈亏'**
  String get warehouseHubDocCheckSub;

  /// No description provided for @warehouseHubInventoryLive.
  ///
  /// In zh, this message translates to:
  /// **'即时库存'**
  String get warehouseHubInventoryLive;

  /// No description provided for @warehouseHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'仓库明细报表'**
  String get warehouseHubReportDetail;

  /// No description provided for @warehouseHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'仓库汇总报表'**
  String get warehouseHubReportSummary;

  /// No description provided for @basicDataHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'基础资料'**
  String get basicDataHubTitle;

  /// No description provided for @basicDataHubGoods.
  ///
  /// In zh, this message translates to:
  /// **'货品资料'**
  String get basicDataHubGoods;

  /// No description provided for @basicDataHubGoodsSub.
  ///
  /// In zh, this message translates to:
  /// **'物料分类树与货品主档'**
  String get basicDataHubGoodsSub;

  /// No description provided for @basicDataHubMould.
  ///
  /// In zh, this message translates to:
  /// **'模具资料'**
  String get basicDataHubMould;

  /// No description provided for @basicDataHubMouldSub.
  ///
  /// In zh, this message translates to:
  /// **'模具系列分类与主档'**
  String get basicDataHubMouldSub;

  /// No description provided for @basicDataHubClient.
  ///
  /// In zh, this message translates to:
  /// **'客户资料'**
  String get basicDataHubClient;

  /// No description provided for @basicDataHubClientSub.
  ///
  /// In zh, this message translates to:
  /// **'客户分类与主档'**
  String get basicDataHubClientSub;

  /// No description provided for @basicDataHubSupplier.
  ///
  /// In zh, this message translates to:
  /// **'供应商资料'**
  String get basicDataHubSupplier;

  /// No description provided for @basicDataHubSupplierSub.
  ///
  /// In zh, this message translates to:
  /// **'供应商分类与主档'**
  String get basicDataHubSupplierSub;

  /// No description provided for @basicDataHubColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色资料'**
  String get basicDataHubColor;

  /// No description provided for @basicDataHubColorSub.
  ///
  /// In zh, this message translates to:
  /// **'颜色主档'**
  String get basicDataHubColorSub;

  /// No description provided for @basicDataHubUnit.
  ///
  /// In zh, this message translates to:
  /// **'基本单位'**
  String get basicDataHubUnit;

  /// No description provided for @basicDataHubUnitSub.
  ///
  /// In zh, this message translates to:
  /// **'计量单位主档'**
  String get basicDataHubUnitSub;

  /// No description provided for @basicDataHubCurrency.
  ///
  /// In zh, this message translates to:
  /// **'币种资料'**
  String get basicDataHubCurrency;

  /// No description provided for @basicDataHubCurrencySub.
  ///
  /// In zh, this message translates to:
  /// **'币种·参考汇率'**
  String get basicDataHubCurrencySub;

  /// No description provided for @basicDataHubWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'仓库资料'**
  String get basicDataHubWarehouse;

  /// No description provided for @basicDataHubWarehouseSub.
  ///
  /// In zh, this message translates to:
  /// **'仓库主档'**
  String get basicDataHubWarehouseSub;

  /// No description provided for @basicDataHubAccount.
  ///
  /// In zh, this message translates to:
  /// **'账户资料'**
  String get basicDataHubAccount;

  /// No description provided for @basicDataHubAccountSub.
  ///
  /// In zh, this message translates to:
  /// **'账户·期初·余额'**
  String get basicDataHubAccountSub;

  /// No description provided for @basicDataHubPaymentStyle.
  ///
  /// In zh, this message translates to:
  /// **'收付款类别'**
  String get basicDataHubPaymentStyle;

  /// No description provided for @basicDataHubPaymentStyleSub.
  ///
  /// In zh, this message translates to:
  /// **'资产负债等六大类'**
  String get basicDataHubPaymentStyleSub;

  /// No description provided for @basicDataHubSettlementMethod.
  ///
  /// In zh, this message translates to:
  /// **'结算方式'**
  String get basicDataHubSettlementMethod;

  /// No description provided for @basicDataHubSettlementMethodSub.
  ///
  /// In zh, this message translates to:
  /// **'结账字典·账期口径'**
  String get basicDataHubSettlementMethodSub;

  /// No description provided for @impersonationSwitchPerson.
  ///
  /// In zh, this message translates to:
  /// **'切换人'**
  String get impersonationSwitchPerson;

  /// No description provided for @impersonationEnterPasswordTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认切换人'**
  String get impersonationEnterPasswordTitle;

  /// No description provided for @impersonationEnterPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'为安全验证，请输入你的登录密码。通过后 15 分钟内可自由切换，无需重复输入。'**
  String get impersonationEnterPasswordHint;

  /// No description provided for @impersonationPasswordLabel.
  ///
  /// In zh, this message translates to:
  /// **'登录密码'**
  String get impersonationPasswordLabel;

  /// No description provided for @impersonationTargetPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择要查看的员工'**
  String get impersonationTargetPickerTitle;

  /// No description provided for @impersonationSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索姓名 / 工号'**
  String get impersonationSearchHint;

  /// No description provided for @impersonationBannerTitle.
  ///
  /// In zh, this message translates to:
  /// **'正在以 {name} 身份查看(只读)'**
  String impersonationBannerTitle(String name);

  /// No description provided for @impersonationBannerSwitch.
  ///
  /// In zh, this message translates to:
  /// **'切换'**
  String get impersonationBannerSwitch;

  /// No description provided for @impersonationBannerExit.
  ///
  /// In zh, this message translates to:
  /// **'退出模拟'**
  String get impersonationBannerExit;

  /// No description provided for @impersonationRemainingMinutes.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {count} 分钟'**
  String impersonationRemainingMinutes(int count);

  /// No description provided for @impersonationWrongPassword.
  ///
  /// In zh, this message translates to:
  /// **'密码错误'**
  String get impersonationWrongPassword;

  /// No description provided for @impersonationExited.
  ///
  /// In zh, this message translates to:
  /// **'已退出模拟身份'**
  String get impersonationExited;

  /// No description provided for @impersonationRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近'**
  String get impersonationRecent;

  /// No description provided for @impersonationNoTargets.
  ///
  /// In zh, this message translates to:
  /// **'暂无可切换的员工'**
  String get impersonationNoTargets;

  /// No description provided for @impersonationStartFailed.
  ///
  /// In zh, this message translates to:
  /// **'切换失败'**
  String get impersonationStartFailed;

  /// No description provided for @exportDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出 Excel'**
  String get exportDialogTitle;

  /// No description provided for @exportPasswordOptionalHint.
  ///
  /// In zh, this message translates to:
  /// **'密码可不填。不填将下载普通 Excel；填写 1–128 位密码则加密文件。'**
  String get exportPasswordOptionalHint;

  /// No description provided for @exportPasswordOptionalLabel.
  ///
  /// In zh, this message translates to:
  /// **'打开密码(可选，1–128 位)'**
  String get exportPasswordOptionalLabel;

  /// No description provided for @exportPasswordConfirmLabel.
  ///
  /// In zh, this message translates to:
  /// **'确认密码'**
  String get exportPasswordConfirmLabel;

  /// No description provided for @exportPasswordTooLong.
  ///
  /// In zh, this message translates to:
  /// **'密码不能超过 128 位'**
  String get exportPasswordTooLong;

  /// No description provided for @exportPasswordMismatch.
  ///
  /// In zh, this message translates to:
  /// **'两次密码不一致'**
  String get exportPasswordMismatch;

  /// No description provided for @exportDownloadPlain.
  ///
  /// In zh, this message translates to:
  /// **'直接下载'**
  String get exportDownloadPlain;

  /// No description provided for @exportDownloadEncrypted.
  ///
  /// In zh, this message translates to:
  /// **'加密下载'**
  String get exportDownloadEncrypted;

  /// No description provided for @exportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导出失败，请稍后重试'**
  String get exportFailed;

  /// No description provided for @exportDownloadStarted.
  ///
  /// In zh, this message translates to:
  /// **'已开始下载 {name}'**
  String exportDownloadStarted(String name);

  /// No description provided for @exportDownloadSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存：{path}'**
  String exportDownloadSaved(String path);

  /// No description provided for @profileLoadingMessage.
  ///
  /// In zh, this message translates to:
  /// **'正在加载员工档案…'**
  String get profileLoadingMessage;

  /// No description provided for @profileLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'员工档案加载失败'**
  String get profileLoadFailed;

  /// No description provided for @profileUnboundTitle.
  ///
  /// In zh, this message translates to:
  /// **'当前账号未绑定员工档案'**
  String get profileUnboundTitle;

  /// No description provided for @profileUnboundDescription.
  ///
  /// In zh, this message translates to:
  /// **'请联系管理员或人事完成账号与员工档案绑定。'**
  String get profileUnboundDescription;

  /// No description provided for @profileSessionUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前未登录或会话不可用'**
  String get profileSessionUnavailable;

  /// No description provided for @profileValueNotProvided.
  ///
  /// In zh, this message translates to:
  /// **'未填写'**
  String get profileValueNotProvided;

  /// No description provided for @profileValueNotRegistered.
  ///
  /// In zh, this message translates to:
  /// **'未登记'**
  String get profileValueNotRegistered;

  /// No description provided for @profileAlternatePhoneLabel.
  ///
  /// In zh, this message translates to:
  /// **'备用手机号'**
  String get profileAlternatePhoneLabel;

  /// No description provided for @profileContractSummaryTitle.
  ///
  /// In zh, this message translates to:
  /// **'合同摘要'**
  String get profileContractSummaryTitle;

  /// No description provided for @profileTabOrgContract.
  ///
  /// In zh, this message translates to:
  /// **'组织与合同'**
  String get profileTabOrgContract;

  /// No description provided for @profileTabContactVehicle.
  ///
  /// In zh, this message translates to:
  /// **'联系与车辆'**
  String get profileTabContactVehicle;

  /// No description provided for @profileTabMyDocuments.
  ///
  /// In zh, this message translates to:
  /// **'我的文件'**
  String get profileTabMyDocuments;

  /// No description provided for @profileEmploymentHistoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'任职记录'**
  String get profileEmploymentHistoryTitle;

  /// No description provided for @profileCompensationBoundaryDescription.
  ///
  /// In zh, this message translates to:
  /// **'薪酬与银行信息不会在“我的”页展示；这是有意设置的隐私边界。本人月度收入请从工资条核对，其他问题请联系授权人事。'**
  String get profileCompensationBoundaryDescription;

  /// No description provided for @profileMissingEmergencyContact.
  ///
  /// In zh, this message translates to:
  /// **'尚未登记紧急联系人，请先联系人事登记；登记后可在这里申请修改。'**
  String get profileMissingEmergencyContact;

  /// No description provided for @historyEventConfirm.
  ///
  /// In zh, this message translates to:
  /// **'转正'**
  String get historyEventConfirm;

  /// No description provided for @accountProvisionPermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'你没有开通账号权限，请联系账号支持人员处理'**
  String get accountProvisionPermissionDenied;

  /// No description provided for @accountProvisionAlreadyExists.
  ///
  /// In zh, this message translates to:
  /// **'该员工已有账号或账号未启用，不能重复开通'**
  String get accountProvisionAlreadyExists;

  /// No description provided for @accountProvisionConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'开通账号确认'**
  String get accountProvisionConfirmTitle;

  /// No description provided for @accountProvisionFailed.
  ///
  /// In zh, this message translates to:
  /// **'开通账号失败，请稍后重试'**
  String get accountProvisionFailed;

  /// No description provided for @accountProvisionInProgress.
  ///
  /// In zh, this message translates to:
  /// **'开通中'**
  String get accountProvisionInProgress;

  /// No description provided for @accountStatusNotProvisioned.
  ///
  /// In zh, this message translates to:
  /// **'未开通账号'**
  String get accountStatusNotProvisioned;

  /// No description provided for @accountStatusInactive.
  ///
  /// In zh, this message translates to:
  /// **'账号未启用'**
  String get accountStatusInactive;

  /// No description provided for @pagePermissionAccountNotProvisionedTitle.
  ///
  /// In zh, this message translates to:
  /// **'此人还未开通账号，暂不能设置权限'**
  String get pagePermissionAccountNotProvisionedTitle;

  /// No description provided for @pagePermissionAccountNotProvisionedCanProvision.
  ///
  /// In zh, this message translates to:
  /// **'请先开通登录账号；一次性凭据确认保存后，将自动加载此人的权限详情。'**
  String get pagePermissionAccountNotProvisionedCanProvision;

  /// No description provided for @pagePermissionAccountNotProvisionedNoAccess.
  ///
  /// In zh, this message translates to:
  /// **'请联系具备“账号支持”权限的人员开通登录账号。'**
  String get pagePermissionAccountNotProvisionedNoAccess;

  /// No description provided for @employeePermissionSettingsTooltip.
  ///
  /// In zh, this message translates to:
  /// **'设置员工权限'**
  String get employeePermissionSettingsTooltip;

  /// No description provided for @employeeAccountNotProvisionedTooltip.
  ///
  /// In zh, this message translates to:
  /// **'该员工未开通账号'**
  String get employeeAccountNotProvisionedTooltip;

  /// No description provided for @employeeResignedCannotProvision.
  ///
  /// In zh, this message translates to:
  /// **'该员工已离职，不能开通登录账号'**
  String get employeeResignedCannotProvision;

  /// No description provided for @employeeAccountNotProvisionedContactSupport.
  ///
  /// In zh, this message translates to:
  /// **'该员工还未开通账号，请联系账号支持人员处理'**
  String get employeeAccountNotProvisionedContactSupport;

  /// No description provided for @materialMainWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'主仓库'**
  String get materialMainWarehouse;

  /// No description provided for @materialWarehouseScopeExplanation.
  ///
  /// In zh, this message translates to:
  /// **'按主仓库合计备料，实际领料由仓库安排。'**
  String get materialWarehouseScopeExplanation;

  /// No description provided for @materialSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'查找产品或物料'**
  String get materialSearchHint;

  /// No description provided for @materialByProduct.
  ///
  /// In zh, this message translates to:
  /// **'按产品看'**
  String get materialByProduct;

  /// No description provided for @materialByMaterial.
  ///
  /// In zh, this message translates to:
  /// **'按物料汇总'**
  String get materialByMaterial;

  /// No description provided for @materialIdentityByMaterial.
  ///
  /// In zh, this message translates to:
  /// **'物料名称'**
  String get materialIdentityByMaterial;

  /// No description provided for @materialIdentityByProduct.
  ///
  /// In zh, this message translates to:
  /// **'物料名称'**
  String get materialIdentityByProduct;

  /// No description provided for @materialRoute.
  ///
  /// In zh, this message translates to:
  /// **'供应方式'**
  String get materialRoute;

  /// No description provided for @materialRequired.
  ///
  /// In zh, this message translates to:
  /// **'需要数量'**
  String get materialRequired;

  /// No description provided for @materialPublicAvailable.
  ///
  /// In zh, this message translates to:
  /// **'可用数量'**
  String get materialPublicAvailable;

  /// No description provided for @materialShortage.
  ///
  /// In zh, this message translates to:
  /// **'还缺数量'**
  String get materialShortage;

  /// No description provided for @materialPhysicalShortageHint.
  ///
  /// In zh, this message translates to:
  /// **'本批需求扣除已覆盖本批的合格物料后仍缺的数量。下达采购、委外或车间计划不会减少实物缺口；合格入库并归属本批后才减少。待补数量另外扣除在途，避免重复下达。'**
  String get materialPhysicalShortageHint;

  /// No description provided for @materialSupplyProgressHint.
  ///
  /// In zh, this message translates to:
  /// **'跟踪下单、财务审批、收货、检验与入库进度；双击行查看明细。下达后仍保留实物缺口，合格入库后更新。'**
  String get materialSupplyProgressHint;

  /// No description provided for @materialToSupply.
  ///
  /// In zh, this message translates to:
  /// **'下单数量'**
  String get materialToSupply;

  /// No description provided for @materialHandle.
  ///
  /// In zh, this message translates to:
  /// **'物料办理'**
  String get materialHandle;

  /// No description provided for @materialAdditionalOrder.
  ///
  /// In zh, this message translates to:
  /// **'追加下单'**
  String get materialAdditionalOrder;

  /// No description provided for @materialProductionWorkshop.
  ///
  /// In zh, this message translates to:
  /// **'生产车间'**
  String get materialProductionWorkshop;

  /// No description provided for @materialResponsible.
  ///
  /// In zh, this message translates to:
  /// **'负责人'**
  String get materialResponsible;

  /// No description provided for @materialFutureSupply.
  ///
  /// In zh, this message translates to:
  /// **'在途未到'**
  String get materialFutureSupply;

  /// No description provided for @materialProgress.
  ///
  /// In zh, this message translates to:
  /// **'进度 / 待办'**
  String get materialProgress;

  /// No description provided for @materialMixedRoutes.
  ///
  /// In zh, this message translates to:
  /// **'多种路线'**
  String get materialMixedRoutes;

  /// No description provided for @materialAggregateSources.
  ///
  /// In zh, this message translates to:
  /// **'{products} 个产品 · {paths} 条路径'**
  String materialAggregateSources(int products, int paths);

  /// No description provided for @materialRouteChangedRetry.
  ///
  /// In zh, this message translates to:
  /// **'分析已更新，请核对当前所选路线后重试'**
  String get materialRouteChangedRetry;

  /// No description provided for @materialWarehouseFacts.
  ///
  /// In zh, this message translates to:
  /// **'仓库与供给明细'**
  String get materialWarehouseFacts;

  /// No description provided for @materialExactStock.
  ///
  /// In zh, this message translates to:
  /// **'本节点合格绑定'**
  String get materialExactStock;

  /// No description provided for @materialPublicStock.
  ///
  /// In zh, this message translates to:
  /// **'公共现货'**
  String get materialPublicStock;

  /// No description provided for @materialClaimedSupply.
  ///
  /// In zh, this message translates to:
  /// **'本节点已采用'**
  String get materialClaimedSupply;

  /// No description provided for @materialTaskBuy.
  ///
  /// In zh, this message translates to:
  /// **'下达采购'**
  String get materialTaskBuy;

  /// No description provided for @materialTaskSubcontract.
  ///
  /// In zh, this message translates to:
  /// **'下达委外'**
  String get materialTaskSubcontract;

  /// No description provided for @materialTaskWorkshop.
  ///
  /// In zh, this message translates to:
  /// **'下达车间'**
  String get materialTaskWorkshop;

  /// No description provided for @materialTaskIssued.
  ///
  /// In zh, this message translates to:
  /// **'已下达'**
  String get materialTaskIssued;

  /// No description provided for @materialTaskBlocked.
  ///
  /// In zh, this message translates to:
  /// **'需处理'**
  String get materialTaskBlocked;

  /// No description provided for @materialTaskEmpty.
  ///
  /// In zh, this message translates to:
  /// **'当前筛选没有任务'**
  String get materialTaskEmpty;

  /// No description provided for @materialTaskBuyHint.
  ///
  /// In zh, this message translates to:
  /// **'按剩余需求下达采购，已下达任务可查看订货、到货和质检进度。'**
  String get materialTaskBuyHint;

  /// No description provided for @materialTaskSubcontractHint.
  ///
  /// In zh, this message translates to:
  /// **'按剩余需求下达委外，有子层物料先形成车间备料任务，进度可继续跟踪。'**
  String get materialTaskSubcontractHint;

  /// No description provided for @materialTaskWorkshopHint.
  ///
  /// In zh, this message translates to:
  /// **'填写数量、车间和负责人后下达；缺料任务先进入待料，齐套并领料后才能开工。'**
  String get materialTaskWorkshopHint;

  /// No description provided for @materialTaskSectionHint.
  ///
  /// In zh, this message translates to:
  /// **'按供应方式集中处理待处理、进行中和需处理任务。'**
  String get materialTaskSectionHint;

  /// No description provided for @materialWarehouseLimit.
  ///
  /// In zh, this message translates to:
  /// **'本次分析最多支持 100 个实际仓库，当前主仓范围超出限制，请调整仓库范围后再分析'**
  String get materialWarehouseLimit;

  /// No description provided for @materialRoutesNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步：还有 {count} 行没选供应方式（红框），在「供应方式」列选好后即自动保存，这些行才能下单。其余行的供应方式已按货品档案自动确认。'**
  String materialRoutesNext(int count);

  /// No description provided for @materialIssueNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步：进入“下达采购 / 下达委外 / 下达车间”，按未下达余量办理并查看已下达进度。'**
  String get materialIssueNext;

  /// No description provided for @materialWorkshopNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步：{count} 个产品可先下达车间。填写数量、车间和负责人；缺料批次等待齐套和领料后开工。'**
  String materialWorkshopNext(int count);

  /// No description provided for @materialRootRoutePending.
  ///
  /// In zh, this message translates to:
  /// **'路线待确认'**
  String get materialRootRoutePending;

  /// No description provided for @materialRootExternalRoute.
  ///
  /// In zh, this message translates to:
  /// **'顶层已选择采购或委外，请到对应入口下达'**
  String get materialRootExternalRoute;

  /// No description provided for @materialRootSupplyCompleted.
  ///
  /// In zh, this message translates to:
  /// **'供料需求已完成'**
  String get materialRootSupplyCompleted;

  /// No description provided for @materialRootOutputHistory.
  ///
  /// In zh, this message translates to:
  /// **'顶层供料交接记录'**
  String get materialRootOutputHistory;

  /// No description provided for @materialRootStockAllocation.
  ///
  /// In zh, this message translates to:
  /// **'现货交接'**
  String get materialRootStockAllocation;

  /// No description provided for @materialRootReceivedSupply.
  ///
  /// In zh, this message translates to:
  /// **'合格到货交接'**
  String get materialRootReceivedSupply;

  /// No description provided for @materialRootOutputReversed.
  ///
  /// In zh, this message translates to:
  /// **'交接已撤回'**
  String get materialRootOutputReversed;

  /// No description provided for @materialSupplyTasksAndReversals.
  ///
  /// In zh, this message translates to:
  /// **'供给任务与撤回记录'**
  String get materialSupplyTasksAndReversals;

  /// No description provided for @materialNotificationReversalReconcile.
  ///
  /// In zh, this message translates to:
  /// **'同步撤回'**
  String get materialNotificationReversalReconcile;

  /// No description provided for @materialRevokeRootStock.
  ///
  /// In zh, this message translates to:
  /// **'撤回现货交接'**
  String get materialRevokeRootStock;

  /// No description provided for @materialRootRevokeFailed.
  ///
  /// In zh, this message translates to:
  /// **'现货交接撤回失败，请刷新后核对'**
  String get materialRootRevokeFailed;

  /// No description provided for @materialRootSupplyProcessed.
  ///
  /// In zh, this message translates to:
  /// **'本批供料已处理，现货交接和追加需求请查看对应记录'**
  String get materialRootSupplyProcessed;

  /// 订货单批准后改量按钮（采购/委外）
  ///
  /// In zh, this message translates to:
  /// **'改量'**
  String get orderChangeQtyButton;

  /// 改量弹窗标题
  ///
  /// In zh, this message translates to:
  /// **'订单改量'**
  String get orderChangeQtyTitle;

  /// 改量弹窗顶部红色警示
  ///
  /// In zh, this message translates to:
  /// **'批准后改量立即生效，并自动重回财务复核；财务将看到修改清单（以前→现在）。驳回不会自动还原数量。'**
  String get orderChangeQtyWarning;

  /// 改量弹窗行内当前数量前缀
  ///
  /// In zh, this message translates to:
  /// **'现 {qty}'**
  String orderChangeQtyCurrent(String qty);

  /// 改量弹窗输入框标签
  ///
  /// In zh, this message translates to:
  /// **'新数量'**
  String get orderChangeQtyNewQty;

  /// 改量弹窗确认按钮
  ///
  /// In zh, this message translates to:
  /// **'确认改量'**
  String get orderChangeQtyConfirm;

  /// 改量行内校验失败提示
  ///
  /// In zh, this message translates to:
  /// **'存在无效数量（必须大于 0），请检查'**
  String get orderChangeQtyInvalid;

  /// 改量成功提示
  ///
  /// In zh, this message translates to:
  /// **'已改量，订货单已重回财务复核'**
  String get orderChangeQtySuccess;

  /// 改量失败提示
  ///
  /// In zh, this message translates to:
  /// **'改量失败，请稍后重试'**
  String get orderChangeQtyFailed;

  /// 修改清单旧行前缀（删除线）
  ///
  /// In zh, this message translates to:
  /// **'以前 {value}'**
  String orderQtyChangeOld(String value);

  /// 修改清单新值前缀（加粗）
  ///
  /// In zh, this message translates to:
  /// **'现在 {value}'**
  String orderQtyChangeNew(String value);

  /// 订货审批任务列表默认状态
  ///
  /// In zh, this message translates to:
  /// **'待财务复核'**
  String get procurementApprovalStatusPending;

  /// 订货审批任务列表改量徽标
  ///
  /// In zh, this message translates to:
  /// **'改后待复核 · 改量 {count} 处'**
  String procurementApprovalStatusChanged(int count);

  /// 订货审批审核详情修改清单卡片标题
  ///
  /// In zh, this message translates to:
  /// **'修改清单 · 改量 {count} 处'**
  String procurementApprovalQtyChangesTitle(int count);

  /// 修改清单卡片说明
  ///
  /// In zh, this message translates to:
  /// **'订货单在财务批准后修改过数量，已自动重回财务复核；请逐行核对 以前→现在 后再复核。'**
  String get procurementApprovalQtyChangesHint;

  /// No description provided for @productionMaterialRecheck.
  ///
  /// In zh, this message translates to:
  /// **'重新核对备料'**
  String get productionMaterialRecheck;

  /// No description provided for @productionMaterialRecheckReady.
  ///
  /// In zh, this message translates to:
  /// **'物料已齐套，请在「我的车间任务」勾选并提交领料；仓库发料完成后再开工。'**
  String get productionMaterialRecheckReady;

  /// No description provided for @productionMaterialRecheckWaiting.
  ///
  /// In zh, this message translates to:
  /// **'已重新检查，当前仍有物料未满足，请核对实际入库和其他任务的预留。'**
  String get productionMaterialRecheckWaiting;

  /// No description provided for @fieldAutofilledReview.
  ///
  /// In zh, this message translates to:
  /// **'已自动带出上次记录或默认值，请核对后使用'**
  String get fieldAutofilledReview;

  /// No description provided for @workflowQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按本行单位填写本次数量，箱、个、千克不要混填；引用来源时不能超过当前可用数量。'**
  String get workflowQuantityHint;

  /// No description provided for @workflowOrderQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按本行单位填写客户订购数量。财务正在审核时不能修改；财务通过后再改会重新送审。'**
  String get workflowOrderQuantityHint;

  /// No description provided for @workflowReturnQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按原出货明细的单位填写实际退回量，不能超过尚可退数量。退回实物审核后先待检，不会直接成为可销售库存。'**
  String get workflowReturnQuantityHint;

  /// No description provided for @workflowPriceHint.
  ///
  /// In zh, this message translates to:
  /// **'单价按本行单位和币种填写，金额随数量重新计算。不要把整行总金额填成单价。'**
  String get workflowPriceHint;

  /// No description provided for @workflowReturnPriceHint.
  ///
  /// In zh, this message translates to:
  /// **'退货贷项在审核时按原发运事实和累计已退金额计算，参考价格不能提高可退金额。'**
  String get workflowReturnPriceHint;

  /// No description provided for @workflowDiscountHint.
  ///
  /// In zh, this message translates to:
  /// **'折扣填小数：1是不打折，0.9是九折；不要填9或90。'**
  String get workflowDiscountHint;

  /// No description provided for @workflowExchangeRateHint.
  ///
  /// In zh, this message translates to:
  /// **'填写1单位原币折合多少本币，最多6位小数。自动带出的汇率也要核对本次单据。'**
  String get workflowExchangeRateHint;

  /// No description provided for @workflowTaxRateHint.
  ///
  /// In zh, this message translates to:
  /// **'填百分数，例如13表示13%；不要填0.13。'**
  String get workflowTaxRateHint;

  /// No description provided for @workflowCurrencyHint.
  ///
  /// In zh, this message translates to:
  /// **'币种决定本行单价和金额的含义；更换前请核对来源单据，不能只改显示名称。'**
  String get workflowCurrencyHint;

  /// No description provided for @workflowSettlementHint.
  ///
  /// In zh, this message translates to:
  /// **'按与供应商约定的结算方式选择。不同供应商、币种或结算条款可能拆成不同订货单。'**
  String get workflowSettlementHint;

  /// No description provided for @workflowWorkshopQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'填写本次交给车间的数量。任务可先下达，但开工和领料仍须满足物料及状态条件。'**
  String get workflowWorkshopQuantityHint;

  /// No description provided for @workflowReportQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按计划行单位填写本次实际完成量，不填累计产量。审核报工后还要经仓库登记、品质检查和入库。'**
  String get workflowReportQuantityHint;

  /// No description provided for @workflowArrivalQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按本行单位填写本次实到数量。少到、多到都按实物登记；超出批准量的部分进入异常处理，不直接计入可用库存。'**
  String get workflowArrivalQuantityHint;

  /// No description provided for @workflowIqcPassHint.
  ///
  /// In zh, this message translates to:
  /// **'只填本次判定合格的数量，与本次不合格量合计不能超过剩余待检量。品质通过后仍需仓库确认入库。'**
  String get workflowIqcPassHint;

  /// No description provided for @workflowIqcFailHint.
  ///
  /// In zh, this message translates to:
  /// **'只填本次判定不合格的数量。它不会进入可用库存，后续还要处理退回、返工或其它处置。'**
  String get workflowIqcFailHint;

  /// No description provided for @workflowPrepaymentAmountHint.
  ///
  /// In zh, this message translates to:
  /// **'填写本次实际收到的预收款，按订单币种计。登记到账只记一次；以后用预收抵扣应收时不会再次记收款。'**
  String get workflowPrepaymentAmountHint;

  /// No description provided for @workflowReceiptAllocationHint.
  ///
  /// In zh, this message translates to:
  /// **'把本次到账款分配到这张应收单，按应收币种填写，不能超过当前可收余额。同一笔到账款不要重复分配。'**
  String get workflowReceiptAllocationHint;

  /// No description provided for @workflowBankFeeHint.
  ///
  /// In zh, this message translates to:
  /// **'填写本次实际银行手续费。到账中已经扣除的费用，不要再作为另付费用重复登记。'**
  String get workflowBankFeeHint;

  /// No description provided for @workflowOtherFeeHint.
  ///
  /// In zh, this message translates to:
  /// **'只填写银行手续费以外的本次费用，并选择对应费用项目；同一笔费用不要重复记录。'**
  String get workflowOtherFeeHint;

  /// No description provided for @workflowReturnReasonHint.
  ///
  /// In zh, this message translates to:
  /// **'写清退货原因和原出货来源。审核退货会形成待处理贷项，实物先待检；退款、换货等客户处理方案须另行确认。'**
  String get workflowReturnReasonHint;

  /// No description provided for @workflowPrepaymentOrderHint.
  ///
  /// In zh, this message translates to:
  /// **'先选这笔预收所属的销售订单，客户和币种会随订单确定；选错时请更换订单。'**
  String get workflowPrepaymentOrderHint;

  /// No description provided for @workflowPrepaymentApplyHint.
  ///
  /// In zh, this message translates to:
  /// **'说明用哪笔预收抵扣哪些欠款及依据。抵扣只调整预收和应收余额，不会再次增加实收现金。'**
  String get workflowPrepaymentApplyHint;

  /// No description provided for @workflowFinanceReviewHint.
  ///
  /// In zh, this message translates to:
  /// **'写下核对结果；订单有修改时先对照修改前后内容。财务确认不等于已经收款、出货或开工。'**
  String get workflowFinanceReviewHint;

  /// No description provided for @workflowFinanceRejectHint.
  ///
  /// In zh, this message translates to:
  /// **'写明哪里不对、需要怎样修改。原因会通知销售，修改后再送财务审核。'**
  String get workflowFinanceRejectHint;

  /// No description provided for @workflowOptionalDetails.
  ///
  /// In zh, this message translates to:
  /// **'补充信息(选填)'**
  String get workflowOptionalDetails;

  /// No description provided for @workflowUnitUnknown.
  ///
  /// In zh, this message translates to:
  /// **'验收单位待核对'**
  String get workflowUnitUnknown;

  /// No description provided for @moneySummaryCustomerPaid.
  ///
  /// In zh, this message translates to:
  /// **'客户已付'**
  String get moneySummaryCustomerPaid;

  /// No description provided for @moneySummaryGrossShipped.
  ///
  /// In zh, this message translates to:
  /// **'已发货金额'**
  String get moneySummaryGrossShipped;

  /// No description provided for @moneySummaryReturned.
  ///
  /// In zh, this message translates to:
  /// **'退货金额'**
  String get moneySummaryReturned;

  /// No description provided for @moneySummaryUnusedReturns.
  ///
  /// In zh, this message translates to:
  /// **'尚未处理的退货金额'**
  String get moneySummaryUnusedReturns;

  /// No description provided for @moneySummaryNetReceivable.
  ///
  /// In zh, this message translates to:
  /// **'当前还需收款'**
  String get moneySummaryNetReceivable;

  /// No description provided for @moneySummaryPendingBalance.
  ///
  /// In zh, this message translates to:
  /// **'客户待处理余额'**
  String get moneySummaryPendingBalance;

  /// No description provided for @moneySummaryFutureShipment.
  ///
  /// In zh, this message translates to:
  /// **'后续发货金额'**
  String get moneySummaryFutureShipment;

  /// No description provided for @moneySummaryExpectedNewCash.
  ///
  /// In zh, this message translates to:
  /// **'预计还需新收'**
  String get moneySummaryExpectedNewCash;

  /// No description provided for @moneySummaryBalanceHint.
  ///
  /// In zh, this message translates to:
  /// **'待处理余额需财务确认抵扣或退款，不表示已退款。'**
  String get moneySummaryBalanceHint;

  /// No description provided for @moneySummaryCollectionHint.
  ///
  /// In zh, this message translates to:
  /// **'按当前应收、后续发货及未使用预收估算，不会自动抵扣或退款。'**
  String get moneySummaryCollectionHint;

  /// No description provided for @moneySummarySourceHint.
  ///
  /// In zh, this message translates to:
  /// **'金额来自已审核单据。客户已付可能含代扣费用，银行实际到账以账户流水为准。'**
  String get moneySummarySourceHint;

  /// No description provided for @moneySummaryUnallocatedHint.
  ///
  /// In zh, this message translates to:
  /// **'部分付款尚未对应到订单，请财务核对。'**
  String get moneySummaryUnallocatedHint;

  /// No description provided for @warehouseArrivalSourceLabel.
  ///
  /// In zh, this message translates to:
  /// **'到货来源'**
  String get warehouseArrivalSourceLabel;

  /// No description provided for @warehouseArrivalSourceAutomatic.
  ///
  /// In zh, this message translates to:
  /// **'自动识别'**
  String get warehouseArrivalSourceAutomatic;

  /// No description provided for @warehouseArrivalSourceNormal.
  ///
  /// In zh, this message translates to:
  /// **'正常到货'**
  String get warehouseArrivalSourceNormal;

  /// No description provided for @warehouseArrivalSourceReplacement.
  ///
  /// In zh, this message translates to:
  /// **'先补退货'**
  String get warehouseArrivalSourceReplacement;

  /// No description provided for @warehouseArrivalSourceHint.
  ///
  /// In zh, this message translates to:
  /// **'只有一种待收来源时，系统自动识别。同时有正常待到货和已退未补数量时，请按这批实物选择。选“先补退货”会先补回已退数量，超出的部分按正常到货处理；免费补回或重新计款由原退货处理结果决定。'**
  String get warehouseArrivalSourceHint;

  /// No description provided for @materialIssuedPlanSyncPending.
  ///
  /// In zh, this message translates to:
  /// **'已下达，计划进度待同步'**
  String get materialIssuedPlanSyncPending;

  /// No description provided for @subcontractPlanIssuedDate.
  ///
  /// In zh, this message translates to:
  /// **'计划下达日期'**
  String get subcontractPlanIssuedDate;

  /// No description provided for @subcontractPlanIssuedDateHint.
  ///
  /// In zh, this message translates to:
  /// **'计划部门首次下达这项委外任务的日期'**
  String get subcontractPlanIssuedDateHint;

  /// No description provided for @serverStatusTitle.
  ///
  /// In zh, this message translates to:
  /// **'服务器状态'**
  String get serverStatusTitle;

  /// No description provided for @serverStatusRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get serverStatusRefresh;

  /// No description provided for @serverStatusAccessRequired.
  ///
  /// In zh, this message translates to:
  /// **'没有服务器状态查看权限'**
  String get serverStatusAccessRequired;

  /// No description provided for @serverStatusResources.
  ///
  /// In zh, this message translates to:
  /// **'运行资源'**
  String get serverStatusResources;

  /// No description provided for @serverStatusStorage.
  ///
  /// In zh, this message translates to:
  /// **'磁盘空间'**
  String get serverStatusStorage;

  /// No description provided for @serverStatusDataProtection.
  ///
  /// In zh, this message translates to:
  /// **'数据库与备份'**
  String get serverStatusDataProtection;

  /// No description provided for @serverStatusOverview.
  ///
  /// In zh, this message translates to:
  /// **'运行总览'**
  String get serverStatusOverview;

  /// No description provided for @serverStatusOverviewHint.
  ///
  /// In zh, this message translates to:
  /// **'根据服务器最近一次采集的数据展示运行情况。'**
  String get serverStatusOverviewHint;

  /// No description provided for @serverStatusCollecting.
  ///
  /// In zh, this message translates to:
  /// **'正在等待服务器采集运行数据。'**
  String get serverStatusCollecting;

  /// No description provided for @serverStatusStale.
  ///
  /// In zh, this message translates to:
  /// **'数据已过期，正在等待新的采集结果。'**
  String get serverStatusStale;

  /// No description provided for @serverStatusRefreshFailed.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法更新。上次数据仅供参考，请稍后刷新。'**
  String get serverStatusRefreshFailed;

  /// No description provided for @serverStatusUpdatedAt.
  ///
  /// In zh, this message translates to:
  /// **'采集时间'**
  String get serverStatusUpdatedAt;

  /// No description provided for @serverStatusEnvironment.
  ///
  /// In zh, this message translates to:
  /// **'运行环境'**
  String get serverStatusEnvironment;

  /// No description provided for @serverStatusVersion.
  ///
  /// In zh, this message translates to:
  /// **'应用版本'**
  String get serverStatusVersion;

  /// No description provided for @serverStatusUptime.
  ///
  /// In zh, this message translates to:
  /// **'已运行'**
  String get serverStatusUptime;

  /// No description provided for @serverStatusPolling.
  ///
  /// In zh, this message translates to:
  /// **'每 {seconds} 秒自动刷新，离开页面后暂停'**
  String serverStatusPolling(int seconds);

  /// No description provided for @serverStatusCpu.
  ///
  /// In zh, this message translates to:
  /// **'处理器(CPU)'**
  String get serverStatusCpu;

  /// No description provided for @serverStatusMemory.
  ///
  /// In zh, this message translates to:
  /// **'系统内存'**
  String get serverStatusMemory;

  /// No description provided for @serverStatusAppMemory.
  ///
  /// In zh, this message translates to:
  /// **'应用内存'**
  String get serverStatusAppMemory;

  /// No description provided for @serverStatusDbPool.
  ///
  /// In zh, this message translates to:
  /// **'数据库连接池'**
  String get serverStatusDbPool;

  /// No description provided for @serverStatusDisk.
  ///
  /// In zh, this message translates to:
  /// **'磁盘'**
  String get serverStatusDisk;

  /// No description provided for @serverStatusUsed.
  ///
  /// In zh, this message translates to:
  /// **'已使用'**
  String get serverStatusUsed;

  /// No description provided for @serverStatusFree.
  ///
  /// In zh, this message translates to:
  /// **'可用空间'**
  String get serverStatusFree;

  /// No description provided for @serverStatusCapacity.
  ///
  /// In zh, this message translates to:
  /// **'总容量'**
  String get serverStatusCapacity;

  /// No description provided for @serverStatusDatabase.
  ///
  /// In zh, this message translates to:
  /// **'数据库'**
  String get serverStatusDatabase;

  /// No description provided for @serverStatusDatabaseHint.
  ///
  /// In zh, this message translates to:
  /// **'查看数据库是否能够响应，以及当前连接数量。'**
  String get serverStatusDatabaseHint;

  /// No description provided for @serverStatusResponse.
  ///
  /// In zh, this message translates to:
  /// **'响应耗时'**
  String get serverStatusResponse;

  /// No description provided for @serverStatusConnections.
  ///
  /// In zh, this message translates to:
  /// **'当前 / 最大连接数'**
  String get serverStatusConnections;

  /// No description provided for @serverStatusBackup.
  ///
  /// In zh, this message translates to:
  /// **'最近备份'**
  String get serverStatusBackup;

  /// No description provided for @serverStatusHours.
  ///
  /// In zh, this message translates to:
  /// **'小时'**
  String get serverStatusHours;

  /// No description provided for @serverStatusLastBackup.
  ///
  /// In zh, this message translates to:
  /// **'最近成功时间'**
  String get serverStatusLastBackup;

  /// No description provided for @serverStatusAttention.
  ///
  /// In zh, this message translates to:
  /// **'需要留意'**
  String get serverStatusAttention;

  /// No description provided for @serverStatusNotCollected.
  ///
  /// In zh, this message translates to:
  /// **'尚未采集到这项数据'**
  String get serverStatusNotCollected;

  /// No description provided for @serverStatusUptimeValue.
  ///
  /// In zh, this message translates to:
  /// **'{days}天 {hours}小时 {minutes}分钟'**
  String serverStatusUptimeValue(int days, int hours, int minutes);

  /// No description provided for @serverStatusThresholdUnknown.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用提醒阈值'**
  String get serverStatusThresholdUnknown;

  /// No description provided for @serverStatusThresholds.
  ///
  /// In zh, this message translates to:
  /// **'黄色提醒 ≥ {warning}；红色告警 ≥ {critical}'**
  String serverStatusThresholds(String warning, String critical);

  /// No description provided for @serverStatusNormal.
  ///
  /// In zh, this message translates to:
  /// **'正常'**
  String get serverStatusNormal;

  /// No description provided for @serverStatusWarning.
  ///
  /// In zh, this message translates to:
  /// **'留意'**
  String get serverStatusWarning;

  /// No description provided for @serverStatusCritical.
  ///
  /// In zh, this message translates to:
  /// **'需处理'**
  String get serverStatusCritical;

  /// No description provided for @serverStatusUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get serverStatusUnknown;

  /// No description provided for @attachmentUploadFormatsHint.
  ///
  /// In zh, this message translates to:
  /// **'支持图片 / PDF / Office / zip / txt，单个不超过 {maxSize}'**
  String attachmentUploadFormatsHint(String maxSize);

  /// No description provided for @attachmentUploadedFile.
  ///
  /// In zh, this message translates to:
  /// **'已上传 {fileName}'**
  String attachmentUploadedFile(String fileName);

  /// No description provided for @attachmentUploadedFiles.
  ///
  /// In zh, this message translates to:
  /// **'已上传 {count} 个文件'**
  String attachmentUploadedFiles(int count);

  /// No description provided for @productionMaterialRecheckHelp.
  ///
  /// In zh, this message translates to:
  /// **'重新核对本任务已合格到货和可用库存；不能代替仓库入库或登记实耗。'**
  String get productionMaterialRecheckHelp;

  /// No description provided for @productionMaterialViewUsage.
  ///
  /// In zh, this message translates to:
  /// **'查看用料记录'**
  String get productionMaterialViewUsage;

  /// No description provided for @systemSettingInvalidInteger.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的非负整数'**
  String get systemSettingInvalidInteger;

  /// No description provided for @systemSettingInvalidValue.
  ///
  /// In zh, this message translates to:
  /// **'设置值超出允许范围'**
  String get systemSettingInvalidValue;

  /// No description provided for @systemSettingEnabled.
  ///
  /// In zh, this message translates to:
  /// **'开启'**
  String get systemSettingEnabled;

  /// No description provided for @systemSettingDisabled.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get systemSettingDisabled;

  /// No description provided for @systemSettingFixFields.
  ///
  /// In zh, this message translates to:
  /// **'请先检查框内标记的设置项'**
  String get systemSettingFixFields;

  /// No description provided for @systemSettingUnsavedRefresh.
  ///
  /// In zh, this message translates to:
  /// **'请先保存或还原修改，再刷新设置'**
  String get systemSettingUnsavedRefresh;

  /// No description provided for @systemSettingEffectTiming.
  ///
  /// In zh, this message translates to:
  /// **'安全阈值在后续操作生效，令牌有效期在下次签发生效；庆典与审计留存在各自的计划任务生效。修改会记录审计并需要账号密码确认。'**
  String get systemSettingEffectTiming;

  /// No description provided for @auditSummaryUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'统计暂不可用，操作记录仍可核查'**
  String get auditSummaryUnavailable;

  /// No description provided for @auditSummaryRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试统计'**
  String get auditSummaryRetry;

  /// No description provided for @auditWorkspaceDescription.
  ///
  /// In zh, this message translates to:
  /// **'按人员与时间查看会话，沿操作记录追溯业务变化。'**
  String get auditWorkspaceDescription;

  /// No description provided for @materialReasonLabel.
  ///
  /// In zh, this message translates to:
  /// **'原因'**
  String get materialReasonLabel;

  /// No description provided for @materialReasonRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写原因'**
  String get materialReasonRequired;

  /// No description provided for @materialReasonTooLong.
  ///
  /// In zh, this message translates to:
  /// **'原因不能超过 {max} 个字符'**
  String materialReasonTooLong(int max);

  /// No description provided for @materialReasonTooShort.
  ///
  /// In zh, this message translates to:
  /// **'原因至少填写 {min} 个字符'**
  String materialReasonTooShort(int min);

  /// No description provided for @auditFiltersTitle.
  ///
  /// In zh, this message translates to:
  /// **'操作类型 · 业务对象 · 事件类型'**
  String get auditFiltersTitle;

  /// No description provided for @warehouseOutboundBatchAction.
  ///
  /// In zh, this message translates to:
  /// **'批量{action}'**
  String warehouseOutboundBatchAction(String action);

  /// No description provided for @warehouseOutboundBatchReview.
  ///
  /// In zh, this message translates to:
  /// **'销售出库批量核对'**
  String get warehouseOutboundBatchReview;

  /// No description provided for @warehouseOutboundBatchHint.
  ///
  /// In zh, this message translates to:
  /// **'请逐项核对所选单据的货品、数量、单位、仓库与实际库位；确认后一次性出库。'**
  String get warehouseOutboundBatchHint;

  /// No description provided for @warehouseOutboundBatchConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认对所选 {count} 张单据执行{action}？'**
  String warehouseOutboundBatchConfirm(String action, int count);

  /// No description provided for @warehouseOutboundBatchStopped.
  ///
  /// In zh, this message translates to:
  /// **'批量作业已停止，请返回刷新核对后重新选择未完成任务。'**
  String get warehouseOutboundBatchStopped;

  /// No description provided for @warehouseOutboundBatchUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未收到明确回执，请返回刷新核对当前状态后再处理。'**
  String get warehouseOutboundBatchUnknown;

  /// No description provided for @warehouseOutboundBatchStale.
  ///
  /// In zh, this message translates to:
  /// **'任务状态或允许动作已变化，请刷新后重新核对。'**
  String get warehouseOutboundBatchStale;

  /// No description provided for @warehouseOutboundBatchEmpty.
  ///
  /// In zh, this message translates to:
  /// **'所选任务已不可办理，请返回刷新任务列表。'**
  String get warehouseOutboundBatchEmpty;

  /// No description provided for @warehouseOutboundBatchResult.
  ///
  /// In zh, this message translates to:
  /// **'处理结果'**
  String get warehouseOutboundBatchResult;

  /// No description provided for @warehouseOutboundBatchDone.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get warehouseOutboundBatchDone;

  /// No description provided for @warehouseOutboundBatchPending.
  ///
  /// In zh, this message translates to:
  /// **'未处理'**
  String get warehouseOutboundBatchPending;

  /// No description provided for @warehouseOutboundBatchFailed.
  ///
  /// In zh, this message translates to:
  /// **'失败，请核对'**
  String get warehouseOutboundBatchFailed;

  /// No description provided for @warehouseOutboundBatchSelection.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 张单据'**
  String warehouseOutboundBatchSelection(int count);

  /// No description provided for @warehouseOutboundBatchReason.
  ///
  /// In zh, this message translates to:
  /// **'处理说明'**
  String get warehouseOutboundBatchReason;

  /// No description provided for @warehouseOutboundConfirmShipment.
  ///
  /// In zh, this message translates to:
  /// **'确认出库'**
  String get warehouseOutboundConfirmShipment;

  /// No description provided for @warehouseOutboundBillNo.
  ///
  /// In zh, this message translates to:
  /// **'出货单号'**
  String get warehouseOutboundBillNo;

  /// No description provided for @warehouseOutboundClient.
  ///
  /// In zh, this message translates to:
  /// **'客户'**
  String get warehouseOutboundClient;

  /// No description provided for @warehouseOutboundStatus.
  ///
  /// In zh, this message translates to:
  /// **'仓库作业'**
  String get warehouseOutboundStatus;

  /// No description provided for @warehouseOutboundLineNo.
  ///
  /// In zh, this message translates to:
  /// **'行号'**
  String get warehouseOutboundLineNo;

  /// No description provided for @warehouseOutboundGoodsCode.
  ///
  /// In zh, this message translates to:
  /// **'货品编码'**
  String get warehouseOutboundGoodsCode;

  /// No description provided for @warehouseOutboundGoodsName.
  ///
  /// In zh, this message translates to:
  /// **'货品名称'**
  String get warehouseOutboundGoodsName;

  /// No description provided for @warehouseOutboundPlaceHint.
  ///
  /// In zh, this message translates to:
  /// **'当前建议库位'**
  String get warehouseOutboundPlaceHint;

  /// No description provided for @warehouseOutboundColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色'**
  String get warehouseOutboundColor;

  /// No description provided for @warehouseOutboundUnit.
  ///
  /// In zh, this message translates to:
  /// **'单位'**
  String get warehouseOutboundUnit;

  /// No description provided for @warehouseOutboundQuantity.
  ///
  /// In zh, this message translates to:
  /// **'出货数量'**
  String get warehouseOutboundQuantity;

  /// No description provided for @warehouseOutboundWeight.
  ///
  /// In zh, this message translates to:
  /// **'重量'**
  String get warehouseOutboundWeight;

  /// No description provided for @warehouseOutboundParcelQuantity.
  ///
  /// In zh, this message translates to:
  /// **'件数'**
  String get warehouseOutboundParcelQuantity;

  /// No description provided for @warehouseOutboundCartonCount.
  ///
  /// In zh, this message translates to:
  /// **'箱数'**
  String get warehouseOutboundCartonCount;

  /// No description provided for @warehouseOutboundClientProductCode.
  ///
  /// In zh, this message translates to:
  /// **'客户产品号'**
  String get warehouseOutboundClientProductCode;

  /// No description provided for @warehouseOutboundClientModel.
  ///
  /// In zh, this message translates to:
  /// **'客户型号'**
  String get warehouseOutboundClientModel;

  /// No description provided for @warehouseOutboundSourceOrder.
  ///
  /// In zh, this message translates to:
  /// **'来源订单'**
  String get warehouseOutboundSourceOrder;

  /// No description provided for @warehouseStockOutboundTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量出库详情'**
  String get warehouseStockOutboundTitle;

  /// No description provided for @warehouseStockOutboundAction.
  ///
  /// In zh, this message translates to:
  /// **'批量出库'**
  String get warehouseStockOutboundAction;

  /// No description provided for @warehouseStockOutboundConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认批量出库'**
  String get warehouseStockOutboundConfirm;

  /// No description provided for @warehouseStockOutboundConfirmMessage.
  ///
  /// In zh, this message translates to:
  /// **'确认对所选 {count} 张单据按表内数量出库？\n每张单据独立审核并扣减实际仓库库存，记录当前员工的审核责任。发生异常时停止后续操作，已成功单据保留结果。'**
  String warehouseStockOutboundConfirmMessage(int count);

  /// No description provided for @warehouseStockOutboundHint.
  ///
  /// In zh, this message translates to:
  /// **'核对货品、出库数量、单位和实际仓库。同一单据的明细一同勾选、整单出库；如需改量，请先返回编辑草稿。'**
  String get warehouseStockOutboundHint;

  /// No description provided for @warehouseStockOutboundLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'出库详情加载失败，请重试。'**
  String get warehouseStockOutboundLoadFailed;

  /// No description provided for @warehouseStockOutboundCompleted.
  ///
  /// In zh, this message translates to:
  /// **'已完成 {count} 张单据出库'**
  String warehouseStockOutboundCompleted(int count);

  /// No description provided for @warehouseStockOutboundDone.
  ///
  /// In zh, this message translates to:
  /// **'已出库'**
  String get warehouseStockOutboundDone;

  /// No description provided for @warehouseStockOutboundUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前不可办理'**
  String get warehouseStockOutboundUnavailable;

  /// No description provided for @warehouseStockOutboundProcessing.
  ///
  /// In zh, this message translates to:
  /// **'正在确认出库'**
  String get warehouseStockOutboundProcessing;

  /// No description provided for @warehouseStockOutboundBillNo.
  ///
  /// In zh, this message translates to:
  /// **'出库单号'**
  String get warehouseStockOutboundBillNo;

  /// No description provided for @warehouseStockOutboundPlace.
  ///
  /// In zh, this message translates to:
  /// **'实际库位号'**
  String get warehouseStockOutboundPlace;

  /// No description provided for @warehouseStockOutboundQuantity.
  ///
  /// In zh, this message translates to:
  /// **'出库数量'**
  String get warehouseStockOutboundQuantity;

  /// No description provided for @warehouseStockOutboundSource.
  ///
  /// In zh, this message translates to:
  /// **'来源单据'**
  String get warehouseStockOutboundSource;

  /// No description provided for @warehouseSubcontractOutboundBatchTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量出库详情'**
  String get warehouseSubcontractOutboundBatchTitle;

  /// No description provided for @warehouseSubcontractOutboundBatchAction.
  ///
  /// In zh, this message translates to:
  /// **'批量出库'**
  String get warehouseSubcontractOutboundBatchAction;

  /// No description provided for @warehouseSubcontractOutboundBatchConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认批量出库'**
  String get warehouseSubcontractOutboundBatchConfirm;

  /// No description provided for @warehouseSubcontractOutboundReviewHint.
  ///
  /// In zh, this message translates to:
  /// **'请逐行核对本次出库数量和实际仓库，再确认出库。'**
  String get warehouseSubcontractOutboundReviewHint;

  /// No description provided for @warehouseSubcontractOutboundBatchHint.
  ///
  /// In zh, this message translates to:
  /// **'明细按整张出库单勾选，本次数量可改小分批出库；某条物料这次不发就填 0(保存时删掉这一行)，整张单都不发请到单张拣货页「退回委外(不发)」。各单独立保存并审核，保留已完成结果；发生异常时暂停，核实后继续尚未执行的单据。'**
  String get warehouseSubcontractOutboundBatchHint;

  /// No description provided for @warehouseSubcontractOutboundDocuments.
  ///
  /// In zh, this message translates to:
  /// **'单据信息'**
  String get warehouseSubcontractOutboundDocuments;

  /// No description provided for @warehouseSubcontractOutboundOrder.
  ///
  /// In zh, this message translates to:
  /// **'来源订单'**
  String get warehouseSubcontractOutboundOrder;

  /// No description provided for @warehouseSubcontractOutboundSupplier.
  ///
  /// In zh, this message translates to:
  /// **'委外商'**
  String get warehouseSubcontractOutboundSupplier;

  /// No description provided for @warehouseSubcontractOutboundWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'发出仓'**
  String get warehouseSubcontractOutboundWarehouse;

  /// No description provided for @warehouseSubcontractOutboundWorker.
  ///
  /// In zh, this message translates to:
  /// **'经办人'**
  String get warehouseSubcontractOutboundWorker;

  /// No description provided for @warehouseSubcontractOutboundDate.
  ///
  /// In zh, this message translates to:
  /// **'出库日期'**
  String get warehouseSubcontractOutboundDate;

  /// No description provided for @warehouseSubcontractOutboundDeliveryDate.
  ///
  /// In zh, this message translates to:
  /// **'交货日期'**
  String get warehouseSubcontractOutboundDeliveryDate;

  /// No description provided for @warehouseSubcontractOutboundGoodsName.
  ///
  /// In zh, this message translates to:
  /// **'货品名称'**
  String get warehouseSubcontractOutboundGoodsName;

  /// No description provided for @warehouseSubcontractOutboundGoodsCode.
  ///
  /// In zh, this message translates to:
  /// **'编号'**
  String get warehouseSubcontractOutboundGoodsCode;

  /// No description provided for @warehouseSubcontractOutboundParentName.
  ///
  /// In zh, this message translates to:
  /// **'回厂交回的委外件'**
  String get warehouseSubcontractOutboundParentName;

  /// No description provided for @warehouseSubcontractOutboundParentCode.
  ///
  /// In zh, this message translates to:
  /// **'委外件编号'**
  String get warehouseSubcontractOutboundParentCode;

  /// No description provided for @warehouseSubcontractOutboundColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色'**
  String get warehouseSubcontractOutboundColor;

  /// No description provided for @warehouseSubcontractOutboundUnit.
  ///
  /// In zh, this message translates to:
  /// **'单位'**
  String get warehouseSubcontractOutboundUnit;

  /// No description provided for @warehouseSubcontractOutboundStockAvailable.
  ///
  /// In zh, this message translates to:
  /// **'仓内可动用'**
  String get warehouseSubcontractOutboundStockAvailable;

  /// No description provided for @warehouseSubcontractOutboundQuantity.
  ///
  /// In zh, this message translates to:
  /// **'本次出库'**
  String get warehouseSubcontractOutboundQuantity;

  /// No description provided for @warehouseSubcontractOutboundPlace.
  ///
  /// In zh, this message translates to:
  /// **'库位号'**
  String get warehouseSubcontractOutboundPlace;

  /// No description provided for @warehouseSubcontractOutboundStatus.
  ///
  /// In zh, this message translates to:
  /// **'处理结果'**
  String get warehouseSubcontractOutboundStatus;

  /// No description provided for @warehouseSubcontractOutboundPending.
  ///
  /// In zh, this message translates to:
  /// **'待出库'**
  String get warehouseSubcontractOutboundPending;

  /// No description provided for @warehouseSubcontractOutboundDone.
  ///
  /// In zh, this message translates to:
  /// **'已出库'**
  String get warehouseSubcontractOutboundDone;

  /// No description provided for @warehouseSubcontractOutboundPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停，请核实'**
  String get warehouseSubcontractOutboundPaused;

  /// No description provided for @warehouseSubcontractOutboundUncertain.
  ///
  /// In zh, this message translates to:
  /// **'回执尚未确定，请刷新核实后再继续。'**
  String get warehouseSubcontractOutboundUncertain;

  /// No description provided for @warehouseSubcontractOutboundChanged.
  ///
  /// In zh, this message translates to:
  /// **'单据已被修改或处理，请返回刷新后重新选择。'**
  String get warehouseSubcontractOutboundChanged;

  /// No description provided for @warehouseSubcontractOutboundSelectRequired.
  ///
  /// In zh, this message translates to:
  /// **'请至少选择一项出库任务。'**
  String get warehouseSubcontractOutboundSelectRequired;

  /// No description provided for @warehouseSubcontractOutboundSelectionLimit.
  ///
  /// In zh, this message translates to:
  /// **'每批最多选择 50 项任务。'**
  String get warehouseSubcontractOutboundSelectionLimit;

  /// No description provided for @warehouseSubcontractOutboundWarehouseRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择发出仓。'**
  String get warehouseSubcontractOutboundWarehouseRequired;

  /// No description provided for @warehouseSubcontractOutboundLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'出库详情加载失败，请重试。'**
  String get warehouseSubcontractOutboundLoadFailed;

  /// No description provided for @warehouseSubcontractOutboundConfirmResponsibility.
  ///
  /// In zh, this message translates to:
  /// **'确认后，系统将以当前登录员工记录本次出库审核责任。'**
  String get warehouseSubcontractOutboundConfirmResponsibility;

  /// No description provided for @warehouseSubcontractOutboundBatchResult.
  ///
  /// In zh, this message translates to:
  /// **'已完成 {done} 项，共 {total} 项。'**
  String warehouseSubcontractOutboundBatchResult(int done, int total);

  /// No description provided for @warehouseSubcontractOutboundContinue.
  ///
  /// In zh, this message translates to:
  /// **'继续未执行项'**
  String get warehouseSubcontractOutboundContinue;

  /// No description provided for @warehouseSubcontractOutboundVerify.
  ///
  /// In zh, this message translates to:
  /// **'核实处理结果'**
  String get warehouseSubcontractOutboundVerify;

  /// No description provided for @warehouseSubcontractOutboundNoLines.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可出库明细'**
  String get warehouseSubcontractOutboundNoLines;

  /// No description provided for @warehouseStockOutboundConfirmSingle.
  ///
  /// In zh, this message translates to:
  /// **'确认出库'**
  String get warehouseStockOutboundConfirmSingle;

  /// No description provided for @warehouseStockOutboundSeries.
  ///
  /// In zh, this message translates to:
  /// **'系列'**
  String get warehouseStockOutboundSeries;

  /// No description provided for @warehouseOutboundBatchDocuments.
  ///
  /// In zh, this message translates to:
  /// **'单据信息'**
  String get warehouseOutboundBatchDocuments;

  /// No description provided for @warehouseOutboundBatchBillDate.
  ///
  /// In zh, this message translates to:
  /// **'业务日期'**
  String get warehouseOutboundBatchBillDate;

  /// No description provided for @warehouseOutboundBatchWorker.
  ///
  /// In zh, this message translates to:
  /// **'经办人'**
  String get warehouseOutboundBatchWorker;

  /// No description provided for @warehouseOutboundBatchMaker.
  ///
  /// In zh, this message translates to:
  /// **'制单员'**
  String get warehouseOutboundBatchMaker;

  /// No description provided for @warehouseOutboundBatchCreatedAt.
  ///
  /// In zh, this message translates to:
  /// **'制单时间'**
  String get warehouseOutboundBatchCreatedAt;

  /// No description provided for @warehouseOutboundBatchUpdatedAt.
  ///
  /// In zh, this message translates to:
  /// **'作业更新'**
  String get warehouseOutboundBatchUpdatedAt;

  /// No description provided for @warehouseSubcontractOutboundDocumentRemark.
  ///
  /// In zh, this message translates to:
  /// **'单据备注'**
  String get warehouseSubcontractOutboundDocumentRemark;

  /// No description provided for @warehouseSubcontractOutboundLineRemark.
  ///
  /// In zh, this message translates to:
  /// **'明细备注'**
  String get warehouseSubcontractOutboundLineRemark;

  /// No description provided for @warehouseSubcontractOutboundWarehouseSyncHint.
  ///
  /// In zh, this message translates to:
  /// **'默认带出原出库单的实际仓库。同一出库单的所有明细共用发出仓，修改后同步更新。'**
  String get warehouseSubcontractOutboundWarehouseSyncHint;

  /// No description provided for @warehouseSubcontractOutboundDocumentRemarkHint.
  ///
  /// In zh, this message translates to:
  /// **'同一出库单共用此备注，修改后在该单所有明细同步显示。单行说明填写在明细备注中。'**
  String get warehouseSubcontractOutboundDocumentRemarkHint;

  /// No description provided for @warehouseSubcontractOutboundOpenPicking.
  ///
  /// In zh, this message translates to:
  /// **'进入拣货出仓'**
  String get warehouseSubcontractOutboundOpenPicking;

  /// No description provided for @warehouseSubcontractOutboundBannerScope.
  ///
  /// In zh, this message translates to:
  /// **'仓库作业视图不含价格与金额, 也不提供委外业务编辑操作。'**
  String get warehouseSubcontractOutboundBannerScope;

  /// No description provided for @warehouseSubcontractOutboundApprove.
  ///
  /// In zh, this message translates to:
  /// **'审核出仓'**
  String get warehouseSubcontractOutboundApprove;

  /// No description provided for @productionBatchTitle.
  ///
  /// In zh, this message translates to:
  /// **'分批生产领料'**
  String get productionBatchTitle;

  /// No description provided for @productionBatchPermission.
  ///
  /// In zh, this message translates to:
  /// **'当前账号没有安排车间分批领料的权限'**
  String get productionBatchPermission;

  /// No description provided for @productionBatchSelectTask.
  ///
  /// In zh, this message translates to:
  /// **'请从我的车间任务选择待料工单'**
  String get productionBatchSelectTask;

  /// No description provided for @productionBatchInvalidQuantity.
  ///
  /// In zh, this message translates to:
  /// **'请输入大于 0 的数量，最多 4 位小数'**
  String get productionBatchInvalidQuantity;

  /// No description provided for @productionBatchPreviewFailed.
  ///
  /// In zh, this message translates to:
  /// **'可生产批量核对失败，请重试'**
  String get productionBatchPreviewFailed;

  /// No description provided for @productionBatchReplay.
  ///
  /// In zh, this message translates to:
  /// **'本批已安排，未重复生成任务'**
  String get productionBatchReplay;

  /// No description provided for @productionBatchSubmittedReuse.
  ///
  /// In zh, this message translates to:
  /// **'已安排本批 {quantity} {unit}，沿用前批已领物料，可回车间任务开工'**
  String productionBatchSubmittedReuse(String quantity, String unit);

  /// No description provided for @productionBatchSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'已提交本批 {quantity} {unit} 领料；剩余 {remaining} {unit} 留待后续安排'**
  String productionBatchSubmitted(
    String quantity,
    String unit,
    String remaining,
  );

  /// No description provided for @productionBatchUncertain.
  ///
  /// In zh, this message translates to:
  /// **'暂未确认本批提交结果，请用“{action}”继续确认。当前批量和汇总已保留。'**
  String productionBatchUncertain(String action);

  /// No description provided for @productionBatchRejected.
  ///
  /// In zh, this message translates to:
  /// **'{message}。请重新核对本批数量和领料汇总。'**
  String productionBatchRejected(String message);

  /// No description provided for @productionBatchRetryRequest.
  ///
  /// In zh, this message translates to:
  /// **'重试本批领料'**
  String get productionBatchRetryRequest;

  /// No description provided for @productionBatchRetryArrange.
  ///
  /// In zh, this message translates to:
  /// **'重试本批安排'**
  String get productionBatchRetryArrange;

  /// No description provided for @productionBatchConfirmRequest.
  ///
  /// In zh, this message translates to:
  /// **'确认本批领料'**
  String get productionBatchConfirmRequest;

  /// No description provided for @productionBatchConfirmArrange.
  ///
  /// In zh, this message translates to:
  /// **'确认本批生产'**
  String get productionBatchConfirmArrange;

  /// No description provided for @productionBatchSubmitting.
  ///
  /// In zh, this message translates to:
  /// **'正在提交本批安排'**
  String get productionBatchSubmitting;

  /// No description provided for @productionBatchSubmittingHint.
  ///
  /// In zh, this message translates to:
  /// **'正在核对本批数量和物料来源，请稍候。'**
  String get productionBatchSubmittingHint;

  /// No description provided for @productionBatchProductFallback.
  ///
  /// In zh, this message translates to:
  /// **'生产产品待确认'**
  String get productionBatchProductFallback;

  /// No description provided for @productionBatchPlan.
  ///
  /// In zh, this message translates to:
  /// **'生产计划'**
  String get productionBatchPlan;

  /// No description provided for @productionBatchWorkOrder.
  ///
  /// In zh, this message translates to:
  /// **'生产工单'**
  String get productionBatchWorkOrder;

  /// No description provided for @productionBatchOriginal.
  ///
  /// In zh, this message translates to:
  /// **'任务待生产'**
  String get productionBatchOriginal;

  /// No description provided for @productionBatchOriginalHint.
  ///
  /// In zh, this message translates to:
  /// **'当前工单的待生产数量'**
  String get productionBatchOriginalHint;

  /// No description provided for @productionBatchReady.
  ///
  /// In zh, this message translates to:
  /// **'当前可齐套上限'**
  String get productionBatchReady;

  /// No description provided for @productionBatchReadyHint.
  ///
  /// In zh, this message translates to:
  /// **'仅按现有合格实物计算'**
  String get productionBatchReadyHint;

  /// No description provided for @productionBatchSelected.
  ///
  /// In zh, this message translates to:
  /// **'本批已核对量'**
  String get productionBatchSelected;

  /// No description provided for @productionBatchSelectedHint.
  ///
  /// In zh, this message translates to:
  /// **'确认后安排的本批数量'**
  String get productionBatchSelectedHint;

  /// No description provided for @productionBatchRemaining.
  ///
  /// In zh, this message translates to:
  /// **'安排后剩余'**
  String get productionBatchRemaining;

  /// No description provided for @productionBatchRemainingHint.
  ///
  /// In zh, this message translates to:
  /// **'留待后续安排'**
  String get productionBatchRemainingHint;

  /// No description provided for @productionBatchUnitUnknown.
  ///
  /// In zh, this message translates to:
  /// **'单位待确认'**
  String get productionBatchUnitUnknown;

  /// No description provided for @productionBatchSetup.
  ///
  /// In zh, this message translates to:
  /// **'本批生产安排'**
  String get productionBatchSetup;

  /// No description provided for @productionBatchQuantity.
  ///
  /// In zh, this message translates to:
  /// **'本次生产数量'**
  String get productionBatchQuantity;

  /// No description provided for @productionBatchQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'最多可安排 {quantity} {unit}。修改后需重新核对领料汇总，再确认提交。'**
  String productionBatchQuantityHint(String quantity, String unit);

  /// No description provided for @productionBatchReview.
  ///
  /// In zh, this message translates to:
  /// **'重新核对领料汇总'**
  String get productionBatchReview;

  /// No description provided for @productionBatchReviewReady.
  ///
  /// In zh, this message translates to:
  /// **'本批已核对'**
  String get productionBatchReviewReady;

  /// No description provided for @productionBatchNeedsReview.
  ///
  /// In zh, this message translates to:
  /// **'数量已修改，需重新核对'**
  String get productionBatchNeedsReview;

  /// No description provided for @productionBatchNeedsReviewHint.
  ///
  /// In zh, this message translates to:
  /// **'下方为上次核对的明细，重新核对后才能确认本批。'**
  String get productionBatchNeedsReviewHint;

  /// No description provided for @productionBatchNoKit.
  ///
  /// In zh, this message translates to:
  /// **'暂不能安排本批'**
  String get productionBatchNoKit;

  /// No description provided for @productionBatchNoKitHint.
  ///
  /// In zh, this message translates to:
  /// **'现有物料尚不能配齐一个生产批次，请等待实际入库后重新核对'**
  String get productionBatchNoKitHint;

  /// No description provided for @productionBatchReuseHint.
  ///
  /// In zh, this message translates to:
  /// **'本批沿用前批已领物料，无需再次领料；确认后回车间任务开工。'**
  String get productionBatchReuseHint;

  /// No description provided for @productionBatchDirectTransferBadge.
  ///
  /// In zh, this message translates to:
  /// **'车间直送 · 自动投入'**
  String get productionBatchDirectTransferBadge;

  /// No description provided for @productionBatchDirectTransferHint.
  ///
  /// In zh, this message translates to:
  /// **'本批物料全部来自本车间直送 (内料仓)：确认后自动投入本批，无需提交领料申请、不等仓库发料；回车间任务直接开工。'**
  String get productionBatchDirectTransferHint;

  /// No description provided for @productionBatchSubmittedDirectTransfer.
  ///
  /// In zh, this message translates to:
  /// **'已安排本批 {quantity} {unit}，直送物料已自动投入，无需领料，可直接开工'**
  String productionBatchSubmittedDirectTransfer(String quantity, String unit);

  /// No description provided for @productionBatchFlow.
  ///
  /// In zh, this message translates to:
  /// **'确认本批领料 → 仓库发齐 → 车间开工'**
  String get productionBatchFlow;

  /// No description provided for @productionBatchRemainingText.
  ///
  /// In zh, this message translates to:
  /// **'本批安排后，剩余 {quantity} {unit} 留待后续安排。'**
  String productionBatchRemainingText(String quantity, String unit);

  /// No description provided for @productionBatchAllRemaining.
  ///
  /// In zh, this message translates to:
  /// **'本批包含当前工单全部待生产数量。'**
  String get productionBatchAllRemaining;

  /// No description provided for @productionBatchMaterials.
  ///
  /// In zh, this message translates to:
  /// **'本批领料明细'**
  String get productionBatchMaterials;

  /// No description provided for @productionBatchMaterialCount.
  ///
  /// In zh, this message translates to:
  /// **'{lines} 行物料 · {warehouses} 个领料仓'**
  String productionBatchMaterialCount(int lines, int warehouses);

  /// No description provided for @productionBatchWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'实际领料仓'**
  String get productionBatchWarehouse;

  /// No description provided for @productionBatchGoodsCode.
  ///
  /// In zh, this message translates to:
  /// **'物料编码'**
  String get productionBatchGoodsCode;

  /// No description provided for @productionBatchGoodsName.
  ///
  /// In zh, this message translates to:
  /// **'物料名称'**
  String get productionBatchGoodsName;

  /// No description provided for @productionBatchColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色'**
  String get productionBatchColor;

  /// No description provided for @productionBatchUnit.
  ///
  /// In zh, this message translates to:
  /// **'领料单位'**
  String get productionBatchUnit;

  /// No description provided for @productionBatchMaterialQuantity.
  ///
  /// In zh, this message translates to:
  /// **'本批领料数量'**
  String get productionBatchMaterialQuantity;

  /// No description provided for @productionBatchMaterialQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'仅为本批需要新增领取的数量，按本行单位和实际仓库办理。'**
  String get productionBatchMaterialQuantityHint;

  /// No description provided for @productionBatchNoAdditionalMaterials.
  ///
  /// In zh, this message translates to:
  /// **'本批无需新增领料，沿已有物料来源安排生产'**
  String get productionBatchNoAdditionalMaterials;

  /// No description provided for @securityReasonBlocked.
  ///
  /// In zh, this message translates to:
  /// **'已拉黑，禁止入场'**
  String get securityReasonBlocked;

  /// No description provided for @securityBlacklistTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客黑名单'**
  String get securityBlacklistTitle;

  /// No description provided for @securityBlacklistEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无拉黑访客'**
  String get securityBlacklistEmpty;

  /// No description provided for @securityBlacklistColNo.
  ///
  /// In zh, this message translates to:
  /// **'访客编号'**
  String get securityBlacklistColNo;

  /// No description provided for @securityBlacklistColName.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get securityBlacklistColName;

  /// No description provided for @securityBlacklistColPhone.
  ///
  /// In zh, this message translates to:
  /// **'手机号'**
  String get securityBlacklistColPhone;

  /// No description provided for @securityBlacklistColReason.
  ///
  /// In zh, this message translates to:
  /// **'拉黑原因'**
  String get securityBlacklistColReason;

  /// No description provided for @securityBlacklistColAt.
  ///
  /// In zh, this message translates to:
  /// **'拉黑时间'**
  String get securityBlacklistColAt;

  /// No description provided for @securityBlacklistColBy.
  ///
  /// In zh, this message translates to:
  /// **'操作人'**
  String get securityBlacklistColBy;

  /// No description provided for @securityBlacklistAction.
  ///
  /// In zh, this message translates to:
  /// **'拉黑访客'**
  String get securityBlacklistAction;

  /// No description provided for @securityBlacklistNoticeLabel.
  ///
  /// In zh, this message translates to:
  /// **'访客拉黑'**
  String get securityBlacklistNoticeLabel;

  /// No description provided for @securityBlacklistNoticeDesc.
  ///
  /// In zh, this message translates to:
  /// **'拉黑后该访客立即无法登录与入场，操作与原因将记入审计。'**
  String get securityBlacklistNoticeDesc;

  /// No description provided for @securityBlacklistReasonLabel.
  ///
  /// In zh, this message translates to:
  /// **'拉黑原因'**
  String get securityBlacklistReasonLabel;

  /// No description provided for @securityBlacklistReasonHint.
  ///
  /// In zh, this message translates to:
  /// **'请填写拉黑原因（必填）'**
  String get securityBlacklistReasonHint;

  /// No description provided for @securityBlacklistDone.
  ///
  /// In zh, this message translates to:
  /// **'已拉黑该访客'**
  String get securityBlacklistDone;

  /// No description provided for @securityBlacklistRemove.
  ///
  /// In zh, this message translates to:
  /// **'解除拉黑'**
  String get securityBlacklistRemove;

  /// No description provided for @securityBlacklistRemoveConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认解除拉黑？解除后该访客可重新登录与提交申请，历史申请状态不变。'**
  String get securityBlacklistRemoveConfirm;

  /// No description provided for @securityBlacklistRemoveDone.
  ///
  /// In zh, this message translates to:
  /// **'已解除拉黑'**
  String get securityBlacklistRemoveDone;

  /// No description provided for @visitorColName.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get visitorColName;

  /// No description provided for @visitorColPurpose.
  ///
  /// In zh, this message translates to:
  /// **'事由'**
  String get visitorColPurpose;

  /// No description provided for @visitorColHost.
  ///
  /// In zh, this message translates to:
  /// **'接待人'**
  String get visitorColHost;

  /// No description provided for @visitorColPlannedVisit.
  ///
  /// In zh, this message translates to:
  /// **'计划到访'**
  String get visitorColPlannedVisit;

  /// No description provided for @visitorColStatus.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get visitorColStatus;

  /// No description provided for @visitorColCompany.
  ///
  /// In zh, this message translates to:
  /// **'公司'**
  String get visitorColCompany;

  /// No description provided for @visitorColVisitorName.
  ///
  /// In zh, this message translates to:
  /// **'访客姓名'**
  String get visitorColVisitorName;

  /// No description provided for @visitorColHostDepartment.
  ///
  /// In zh, this message translates to:
  /// **'接待人部门'**
  String get visitorColHostDepartment;

  /// No description provided for @visitorApplySubmittingOverlay.
  ///
  /// In zh, this message translates to:
  /// **'正在提交访客申请，请勿重复提交或离开本页。'**
  String get visitorApplySubmittingOverlay;

  /// No description provided for @visitorApplyHostHint.
  ///
  /// In zh, this message translates to:
  /// **'请选择被访人'**
  String get visitorApplyHostHint;

  /// No description provided for @visitorApplyHostSheetTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择被访人'**
  String get visitorApplyHostSheetTitle;

  /// No description provided for @visitorApplyHostSearchEmpty.
  ///
  /// In zh, this message translates to:
  /// **'输入被访人姓名搜索'**
  String get visitorApplyHostSearchEmpty;

  /// No description provided for @visitorApplyHostSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'至少输入 2 个字，最多显示 5 位同事'**
  String get visitorApplyHostSearchHint;

  /// No description provided for @visitorSettingsPortalTag.
  ///
  /// In zh, this message translates to:
  /// **'{app} · 访客端'**
  String visitorSettingsPortalTag(Object app);

  /// No description provided for @visitorApprovalHostDeptColInfo.
  ///
  /// In zh, this message translates to:
  /// **'访客申请时记录的接待人所属部门快照；表头筛选按此下推后端 hostDepartmentId 参数。'**
  String get visitorApprovalHostDeptColInfo;

  /// No description provided for @visitorBatchLimitError.
  ///
  /// In zh, this message translates to:
  /// **'单次最多批量处理 {limit} 条，请分批操作（当前 {count} 条）'**
  String visitorBatchLimitError(int limit, int count);

  /// No description provided for @visitorBatchApproveTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量批准({count})'**
  String visitorBatchApproveTitle(int count);

  /// No description provided for @visitorBatchApproveMessage.
  ///
  /// In zh, this message translates to:
  /// **'将逐单批准所选 {count} 条访客申请，批准后生成通行二维码。如需核对接待人与来访事由，请双击行进入详情逐单审阅。'**
  String visitorBatchApproveMessage(int count);

  /// No description provided for @visitorBatchApproveConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认批量批准'**
  String get visitorBatchApproveConfirm;

  /// No description provided for @visitorBatchActionLabel.
  ///
  /// In zh, this message translates to:
  /// **'访客审批'**
  String get visitorBatchActionLabel;

  /// No description provided for @visitorBatchApproveResponsibility.
  ///
  /// In zh, this message translates to:
  /// **'确认后，系统将以此登录员工记录所选 {count} 条访客申请的审批责任。'**
  String visitorBatchApproveResponsibility(int count);

  /// No description provided for @visitorBatchVerbApprove.
  ///
  /// In zh, this message translates to:
  /// **'批准'**
  String get visitorBatchVerbApprove;

  /// No description provided for @visitorBatchVerbReject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get visitorBatchVerbReject;

  /// No description provided for @visitorBatchVerbForward.
  ///
  /// In zh, this message translates to:
  /// **'转接待人确认'**
  String get visitorBatchVerbForward;

  /// No description provided for @visitorBatchResult.
  ///
  /// In zh, this message translates to:
  /// **'已{verb} {count} 条访客申请'**
  String visitorBatchResult(Object verb, int count);

  /// No description provided for @visitorBatchResultFailures.
  ///
  /// In zh, this message translates to:
  /// **'，{count} 条失败'**
  String visitorBatchResultFailures(int count);

  /// No description provided for @visitorBatchResultSkipped.
  ///
  /// In zh, this message translates to:
  /// **'，{count} 条已跳过'**
  String visitorBatchResultSkipped(int count);

  /// No description provided for @visitorBatchIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'批量{verb}未全部完成：{reason}'**
  String visitorBatchIncomplete(Object verb, Object reason);

  /// No description provided for @visitorBatchRejectTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量拒绝({count})'**
  String visitorBatchRejectTitle(int count);

  /// No description provided for @visitorBatchRejectDescription.
  ///
  /// In zh, this message translates to:
  /// **'拒绝原因将同步给 {count} 位访客，请说明具体问题。'**
  String visitorBatchRejectDescription(int count);

  /// No description provided for @visitorBatchRejectConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认拒绝'**
  String get visitorBatchRejectConfirm;

  /// No description provided for @visitorBatchSubjectLabel.
  ///
  /// In zh, this message translates to:
  /// **'访客申请'**
  String get visitorBatchSubjectLabel;

  /// No description provided for @visitorBatchForwardNoneSelected.
  ///
  /// In zh, this message translates to:
  /// **'所选申请均已转接待人确认，无需重复转接'**
  String get visitorBatchForwardNoneSelected;

  /// No description provided for @visitorBatchForwardTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量转接待人确认({count})'**
  String visitorBatchForwardTitle(int count);

  /// No description provided for @visitorBatchForwardMessage.
  ///
  /// In zh, this message translates to:
  /// **'将把所选 {count} 条访客申请转给各自接待人确认，接待人确认后回到本队列等待你最终批准。'**
  String visitorBatchForwardMessage(int count);

  /// No description provided for @visitorBatchForwardSkippedNote.
  ///
  /// In zh, this message translates to:
  /// **'（另有 {count} 条已在接待人确认中，已跳过）'**
  String visitorBatchForwardSkippedNote(int count);

  /// No description provided for @visitorBatchForwardConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认批量转接'**
  String get visitorBatchForwardConfirm;

  /// No description provided for @visitorBatchForwardResponsibility.
  ///
  /// In zh, this message translates to:
  /// **'确认后，系统将以此登录员工记录所选 {count} 条访客申请的转接责任。'**
  String visitorBatchForwardResponsibility(int count);

  /// No description provided for @visitorBatchApproveButton.
  ///
  /// In zh, this message translates to:
  /// **'批量批准({count})'**
  String visitorBatchApproveButton(int count);

  /// No description provided for @visitorBatchForwardButton.
  ///
  /// In zh, this message translates to:
  /// **'批量转接待人确认({count})'**
  String visitorBatchForwardButton(int count);

  /// No description provided for @visitorBatchRejectButton.
  ///
  /// In zh, this message translates to:
  /// **'批量拒绝({count})'**
  String visitorBatchRejectButton(int count);

  /// No description provided for @visitorApprovalDoneApprove.
  ///
  /// In zh, this message translates to:
  /// **'访客申请已批准'**
  String get visitorApprovalDoneApprove;

  /// No description provided for @visitorApprovalDoneReject.
  ///
  /// In zh, this message translates to:
  /// **'访客申请已驳回'**
  String get visitorApprovalDoneReject;

  /// No description provided for @visitorApprovalDoneForward.
  ///
  /// In zh, this message translates to:
  /// **'已转接待人确认'**
  String get visitorApprovalDoneForward;

  /// No description provided for @visitorApprovalDoneFallback.
  ///
  /// In zh, this message translates to:
  /// **'审批操作已完成'**
  String get visitorApprovalDoneFallback;

  /// No description provided for @visitorApprovalApproveNoticeLabel.
  ///
  /// In zh, this message translates to:
  /// **'访客审批通过'**
  String get visitorApprovalApproveNoticeLabel;

  /// No description provided for @visitorApprovalApproveNoticeDesc.
  ///
  /// In zh, this message translates to:
  /// **'确认后系统将记录当前审核员和审批结果，请对本次访客放行决定负责。'**
  String get visitorApprovalApproveNoticeDesc;

  /// No description provided for @visitorApprovalRejectNoticeLabel.
  ///
  /// In zh, this message translates to:
  /// **'访客审批拒绝'**
  String get visitorApprovalRejectNoticeLabel;

  /// No description provided for @visitorApprovalRejectNoticeDesc.
  ///
  /// In zh, this message translates to:
  /// **'确认后系统将记录当前审核员和拒绝结果，请对本次决定负责。'**
  String get visitorApprovalRejectNoticeDesc;

  /// No description provided for @myVisitorsConfirmDone.
  ///
  /// In zh, this message translates to:
  /// **'已确认接待，申请已转回 HR 审批'**
  String get myVisitorsConfirmDone;

  /// No description provided for @myVisitorsRejectDone.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝接待'**
  String get myVisitorsRejectDone;

  /// No description provided for @myVisitorsBatchNoneSelected.
  ///
  /// In zh, this message translates to:
  /// **'所选申请均不在「待我确认」状态，无需确认'**
  String get myVisitorsBatchNoneSelected;

  /// No description provided for @myVisitorsBatchTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量确认接待({count})'**
  String myVisitorsBatchTitle(int count);

  /// No description provided for @myVisitorsBatchMessage.
  ///
  /// In zh, this message translates to:
  /// **'将逐条确认接待所选 {count} 位访客，确认后申请转回 HR 等待最终批准。'**
  String myVisitorsBatchMessage(int count);

  /// No description provided for @myVisitorsBatchSkippedNote.
  ///
  /// In zh, this message translates to:
  /// **'（另有 {count} 条不在「待我确认」状态，已跳过）'**
  String myVisitorsBatchSkippedNote(int count);

  /// No description provided for @myVisitorsBatchConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认接待'**
  String get myVisitorsBatchConfirm;

  /// No description provided for @myVisitorsBatchResult.
  ///
  /// In zh, this message translates to:
  /// **'已确认接待 {count} 位访客'**
  String myVisitorsBatchResult(int count);

  /// No description provided for @myVisitorsBatchIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'批量确认未全部完成：{reason}'**
  String myVisitorsBatchIncomplete(Object reason);

  /// No description provided for @myVisitorsBatchButton.
  ///
  /// In zh, this message translates to:
  /// **'批量确认接待({count})'**
  String myVisitorsBatchButton(int count);

  /// No description provided for @myVisitorsStatusColInfo.
  ///
  /// In zh, this message translates to:
  /// **'默认只看「待我确认」；表头筛选可切到已转 HR / 已批准 / 已拒绝（下推后端）。'**
  String get myVisitorsStatusColInfo;

  /// No description provided for @expenseFlowNew.
  ///
  /// In zh, this message translates to:
  /// **'新建报销'**
  String get expenseFlowNew;

  /// No description provided for @expenseFlowEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑报销'**
  String get expenseFlowEdit;

  /// No description provided for @expenseFlowSaveAndContinue.
  ///
  /// In zh, this message translates to:
  /// **'保存并补充凭证'**
  String get expenseFlowSaveAndContinue;

  /// No description provided for @expenseFlowSaveDraft.
  ///
  /// In zh, this message translates to:
  /// **'存草稿'**
  String get expenseFlowSaveDraft;

  /// No description provided for @expenseFlowSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get expenseFlowSave;

  /// No description provided for @expenseFlowFlowGuide.
  ///
  /// In zh, this message translates to:
  /// **'填写费用 → 保存草稿 → 上传原件并登记凭证 → 提交审批 → 财务登记付款'**
  String get expenseFlowFlowGuide;

  /// No description provided for @expenseFlowInvoiceGuide.
  ///
  /// In zh, this message translates to:
  /// **'请先保存草稿，再上传发票或其他合法凭证原件。电子凭证应保留收到的原始文件；图片识别仅辅助填写，不能代替查验或归档。'**
  String get expenseFlowInvoiceGuide;

  /// No description provided for @expenseFlowNoInvoiceGuide.
  ///
  /// In zh, this message translates to:
  /// **'无发票时，请在说明中写明原因及凭证情况，上传能够证明真实业务的合法凭证，由财务审核。'**
  String get expenseFlowNoInvoiceGuide;

  /// No description provided for @expenseFlowApplicant.
  ///
  /// In zh, this message translates to:
  /// **'申请人'**
  String get expenseFlowApplicant;

  /// No description provided for @expenseFlowDepartment.
  ///
  /// In zh, this message translates to:
  /// **'部门'**
  String get expenseFlowDepartment;

  /// No description provided for @expenseFlowDate.
  ///
  /// In zh, this message translates to:
  /// **'制单日期'**
  String get expenseFlowDate;

  /// No description provided for @expenseFlowTitle.
  ///
  /// In zh, this message translates to:
  /// **'报销标题 *'**
  String get expenseFlowTitle;

  /// No description provided for @expenseFlowTitleHint.
  ///
  /// In zh, this message translates to:
  /// **'如：上海客户拜访差旅'**
  String get expenseFlowTitleHint;

  /// No description provided for @expenseFlowTitleInfo.
  ///
  /// In zh, this message translates to:
  /// **'简要说明费用用途，将打印在报销单事由栏。'**
  String get expenseFlowTitleInfo;

  /// No description provided for @expenseFlowRemark.
  ///
  /// In zh, this message translates to:
  /// **'事由与说明'**
  String get expenseFlowRemark;

  /// No description provided for @expenseFlowRemarkHint.
  ///
  /// In zh, this message translates to:
  /// **'行程、项目、同行人员，或无发票的情况说明'**
  String get expenseFlowRemarkHint;

  /// No description provided for @expenseFlowMissingTitle.
  ///
  /// In zh, this message translates to:
  /// **'请填写报销标题'**
  String get expenseFlowMissingTitle;

  /// No description provided for @expenseFlowTitleLength.
  ///
  /// In zh, this message translates to:
  /// **'报销标题最多 200 字'**
  String get expenseFlowTitleLength;

  /// No description provided for @expenseFlowMissingItems.
  ///
  /// In zh, this message translates to:
  /// **'请至少添加一项报销明细'**
  String get expenseFlowMissingItems;

  /// No description provided for @expenseFlowItems.
  ///
  /// In zh, this message translates to:
  /// **'报销明细'**
  String get expenseFlowItems;

  /// No description provided for @expenseFlowAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get expenseFlowAdd;

  /// No description provided for @expenseFlowEmptyItems.
  ///
  /// In zh, this message translates to:
  /// **'点击添加，填写费用类别、实际金额及发生日期。'**
  String get expenseFlowEmptyItems;

  /// No description provided for @expenseFlowTotal.
  ///
  /// In zh, this message translates to:
  /// **'报销合计'**
  String get expenseFlowTotal;

  /// No description provided for @expenseFlowCapital.
  ///
  /// In zh, this message translates to:
  /// **'人民币大写'**
  String get expenseFlowCapital;

  /// No description provided for @expenseFlowDeleteItem.
  ///
  /// In zh, this message translates to:
  /// **'删除明细'**
  String get expenseFlowDeleteItem;

  /// No description provided for @expenseFlowDraftSaved.
  ///
  /// In zh, this message translates to:
  /// **'草稿已保存，请补充凭证后提交审批'**
  String get expenseFlowDraftSaved;

  /// No description provided for @expenseFlowSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get expenseFlowSaved;

  /// No description provided for @expenseFlowRejectedGuide.
  ///
  /// In zh, this message translates to:
  /// **'已被驳回，请根据原因修订，保存后重新提交。'**
  String get expenseFlowRejectedGuide;

  /// No description provided for @expenseFlowLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败，请重试'**
  String get expenseFlowLoadFailed;

  /// No description provided for @expenseFlowNotEditable.
  ///
  /// In zh, this message translates to:
  /// **'仅申请人可编辑草稿或已驳回的报销单。'**
  String get expenseFlowNotEditable;

  /// No description provided for @expenseFlowAmountInvalid.
  ///
  /// In zh, this message translates to:
  /// **'金额须大于 0，最多两位小数，不超过 9999999999.99 元'**
  String get expenseFlowAmountInvalid;

  /// No description provided for @expenseFlowInvoiceAmountInvalid.
  ///
  /// In zh, this message translates to:
  /// **'金额最多两位小数；价税合计须大于 0，其余金额不能为负'**
  String get expenseFlowInvoiceAmountInvalid;

  /// No description provided for @expenseFlowOcrGuide.
  ///
  /// In zh, this message translates to:
  /// **'选择图片识别并预填，再对照原件逐项确认。识别不会查验真伪，也不会自动保存原件。'**
  String get expenseFlowOcrGuide;

  /// No description provided for @expenseFlowOcrConfirm.
  ///
  /// In zh, this message translates to:
  /// **'我已对照原件核对识别结果'**
  String get expenseFlowOcrConfirm;

  /// No description provided for @expenseFlowOcrConfirmRequired.
  ///
  /// In zh, this message translates to:
  /// **'请先核对识别结果并勾选确认'**
  String get expenseFlowOcrConfirmRequired;

  /// No description provided for @expenseFlowOriginalRequired.
  ///
  /// In zh, this message translates to:
  /// **'请先在详情页上传凭证原件，并在此关联对应文件'**
  String get expenseFlowOriginalRequired;

  /// No description provided for @expenseFlowInvoiceDateRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择凭证日期'**
  String get expenseFlowInvoiceDateRequired;

  /// No description provided for @expenseFlowOtherNumberInvalid.
  ///
  /// In zh, this message translates to:
  /// **'其他凭证号码可包含字母、数字、斜线和短横线，最多 60 位；请填写开具方'**
  String get expenseFlowOtherNumberInvalid;

  /// No description provided for @expenseFlowVerify.
  ///
  /// In zh, this message translates to:
  /// **'登记查验结果'**
  String get expenseFlowVerify;

  /// No description provided for @expenseFlowVerifyTitle.
  ///
  /// In zh, this message translates to:
  /// **'凭证人工查验'**
  String get expenseFlowVerifyTitle;

  /// No description provided for @expenseFlowVerifyGuide.
  ///
  /// In zh, this message translates to:
  /// **'先核对业务真实性和附件原件。税务发票请在国家税务总局发票查验平台或电子税务局查验；其他合法凭证按其适用渠道核实。金额勾稽与图片识别均不代表税务查验。'**
  String get expenseFlowVerifyGuide;

  /// No description provided for @expenseFlowVerifyOfficial.
  ///
  /// In zh, this message translates to:
  /// **'打开国家税务总局查验平台'**
  String get expenseFlowVerifyOfficial;

  /// No description provided for @expenseFlowVerifyRemark.
  ///
  /// In zh, this message translates to:
  /// **'查验记录(渠道、结果及必要说明) *'**
  String get expenseFlowVerifyRemark;

  /// No description provided for @expenseFlowVerifyPassed.
  ///
  /// In zh, this message translates to:
  /// **'查验通过'**
  String get expenseFlowVerifyPassed;

  /// No description provided for @expenseFlowVerifyMismatch.
  ///
  /// In zh, this message translates to:
  /// **'查验不符'**
  String get expenseFlowVerifyMismatch;

  /// No description provided for @expenseFlowVerifyRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写查验渠道和结果说明'**
  String get expenseFlowVerifyRequired;

  /// No description provided for @expenseFlowVerifyBeforeApprove.
  ///
  /// In zh, this message translates to:
  /// **'请先逐张登记凭证的人工查验结果，再审批通过'**
  String get expenseFlowVerifyBeforeApprove;

  /// No description provided for @expenseFlowPaymentRecord.
  ///
  /// In zh, this message translates to:
  /// **'登记付款'**
  String get expenseFlowPaymentRecord;

  /// No description provided for @expenseFlowPaymentConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认已付款'**
  String get expenseFlowPaymentConfirm;

  /// No description provided for @expenseFlowPaymentGuide.
  ///
  /// In zh, this message translates to:
  /// **'请先在线下完成实际付款。此操作只登记已发生的付款、扣减系统账户余额并生成财务记录，不会向银行发起转账。'**
  String get expenseFlowPaymentGuide;

  /// No description provided for @expenseFlowPaymentDone.
  ///
  /// In zh, this message translates to:
  /// **'已登记付款，财务记录已生成'**
  String get expenseFlowPaymentDone;

  /// No description provided for @expenseFlowPrintDisclaimer.
  ///
  /// In zh, this message translates to:
  /// **'内部报销审批展示单；不替代原始凭证、税务查验或法定电子档案。'**
  String get expenseFlowPrintDisclaimer;

  /// No description provided for @expenseFlowSettingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'报销设置'**
  String get expenseFlowSettingsTitle;

  /// No description provided for @expenseFlowSettingsDescription.
  ///
  /// In zh, this message translates to:
  /// **'由财务维护公司抬头和凭证要求，员工填单时自动显示。'**
  String get expenseFlowSettingsDescription;

  /// No description provided for @expenseFlowCompanyName.
  ///
  /// In zh, this message translates to:
  /// **'公司名称'**
  String get expenseFlowCompanyName;

  /// No description provided for @expenseFlowCompanyTaxNo.
  ///
  /// In zh, this message translates to:
  /// **'纳税人识别号'**
  String get expenseFlowCompanyTaxNo;

  /// No description provided for @expenseFlowSubmissionGuide.
  ///
  /// In zh, this message translates to:
  /// **'报销及凭证说明'**
  String get expenseFlowSubmissionGuide;

  /// No description provided for @expenseFlowRequireInvoice.
  ///
  /// In zh, this message translates to:
  /// **'提交时必须登记发票'**
  String get expenseFlowRequireInvoice;

  /// No description provided for @expenseFlowRequireInvoiceHint.
  ///
  /// In zh, this message translates to:
  /// **'关闭后仍须上传合法原始凭证，并填写无发票情况说明。'**
  String get expenseFlowRequireInvoiceHint;

  /// No description provided for @expenseFlowSettingsSaved.
  ///
  /// In zh, this message translates to:
  /// **'报销设置已保存'**
  String get expenseFlowSettingsSaved;

  /// No description provided for @expenseFlowSettingsSave.
  ///
  /// In zh, this message translates to:
  /// **'保存设置'**
  String get expenseFlowSettingsSave;

  /// No description provided for @expenseFlowSettingsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'报销设置加载失败'**
  String get expenseFlowSettingsLoadFailed;

  /// No description provided for @expenseFlowRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get expenseFlowRetry;

  /// No description provided for @expenseFlowCompanyNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写公司名称'**
  String get expenseFlowCompanyNameRequired;

  /// No description provided for @expenseFlowSettingsEntryDescription.
  ///
  /// In zh, this message translates to:
  /// **'公司抬头、税号及提交凭证要求'**
  String get expenseFlowSettingsEntryDescription;

  /// No description provided for @expenseFlowApprovalEntryDescription.
  ///
  /// In zh, this message translates to:
  /// **'核对凭证、审批及登记付款'**
  String get expenseFlowApprovalEntryDescription;

  /// No description provided for @expenseFlowApprovalTitle.
  ///
  /// In zh, this message translates to:
  /// **'报销审批'**
  String get expenseFlowApprovalTitle;

  /// No description provided for @expenseFlowInvoiceRequiredGuide.
  ///
  /// In zh, this message translates to:
  /// **'按财务设置，本单须登记发票并关联原件后才能提交。'**
  String get expenseFlowInvoiceRequiredGuide;

  /// No description provided for @expenseFlowReadEvidenceRequired.
  ///
  /// In zh, this message translates to:
  /// **'审批通过前需要具备凭证预览与下载权限，请联系授权人。'**
  String get expenseFlowReadEvidenceRequired;

  /// No description provided for @expenseFlowHistory.
  ///
  /// In zh, this message translates to:
  /// **'已处理'**
  String get expenseFlowHistory;

  /// No description provided for @expenseFlowPendingCorrection.
  ///
  /// In zh, this message translates to:
  /// **'待修订'**
  String get expenseFlowPendingCorrection;

  /// No description provided for @expenseFlowPaymentProofs.
  ///
  /// In zh, this message translates to:
  /// **'付款证明(银行回单或现金签收凭据)'**
  String get expenseFlowPaymentProofs;

  /// No description provided for @expenseFlowPaymentProofGuide.
  ///
  /// In zh, this message translates to:
  /// **'先完成实际付款并上传凭据，再登记付款。'**
  String get expenseFlowPaymentProofGuide;

  /// No description provided for @expenseFlowPaymentProofRequired.
  ///
  /// In zh, this message translates to:
  /// **'请先上传付款证明，再确认已付款。'**
  String get expenseFlowPaymentProofRequired;

  /// No description provided for @expenseFlowItemPurpose.
  ///
  /// In zh, this message translates to:
  /// **'费用用途 *'**
  String get expenseFlowItemPurpose;

  /// No description provided for @expenseFlowItemPurposeHint.
  ///
  /// In zh, this message translates to:
  /// **'请说明这笔费用的真实用途，如客户、项目或具体行程。'**
  String get expenseFlowItemPurposeHint;

  /// No description provided for @expenseFlowItemPurposeRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写费用用途'**
  String get expenseFlowItemPurposeRequired;

  /// No description provided for @goodsLearnedPriceUnconfirmed.
  ///
  /// In zh, this message translates to:
  /// **'计价单位与币种待核对'**
  String get goodsLearnedPriceUnconfirmed;

  /// No description provided for @goodsLearnedPriceTaxRate.
  ///
  /// In zh, this message translates to:
  /// **'税率'**
  String get goodsLearnedPriceTaxRate;

  /// No description provided for @shelfLocationQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'库位是存放建议；库存按实际仓库和颜色统计，不代表该库位的盘点数量。'**
  String get shelfLocationQuantityHint;

  /// No description provided for @shelfActualWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'实际仓库'**
  String get shelfActualWarehouse;

  /// No description provided for @shelfMasterOnly.
  ///
  /// In zh, this message translates to:
  /// **'主档建议(未指定仓库)'**
  String get shelfMasterOnly;

  /// No description provided for @shelfChooseWarehouseForRack.
  ///
  /// In zh, this message translates to:
  /// **'当前包含多个仓库，请选择具体仓库查看货架图。下表按实际仓库分别列示。'**
  String get shelfChooseWarehouseForRack;

  /// No description provided for @materialPreparationReview.
  ///
  /// In zh, this message translates to:
  /// **'核对并下单'**
  String get materialPreparationReview;

  /// No description provided for @materialPreparationApproveNow.
  ///
  /// In zh, this message translates to:
  /// **'同时审核下达'**
  String get materialPreparationApproveNow;

  /// No description provided for @materialPreparationViewPlans.
  ///
  /// In zh, this message translates to:
  /// **'查看已下达计划'**
  String get materialPreparationViewPlans;

  /// No description provided for @materialPreparationOrdering.
  ///
  /// In zh, this message translates to:
  /// **'正在下单…'**
  String get materialPreparationOrdering;

  /// No description provided for @materialPreparationOrderCount.
  ///
  /// In zh, this message translates to:
  /// **'下单({count})'**
  String materialPreparationOrderCount(int count);

  /// No description provided for @materialPreparationNoActions.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可办理的物料'**
  String get materialPreparationNoActions;

  /// No description provided for @materialPreparationAvailableHint.
  ///
  /// In zh, this message translates to:
  /// **'本行可安排的现货和已下达供给，包含在途及未办理余量；其它订单已占用的量不重复计入，实际领料以实物为准。'**
  String get materialPreparationAvailableHint;

  /// No description provided for @materialPreparationPending.
  ///
  /// In zh, this message translates to:
  /// **'待下单'**
  String get materialPreparationPending;

  /// No description provided for @materialPreparationInProgress.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get materialPreparationInProgress;

  /// No description provided for @materialPreparationMissingAssignment.
  ///
  /// In zh, this message translates to:
  /// **'请先补齐“{goods}”的生产车间和负责人，再下单'**
  String materialPreparationMissingAssignment(String goods);

  /// No description provided for @workshopMaterialBin.
  ///
  /// In zh, this message translates to:
  /// **'车间内料仓'**
  String get workshopMaterialBin;

  /// No description provided for @workshopMaterialBinOf.
  ///
  /// In zh, this message translates to:
  /// **'{workshop}内料仓'**
  String workshopMaterialBinOf(String workshop);

  /// No description provided for @workshopMaterialGroup.
  ///
  /// In zh, this message translates to:
  /// **'车间内料仓'**
  String get workshopMaterialGroup;

  /// No description provided for @workshopMaterialSetup.
  ///
  /// In zh, this message translates to:
  /// **'车间内料仓设置'**
  String get workshopMaterialSetup;

  /// No description provided for @workshopMaterialReports.
  ///
  /// In zh, this message translates to:
  /// **'车间内料仓用量'**
  String get workshopMaterialReports;

  /// No description provided for @wmIssueMethod.
  ///
  /// In zh, this message translates to:
  /// **'发料方式'**
  String get wmIssueMethod;

  /// No description provided for @wmIssueMethodOrder.
  ///
  /// In zh, this message translates to:
  /// **'按工单领料'**
  String get wmIssueMethodOrder;

  /// No description provided for @wmIssueMethodPeriodic.
  ///
  /// In zh, this message translates to:
  /// **'整批领到车间内料仓'**
  String get wmIssueMethodPeriodic;

  /// No description provided for @wmCostBasis.
  ///
  /// In zh, this message translates to:
  /// **'分摊方式'**
  String get wmCostBasis;

  /// No description provided for @wmCostBasisOwn.
  ///
  /// In zh, this message translates to:
  /// **'主料'**
  String get wmCostBasisOwn;

  /// No description provided for @wmCostBasisShared.
  ///
  /// In zh, this message translates to:
  /// **'辅料'**
  String get wmCostBasisShared;

  /// No description provided for @wmCostBasisExpense.
  ///
  /// In zh, this message translates to:
  /// **'记车间费用'**
  String get wmCostBasisExpense;

  /// No description provided for @wmBulkPackageQty.
  ///
  /// In zh, this message translates to:
  /// **'每袋净重 (公斤)'**
  String get wmBulkPackageQty;

  /// No description provided for @wmRecycledMaterial.
  ///
  /// In zh, this message translates to:
  /// **'回收料'**
  String get wmRecycledMaterial;

  /// No description provided for @wmUnitWeightGrams.
  ///
  /// In zh, this message translates to:
  /// **'单个重量 (克)'**
  String get wmUnitWeightGrams;

  /// No description provided for @wmUnitWeightFromBom.
  ///
  /// In zh, this message translates to:
  /// **'塑料单个重量 (来自 BOM): {grams} 克'**
  String wmUnitWeightFromBom(String grams);

  /// No description provided for @wmUnusualWeightConfirm.
  ///
  /// In zh, this message translates to:
  /// **'单个重量 {grams} 克看起来不太对, 确定吗?'**
  String wmUnusualWeightConfirm(String grams);

  /// No description provided for @wmSecondMaterialConfirm.
  ///
  /// In zh, this message translates to:
  /// **'这个产品要同时用两种料吗 (双色 / 双料)? 如果只是换料, 请改原来那一行'**
  String get wmSecondMaterialConfirm;

  /// No description provided for @wmRequestIssue.
  ///
  /// In zh, this message translates to:
  /// **'申请领料'**
  String get wmRequestIssue;

  /// No description provided for @wmReturn.
  ///
  /// In zh, this message translates to:
  /// **'退回'**
  String get wmReturn;

  /// No description provided for @wmOtherIssue.
  ///
  /// In zh, this message translates to:
  /// **'试模清机等用料'**
  String get wmOtherIssue;

  /// No description provided for @wmOtherReasonTrial.
  ///
  /// In zh, this message translates to:
  /// **'试模'**
  String get wmOtherReasonTrial;

  /// No description provided for @wmOtherReasonPurge.
  ///
  /// In zh, this message translates to:
  /// **'清机'**
  String get wmOtherReasonPurge;

  /// No description provided for @wmOtherReasonScrap.
  ///
  /// In zh, this message translates to:
  /// **'报废料'**
  String get wmOtherReasonScrap;

  /// No description provided for @wmOtherReasonOther.
  ///
  /// In zh, this message translates to:
  /// **'其它'**
  String get wmOtherReasonOther;

  /// No description provided for @wmDirectIssue.
  ///
  /// In zh, this message translates to:
  /// **'直接发料'**
  String get wmDirectIssue;

  /// No description provided for @wmPendingIssue.
  ///
  /// In zh, this message translates to:
  /// **'待发料'**
  String get wmPendingIssue;

  /// No description provided for @wmPendingReturn.
  ///
  /// In zh, this message translates to:
  /// **'待收退回'**
  String get wmPendingReturn;

  /// No description provided for @wmCount.
  ///
  /// In zh, this message translates to:
  /// **'盘点'**
  String get wmCount;

  /// No description provided for @wmHistory.
  ///
  /// In zh, this message translates to:
  /// **'记录'**
  String get wmHistory;

  /// No description provided for @wmBags.
  ///
  /// In zh, this message translates to:
  /// **'袋数'**
  String get wmBags;

  /// No description provided for @wmKg.
  ///
  /// In zh, this message translates to:
  /// **'公斤'**
  String get wmKg;

  /// No description provided for @wmReceiver.
  ///
  /// In zh, this message translates to:
  /// **'领料人'**
  String get wmReceiver;

  /// No description provided for @wmWarehouseAvailable.
  ///
  /// In zh, this message translates to:
  /// **'仓库还有 {qty} 公斤'**
  String wmWarehouseAvailable(String qty);

  /// No description provided for @wmEstimatedRemaining.
  ///
  /// In zh, this message translates to:
  /// **'内料仓估计还剩 {qty} 公斤'**
  String wmEstimatedRemaining(String qty);

  /// No description provided for @wmCountingNextPeriod.
  ///
  /// In zh, this message translates to:
  /// **'已开始盘点, 这批料算到下一期'**
  String get wmCountingNextPeriod;

  /// No description provided for @wmSupplementFlag.
  ///
  /// In zh, this message translates to:
  /// **'这批料是上一期漏录的'**
  String get wmSupplementFlag;

  /// No description provided for @wmSupplementPeriod.
  ///
  /// In zh, this message translates to:
  /// **'补到哪一期'**
  String get wmSupplementPeriod;

  /// No description provided for @wmAlsoOrderMaterials.
  ///
  /// In zh, this message translates to:
  /// **'还要按工单领别的料 (例如嵌件)'**
  String get wmAlsoOrderMaterials;

  /// No description provided for @wmFillFromGoodsWeight.
  ///
  /// In zh, this message translates to:
  /// **'勾选行用货品资料单重填入'**
  String get wmFillFromGoodsWeight;

  /// No description provided for @wmCloseFailing.
  ///
  /// In zh, this message translates to:
  /// **'结算连续失败, 系统改为每天重试一次, 请联系系统管理员'**
  String get wmCloseFailing;

  /// No description provided for @wmStartCount.
  ///
  /// In zh, this message translates to:
  /// **'开始盘点'**
  String get wmStartCount;

  /// No description provided for @wmCutoffToday.
  ///
  /// In zh, this message translates to:
  /// **'截止到今天'**
  String get wmCutoffToday;

  /// No description provided for @wmCutoffYesterday.
  ///
  /// In zh, this message translates to:
  /// **'截止到昨天'**
  String get wmCutoffYesterday;

  /// No description provided for @wmMonthEndHint.
  ///
  /// In zh, this message translates to:
  /// **'想要按月对账, 请在月底盘一次'**
  String get wmMonthEndHint;

  /// No description provided for @wmFillFull.
  ///
  /// In zh, this message translates to:
  /// **'满'**
  String get wmFillFull;

  /// No description provided for @wmFillHalf.
  ///
  /// In zh, this message translates to:
  /// **'半'**
  String get wmFillHalf;

  /// No description provided for @wmFillEmpty.
  ///
  /// In zh, this message translates to:
  /// **'空'**
  String get wmFillEmpty;

  /// No description provided for @wmFillWeighed.
  ///
  /// In zh, this message translates to:
  /// **'直接填公斤'**
  String get wmFillWeighed;

  /// No description provided for @wmWeighOpenBag.
  ///
  /// In zh, this message translates to:
  /// **'开口袋过秤'**
  String get wmWeighOpenBag;

  /// No description provided for @wmWeighMixed.
  ///
  /// In zh, this message translates to:
  /// **'搅好未上机'**
  String get wmWeighMixed;

  /// No description provided for @wmWeighLoose.
  ///
  /// In zh, this message translates to:
  /// **'散料'**
  String get wmWeighLoose;

  /// No description provided for @wmFillGuide.
  ///
  /// In zh, this message translates to:
  /// **'满按容量、半按一半估算；空按 0 记录，仅用于确实无料。容器有余料时可称重后直接填公斤。满/半/空属于估盘，会影响本期和下期耗用。'**
  String get wmFillGuide;

  /// No description provided for @wmMachineIdle.
  ///
  /// In zh, this message translates to:
  /// **'本机停机、全空'**
  String get wmMachineIdle;

  /// No description provided for @wmZeroRest.
  ///
  /// In zh, this message translates to:
  /// **'其余料都用完了, 记 0'**
  String get wmZeroRest;

  /// No description provided for @wmPrintBlank.
  ///
  /// In zh, this message translates to:
  /// **'打印空白盘点表'**
  String get wmPrintBlank;

  /// No description provided for @wmSubmitCount.
  ///
  /// In zh, this message translates to:
  /// **'审核盘点并过账'**
  String get wmSubmitCount;

  /// No description provided for @wmWithdrawCount.
  ///
  /// In zh, this message translates to:
  /// **'撤回盘点'**
  String get wmWithdrawCount;

  /// No description provided for @wmCorrectCount.
  ///
  /// In zh, this message translates to:
  /// **'更正盘点'**
  String get wmCorrectCount;

  /// No description provided for @wmBagsTimesKg.
  ///
  /// In zh, this message translates to:
  /// **'整袋 {bags} 袋 × 每袋 {kg} 公斤'**
  String wmBagsTimesKg(int bags, String kg);

  /// No description provided for @wmCloseState.
  ///
  /// In zh, this message translates to:
  /// **'结算状态'**
  String get wmCloseState;

  /// No description provided for @wmCloseWaitingPrevious.
  ///
  /// In zh, this message translates to:
  /// **'等上一期结算'**
  String get wmCloseWaitingPrevious;

  /// No description provided for @wmCloseBlockedReport.
  ///
  /// In zh, this message translates to:
  /// **'还有 {n} 张报工没审核 (请审核人审核, 或制单人删掉不要的草稿)'**
  String wmCloseBlockedReport(int n);

  /// No description provided for @wmCloseBlockedWeight.
  ///
  /// In zh, this message translates to:
  /// **'有 {n} 个产品没填单个重量 (请 BOM 维护人处理)'**
  String wmCloseBlockedWeight(int n);

  /// No description provided for @wmCloseBlockedStock.
  ///
  /// In zh, this message translates to:
  /// **'「{material}」这一期没有发料记录却有产品在用 (请仓库补录漏录的发料, 或车间改认料)'**
  String wmCloseBlockedStock(String material);

  /// No description provided for @wmCloseRetry.
  ///
  /// In zh, this message translates to:
  /// **'立即重试'**
  String get wmCloseRetry;

  /// No description provided for @wmReopen.
  ///
  /// In zh, this message translates to:
  /// **'撤销结算'**
  String get wmReopen;

  /// No description provided for @wmReopenReason.
  ///
  /// In zh, this message translates to:
  /// **'撤销原因'**
  String get wmReopenReason;

  /// No description provided for @wmReopenHeld.
  ///
  /// In zh, this message translates to:
  /// **'已撤销结算, 改完请点「重新结算」; {time} 系统会自动重新结算'**
  String wmReopenHeld(String time);

  /// No description provided for @wmSettleAgain.
  ///
  /// In zh, this message translates to:
  /// **'重新结算'**
  String get wmSettleAgain;

  /// No description provided for @wmNeedChoice.
  ///
  /// In zh, this message translates to:
  /// **'待认料'**
  String get wmNeedChoice;

  /// No description provided for @wmStartSheetTitle.
  ///
  /// In zh, this message translates to:
  /// **'开工前确认用料'**
  String get wmStartSheetTitle;

  /// No description provided for @wmStartConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认并开工 ({n})'**
  String wmStartConfirm(int n);

  /// No description provided for @wmOrderInstead.
  ///
  /// In zh, this message translates to:
  /// **'这几个产品按工单领料 (暂不开工)'**
  String get wmOrderInstead;

  /// No description provided for @wmNotFromStore.
  ///
  /// In zh, this message translates to:
  /// **'本产品不用车间内料仓的料 (按工单领料)'**
  String get wmNotFromStore;

  /// No description provided for @wmWeightPending.
  ///
  /// In zh, this message translates to:
  /// **'待补, 不影响开工'**
  String get wmWeightPending;

  /// No description provided for @wmChangeMaterial.
  ///
  /// In zh, this message translates to:
  /// **'这张工单改用别的料'**
  String get wmChangeMaterial;

  /// No description provided for @wmChangeFrom.
  ///
  /// In zh, this message translates to:
  /// **'从哪天起改用'**
  String get wmChangeFrom;

  /// No description provided for @wmAddMaterial.
  ///
  /// In zh, this message translates to:
  /// **'加一种料'**
  String get wmAddMaterial;

  /// No description provided for @wmEnable.
  ///
  /// In zh, this message translates to:
  /// **'开启整批领料'**
  String get wmEnable;

  /// No description provided for @wmGoLiveDate.
  ///
  /// In zh, this message translates to:
  /// **'启用日'**
  String get wmGoLiveDate;

  /// No description provided for @wmMainWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'放在哪个主仓下'**
  String get wmMainWarehouse;

  /// No description provided for @wmMachines.
  ///
  /// In zh, this message translates to:
  /// **'机台与容器'**
  String get wmMachines;

  /// No description provided for @wmGoLivePrep.
  ///
  /// In zh, this message translates to:
  /// **'上线准备'**
  String get wmGoLivePrep;

  /// No description provided for @wmGoLiveProgress.
  ///
  /// In zh, this message translates to:
  /// **'常做的 {total} 个产品, 已选料 {chosen} 个, 已填单重 {weighed} 个'**
  String wmGoLiveProgress(int total, int chosen, int weighed);

  /// No description provided for @wmReportUsage.
  ///
  /// In zh, this message translates to:
  /// **'用量表'**
  String get wmReportUsage;

  /// No description provided for @wmReportProduct.
  ///
  /// In zh, this message translates to:
  /// **'产品用料'**
  String get wmReportProduct;

  /// No description provided for @wmReportTrend.
  ///
  /// In zh, this message translates to:
  /// **'耗用差异率趋势'**
  String get wmReportTrend;

  /// No description provided for @wmReportMissingWeight.
  ///
  /// In zh, this message translates to:
  /// **'缺单重清单'**
  String get wmReportMissingWeight;

  /// No description provided for @wmReportLedger.
  ///
  /// In zh, this message translates to:
  /// **'收发明细'**
  String get wmReportLedger;

  /// No description provided for @wmTrueUnitUsage.
  ///
  /// In zh, this message translates to:
  /// **'独占期平均耗用'**
  String get wmTrueUnitUsage;

  /// No description provided for @wmAllocatedByTheory.
  ///
  /// In zh, this message translates to:
  /// **'按理论比例分摊'**
  String get wmAllocatedByTheory;

  /// No description provided for @wmWasteRate.
  ///
  /// In zh, this message translates to:
  /// **'耗用差异率'**
  String get wmWasteRate;

  /// No description provided for @wmIncludeWorkshopStore.
  ///
  /// In zh, this message translates to:
  /// **'含内料仓'**
  String get wmIncludeWorkshopStore;

  /// No description provided for @workshopMaterialSetupHubDesc.
  ///
  /// In zh, this message translates to:
  /// **'开启车间整批领料、机台与容器、上线准备 (产品的颗粒与单个重量)'**
  String get workshopMaterialSetupHubDesc;

  /// No description provided for @workshopMaterialReportsHubDesc.
  ///
  /// In zh, this message translates to:
  /// **'按期间看盘点推算耗用、耗用差异率与结算状态'**
  String get workshopMaterialReportsHubDesc;

  /// No description provided for @wmReceiveReturn.
  ///
  /// In zh, this message translates to:
  /// **'收退回'**
  String get wmReceiveReturn;

  /// No description provided for @wmIssueByRequest.
  ///
  /// In zh, this message translates to:
  /// **'按申请发料'**
  String get wmIssueByRequest;

  /// No description provided for @wmOnHand.
  ///
  /// In zh, this message translates to:
  /// **'现存'**
  String get wmOnHand;

  /// No description provided for @wmInUseMaterial.
  ///
  /// In zh, this message translates to:
  /// **'在用料'**
  String get wmInUseMaterial;

  /// No description provided for @wmBagMaterials.
  ///
  /// In zh, this message translates to:
  /// **'袋料'**
  String get wmBagMaterials;

  /// No description provided for @wmEnableWorkshopTab.
  ///
  /// In zh, this message translates to:
  /// **'车间开启'**
  String get wmEnableWorkshopTab;

  /// No description provided for @wmReportPeriod.
  ///
  /// In zh, this message translates to:
  /// **'期间'**
  String get wmReportPeriod;

  /// No description provided for @wmReportAllPeriods.
  ///
  /// In zh, this message translates to:
  /// **'全部期间'**
  String get wmReportAllPeriods;

  /// No description provided for @wmReportMaterial.
  ///
  /// In zh, this message translates to:
  /// **'料'**
  String get wmReportMaterial;

  /// No description provided for @wmReportNoBin.
  ///
  /// In zh, this message translates to:
  /// **'还没有车间开启整批领料，暂时没有内料仓用量可看。'**
  String get wmReportNoBin;

  /// No description provided for @wmOpenBom.
  ///
  /// In zh, this message translates to:
  /// **'打开 BOM'**
  String get wmOpenBom;

  /// No description provided for @wmWorkshopMaterialSection.
  ///
  /// In zh, this message translates to:
  /// **'车间用料'**
  String get wmWorkshopMaterialSection;

  /// No description provided for @wmIssueMethodUpdated.
  ///
  /// In zh, this message translates to:
  /// **'发料方式已更新'**
  String get wmIssueMethodUpdated;

  /// No description provided for @bomLearningAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动更新 BOM'**
  String get bomLearningAuto;

  /// No description provided for @bomLearningAverage.
  ///
  /// In zh, this message translates to:
  /// **'每件平均用量'**
  String get bomLearningAverage;

  /// No description provided for @warehouseGoodsMasterDefaultHint.
  ///
  /// In zh, this message translates to:
  /// **'已带入货品主档的默认存放仓，请核对本次实际仓库'**
  String get warehouseGoodsMasterDefaultHint;

  /// No description provided for @warehouseSuggestedDestinationHint.
  ///
  /// In zh, this message translates to:
  /// **'已带入建议存放仓，请核对本次实际仓库'**
  String get warehouseSuggestedDestinationHint;

  /// No description provided for @warehouseBatchRegistrationHelp.
  ///
  /// In zh, this message translates to:
  /// **'成品仓、库位号逐行必填；优先带入货品主档默认仓，缺项再参考个人选仓上下文。勾选多行后改仓或填写库位可批量应用。每张报工单各生成一份送检，品质放行后再最终点收。'**
  String get warehouseBatchRegistrationHelp;

  /// No description provided for @goodsNameEnLabel.
  ///
  /// In zh, this message translates to:
  /// **'英文名称'**
  String get goodsNameEnLabel;

  /// No description provided for @goodsNameEnHint.
  ///
  /// In zh, this message translates to:
  /// **'如 DOUBLE 3 PIN SOCKET WITH SWITCH'**
  String get goodsNameEnHint;

  /// No description provided for @goodsNameEnInfo.
  ///
  /// In zh, this message translates to:
  /// **'客户报价单或订货单上对这个货品的英文叫法。识别客户文件时, 系统用它把英文品名对应到这个货品。'**
  String get goodsNameEnInfo;

  /// No description provided for @goodsNameEnColumnInfo.
  ///
  /// In zh, this message translates to:
  /// **'客户文件里对这个货品的英文叫法。销售保存带英文品名的单据时会自动记住, 也可以在货品详情里修改。'**
  String get goodsNameEnColumnInfo;

  /// No description provided for @goodsNameEnSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索货品(名称/英文名称/编号/型号/规格/系列)'**
  String get goodsNameEnSearchHint;

  /// No description provided for @goodsNameEnLearned.
  ///
  /// In zh, this message translates to:
  /// **'系统自动记住'**
  String get goodsNameEnLearned;

  /// No description provided for @goodsNameEnLearnedTip.
  ///
  /// In zh, this message translates to:
  /// **'这是销售保存客户文件时系统自动记住的英文名称, 不对可以直接修改。'**
  String get goodsNameEnLearnedTip;

  /// No description provided for @goodsNameEnEdit.
  ///
  /// In zh, this message translates to:
  /// **'修改英文名称'**
  String get goodsNameEnEdit;

  /// No description provided for @goodsNameEnEditDescription.
  ///
  /// In zh, this message translates to:
  /// **'填客户文件上写的英文品名。保存后, 以后识别客户文件都按这个名称对应到本货品。留空表示不用英文名称。'**
  String get goodsNameEnEditDescription;

  /// No description provided for @goodsNameEnSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存…'**
  String get goodsNameEnSaving;

  /// No description provided for @goodsNameEnSaved.
  ///
  /// In zh, this message translates to:
  /// **'英文名称已保存'**
  String get goodsNameEnSaved;

  /// No description provided for @goodsNameEnCleared.
  ///
  /// In zh, this message translates to:
  /// **'英文名称已清除'**
  String get goodsNameEnCleared;

  /// No description provided for @goodsNameEnImportHint.
  ///
  /// In zh, this message translates to:
  /// **'英文名称也可以导入 (表头写「英文名称」或「English Name」)。'**
  String get goodsNameEnImportHint;

  /// No description provided for @goodsNameEnTooLong.
  ///
  /// In zh, this message translates to:
  /// **'英文名称最多 {max} 个字'**
  String goodsNameEnTooLong(int max);

  /// No description provided for @clientNameEnLabel.
  ///
  /// In zh, this message translates to:
  /// **'外文名称'**
  String get clientNameEnLabel;

  /// No description provided for @clientNameEnHint.
  ///
  /// In zh, this message translates to:
  /// **'如 SUNAS TRADING LIMITED'**
  String get clientNameEnHint;

  /// No description provided for @clientNameEnInfo.
  ///
  /// In zh, this message translates to:
  /// **'客户公司的英文或其他外文名称。识别客户文件时, 系统用它找到这个客户; 销售保存单据时也会自动补上。'**
  String get clientNameEnInfo;

  /// No description provided for @clientNameEnSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索客户(简称/编码/全称/外文名称/联系人/手机/邮箱)'**
  String get clientNameEnSearchHint;

  /// No description provided for @clientGoodsAliasTab.
  ///
  /// In zh, this message translates to:
  /// **'货品对照'**
  String get clientGoodsAliasTab;

  /// No description provided for @clientGoodsAliasTitle.
  ///
  /// In zh, this message translates to:
  /// **'客户对货品的叫法'**
  String get clientGoodsAliasTitle;

  /// No description provided for @clientGoodsAliasDescription.
  ///
  /// In zh, this message translates to:
  /// **'客户报价单、订货单上的型号和品名, 对应到我们的哪个货品。识别这个客户的文件时, 系统优先按这里对应。'**
  String get clientGoodsAliasDescription;

  /// No description provided for @clientGoodsAliasSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索客户的叫法、货品名称或编号'**
  String get clientGoodsAliasSearchHint;

  /// No description provided for @clientGoodsAliasEmptyTitle.
  ///
  /// In zh, this message translates to:
  /// **'还没有货品对照'**
  String get clientGoodsAliasEmptyTitle;

  /// No description provided for @clientGoodsAliasEmpty.
  ///
  /// In zh, this message translates to:
  /// **'保存带有文件型号的报价单或订货单后, 这里会自动记住客户的叫法'**
  String get clientGoodsAliasEmpty;

  /// No description provided for @clientGoodsAliasNoMatch.
  ///
  /// In zh, this message translates to:
  /// **'没有找到相关的对照, 换个关键词试试'**
  String get clientGoodsAliasNoMatch;

  /// No description provided for @clientGoodsAliasKindPartNo.
  ///
  /// In zh, this message translates to:
  /// **'客户型号'**
  String get clientGoodsAliasKindPartNo;

  /// No description provided for @clientGoodsAliasKindDescription.
  ///
  /// In zh, this message translates to:
  /// **'客户品名'**
  String get clientGoodsAliasKindDescription;

  /// No description provided for @clientGoodsAliasContext.
  ///
  /// In zh, this message translates to:
  /// **'适用于 {context}'**
  String clientGoodsAliasContext(String context);

  /// No description provided for @clientGoodsAliasConfirmCount.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{已确认 {count} 次}}'**
  String clientGoodsAliasConfirmCount(int count);

  /// No description provided for @clientGoodsAliasExplicitCount.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{其中 {count} 次是手工选的}}'**
  String clientGoodsAliasExplicitCount(int count);

  /// No description provided for @clientGoodsAliasLastConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'最近 {date}'**
  String clientGoodsAliasLastConfirmed(String date);

  /// No description provided for @clientGoodsAliasLastConfirmedBy.
  ///
  /// In zh, this message translates to:
  /// **'最近 {date} · {name}'**
  String clientGoodsAliasLastConfirmedBy(String date, String name);

  /// No description provided for @clientGoodsAliasGoodsMissing.
  ///
  /// In zh, this message translates to:
  /// **'货品资料已删除'**
  String get clientGoodsAliasGoodsMissing;

  /// No description provided for @clientGoodsAliasDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除这条对照'**
  String get clientGoodsAliasDelete;

  /// No description provided for @clientGoodsAliasDeleteAction.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get clientGoodsAliasDeleteAction;

  /// No description provided for @clientGoodsAliasDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'删除后, 识别这个客户的文件时不再把「{alias}」对应到「{goods}」。以后销售保存单据时, 系统可能会重新记住。'**
  String clientGoodsAliasDeleteConfirm(String alias, String goods);

  /// No description provided for @clientGoodsAliasDeleting.
  ///
  /// In zh, this message translates to:
  /// **'正在删除对照'**
  String get clientGoodsAliasDeleting;

  /// No description provided for @clientGoodsAliasDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除这条对照'**
  String get clientGoodsAliasDeleted;

  /// No description provided for @clientGoodsAliasLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'货品对照没有加载出来, 请重试'**
  String get clientGoodsAliasLoadFailed;

  /// No description provided for @clientGoodsAliasTotal.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{共 {count} 条}}'**
  String clientGoodsAliasTotal(int count);

  /// No description provided for @clientGoodsAliasPage.
  ///
  /// In zh, this message translates to:
  /// **'第 {page} / {pages} 页'**
  String clientGoodsAliasPage(int page, int pages);

  /// No description provided for @clientGoodsAliasPrevPage.
  ///
  /// In zh, this message translates to:
  /// **'上一页'**
  String get clientGoodsAliasPrevPage;

  /// No description provided for @clientGoodsAliasNextPage.
  ///
  /// In zh, this message translates to:
  /// **'下一页'**
  String get clientGoodsAliasNextPage;

  /// No description provided for @aiJobCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get aiJobCancel;

  /// No description provided for @aiJobElapsed.
  ///
  /// In zh, this message translates to:
  /// **'已用时 {time}'**
  String aiJobElapsed(String time);

  /// No description provided for @aiJobQueued.
  ///
  /// In zh, this message translates to:
  /// **'正在排队, 马上开始'**
  String get aiJobQueued;

  /// No description provided for @aiJobSlowHint.
  ///
  /// In zh, this message translates to:
  /// **'内容较多时需要一两分钟, 请耐心等待, 不用重复点'**
  String get aiJobSlowHint;

  /// No description provided for @aiJobTimeout.
  ///
  /// In zh, this message translates to:
  /// **'处理时间太长, 已停止等待。请稍后再试, 或把文件拆小一些'**
  String get aiJobTimeout;

  /// No description provided for @aiJobGone.
  ///
  /// In zh, this message translates to:
  /// **'这次处理的任务已不存在(可能已被清理), 请重新开始'**
  String get aiJobGone;

  /// No description provided for @aiJobFailedGeneric.
  ///
  /// In zh, this message translates to:
  /// **'处理没有成功, 请稍后重试'**
  String get aiJobFailedGeneric;

  /// No description provided for @aiJobConfidenceHigh.
  ///
  /// In zh, this message translates to:
  /// **'把握高'**
  String get aiJobConfidenceHigh;

  /// No description provided for @aiJobConfidenceMedium.
  ///
  /// In zh, this message translates to:
  /// **'把握中'**
  String get aiJobConfidenceMedium;

  /// No description provided for @aiJobConfidenceLow.
  ///
  /// In zh, this message translates to:
  /// **'把握低'**
  String get aiJobConfidenceLow;

  /// No description provided for @aiJobConfidenceSemantics.
  ///
  /// In zh, this message translates to:
  /// **'AI 判断把握: {level}'**
  String aiJobConfidenceSemantics(String level);

  /// No description provided for @aiSettingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'AI 服务'**
  String get aiSettingsTitle;

  /// No description provided for @aiSettingsEntrySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'配置大模型服务商、密钥和连接测试'**
  String get aiSettingsEntrySubtitle;

  /// No description provided for @aiSettingsHeroActive.
  ///
  /// In zh, this message translates to:
  /// **'正在使用: {name} · {model}'**
  String aiSettingsHeroActive(String name, String model);

  /// No description provided for @aiSettingsHeroReady.
  ///
  /// In zh, this message translates to:
  /// **'销售上传客户文件时会用它自动识别'**
  String get aiSettingsHeroReady;

  /// No description provided for @aiSettingsHeroNone.
  ///
  /// In zh, this message translates to:
  /// **'还没有可用的 AI 服务'**
  String get aiSettingsHeroNone;

  /// No description provided for @aiSettingsHeroNoneHint.
  ///
  /// In zh, this message translates to:
  /// **'添加一个服务商并测试通过后, 销售上传客户文件就能自动识别'**
  String get aiSettingsHeroNoneHint;

  /// No description provided for @aiSettingsHeroDefaultDisabled.
  ///
  /// In zh, this message translates to:
  /// **'默认服务已停用, 目前不会调用 AI'**
  String get aiSettingsHeroDefaultDisabled;

  /// No description provided for @aiSettingsHeroNeedsKey.
  ///
  /// In zh, this message translates to:
  /// **'还没有填写密钥, 目前不会调用 AI'**
  String get aiSettingsHeroNeedsKey;

  /// No description provided for @aiSettingsSecurityNote.
  ///
  /// In zh, this message translates to:
  /// **'密钥加密保存, 页面只显示尾号; 保存、删除和用已存密钥测试都要再次确认登录密码。'**
  String get aiSettingsSecurityNote;

  /// No description provided for @aiSettingsOutboundOff.
  ///
  /// In zh, this message translates to:
  /// **'这台服务器关闭了对外调用 AI(测试环境默认如此), 配置可以保存, 但不会真正调用'**
  String get aiSettingsOutboundOff;

  /// No description provided for @aiSettingsProvidersSection.
  ///
  /// In zh, this message translates to:
  /// **'服务商'**
  String get aiSettingsProvidersSection;

  /// No description provided for @aiSettingsAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加 AI 服务'**
  String get aiSettingsAdd;

  /// No description provided for @aiSettingsEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑 AI 服务'**
  String get aiSettingsEditTitle;

  /// No description provided for @aiSettingsEmptyTitle.
  ///
  /// In zh, this message translates to:
  /// **'还没有配置 AI 服务'**
  String get aiSettingsEmptyTitle;

  /// No description provided for @aiSettingsEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'支持 DeepSeek、通义千问、Kimi、智谱等国内服务商, 也可以接本机部署的模型'**
  String get aiSettingsEmptyHint;

  /// No description provided for @aiSettingsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载 AI 服务设置失败'**
  String get aiSettingsLoadFailed;

  /// No description provided for @aiSettingsNoAccess.
  ///
  /// In zh, this message translates to:
  /// **'只有超级管理员可以查看和修改 AI 服务'**
  String get aiSettingsNoAccess;

  /// No description provided for @aiSettingsRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get aiSettingsRetry;

  /// No description provided for @aiSettingsRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get aiSettingsRefresh;

  /// No description provided for @aiSettingsClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get aiSettingsClose;

  /// No description provided for @aiSettingsCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get aiSettingsCancel;

  /// No description provided for @aiSettingsRegion.
  ///
  /// In zh, this message translates to:
  /// **'所在区域'**
  String get aiSettingsRegion;

  /// No description provided for @aiSettingsRegionMainland.
  ///
  /// In zh, this message translates to:
  /// **'国内'**
  String get aiSettingsRegionMainland;

  /// No description provided for @aiSettingsRegionOverseas.
  ///
  /// In zh, this message translates to:
  /// **'境外'**
  String get aiSettingsRegionOverseas;

  /// No description provided for @aiSettingsRegionLocal.
  ///
  /// In zh, this message translates to:
  /// **'本机'**
  String get aiSettingsRegionLocal;

  /// No description provided for @aiSettingsDefaultBadge.
  ///
  /// In zh, this message translates to:
  /// **'默认'**
  String get aiSettingsDefaultBadge;

  /// No description provided for @aiSettingsDisabledBadge.
  ///
  /// In zh, this message translates to:
  /// **'已停用'**
  String get aiSettingsDisabledBadge;

  /// No description provided for @aiSettingsModel.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get aiSettingsModel;

  /// No description provided for @aiSettingsBaseUrl.
  ///
  /// In zh, this message translates to:
  /// **'接口地址'**
  String get aiSettingsBaseUrl;

  /// No description provided for @aiSettingsApiKey.
  ///
  /// In zh, this message translates to:
  /// **'密钥'**
  String get aiSettingsApiKey;

  /// No description provided for @aiSettingsKeyMissing.
  ///
  /// In zh, this message translates to:
  /// **'未配置'**
  String get aiSettingsKeyMissing;

  /// No description provided for @aiSettingsKeyNotNeeded.
  ///
  /// In zh, this message translates to:
  /// **'不需要'**
  String get aiSettingsKeyNotNeeded;

  /// No description provided for @aiSettingsKeyUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'密钥无法解密, 请重新填写'**
  String get aiSettingsKeyUnreadable;

  /// No description provided for @aiSettingsLastTest.
  ///
  /// In zh, this message translates to:
  /// **'上次测试'**
  String get aiSettingsLastTest;

  /// No description provided for @aiSettingsLastTestOk.
  ///
  /// In zh, this message translates to:
  /// **'通过 · {time}'**
  String aiSettingsLastTestOk(String time);

  /// No description provided for @aiSettingsLastTestFailed.
  ///
  /// In zh, this message translates to:
  /// **'未通过 · {time}'**
  String aiSettingsLastTestFailed(String time);

  /// No description provided for @aiSettingsNeverTested.
  ///
  /// In zh, this message translates to:
  /// **'还没测试过'**
  String get aiSettingsNeverTested;

  /// No description provided for @aiSettingsEnabledSwitch.
  ///
  /// In zh, this message translates to:
  /// **'启用'**
  String get aiSettingsEnabledSwitch;

  /// No description provided for @aiSettingsEnabledInfo.
  ///
  /// In zh, this message translates to:
  /// **'停用后不会调用这个服务'**
  String get aiSettingsEnabledInfo;

  /// No description provided for @aiSettingsTest.
  ///
  /// In zh, this message translates to:
  /// **'测试连接'**
  String get aiSettingsTest;

  /// No description provided for @aiSettingsTesting.
  ///
  /// In zh, this message translates to:
  /// **'正在测试'**
  String get aiSettingsTesting;

  /// No description provided for @aiSettingsEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get aiSettingsEdit;

  /// No description provided for @aiSettingsSetDefault.
  ///
  /// In zh, this message translates to:
  /// **'设为默认'**
  String get aiSettingsSetDefault;

  /// No description provided for @aiSettingsDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get aiSettingsDelete;

  /// No description provided for @aiSettingsDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除这个 AI 服务?'**
  String get aiSettingsDeleteTitle;

  /// No description provided for @aiSettingsDeleteMessage.
  ///
  /// In zh, this message translates to:
  /// **'删除后「{name}」的配置和密钥都会清除, 不能恢复。'**
  String aiSettingsDeleteMessage(String name);

  /// No description provided for @aiSettingsDeleteDefaultBlocked.
  ///
  /// In zh, this message translates to:
  /// **'默认服务不能删除, 请先把别的服务设为默认'**
  String get aiSettingsDeleteDefaultBlocked;

  /// No description provided for @aiSettingsDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get aiSettingsDeleted;

  /// No description provided for @aiSettingsDefaultSet.
  ///
  /// In zh, this message translates to:
  /// **'已把「{name}」设为默认'**
  String aiSettingsDefaultSet(String name);

  /// No description provided for @aiSettingsEnabledOn.
  ///
  /// In zh, this message translates to:
  /// **'已启用「{name}」'**
  String aiSettingsEnabledOn(String name);

  /// No description provided for @aiSettingsEnabledOff.
  ///
  /// In zh, this message translates to:
  /// **'已停用「{name}」'**
  String aiSettingsEnabledOff(String name);

  /// No description provided for @aiSettingsBusySaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存'**
  String get aiSettingsBusySaving;

  /// No description provided for @aiSettingsBusyDeleting.
  ///
  /// In zh, this message translates to:
  /// **'正在删除'**
  String get aiSettingsBusyDeleting;

  /// No description provided for @aiSettingsUpdatedBy.
  ///
  /// In zh, this message translates to:
  /// **'{name} 修改于 {time}'**
  String aiSettingsUpdatedBy(String name, String time);

  /// No description provided for @aiSettingsTestNeedsKeyEdit.
  ///
  /// In zh, this message translates to:
  /// **'还没有密钥, 请先点「编辑」填写密钥再测试'**
  String get aiSettingsTestNeedsKeyEdit;

  /// No description provided for @aiSettingsUsageTitle.
  ///
  /// In zh, this message translates to:
  /// **'近 {days} 天用量'**
  String aiSettingsUsageTitle(int days);

  /// No description provided for @aiSettingsUsageCalls.
  ///
  /// In zh, this message translates to:
  /// **'调用次数'**
  String get aiSettingsUsageCalls;

  /// No description provided for @aiSettingsUsageSuccessRate.
  ///
  /// In zh, this message translates to:
  /// **'成功率'**
  String get aiSettingsUsageSuccessRate;

  /// No description provided for @aiSettingsUsageTokens.
  ///
  /// In zh, this message translates to:
  /// **'输入 / 输出 token'**
  String get aiSettingsUsageTokens;

  /// No description provided for @aiSettingsUsageLatency.
  ///
  /// In zh, this message translates to:
  /// **'平均耗时'**
  String get aiSettingsUsageLatency;

  /// No description provided for @aiSettingsUsageSeconds.
  ///
  /// In zh, this message translates to:
  /// **'{value} 秒'**
  String aiSettingsUsageSeconds(String value);

  /// No description provided for @aiSettingsUsageEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有调用记录'**
  String get aiSettingsUsageEmpty;

  /// No description provided for @aiSettingsUsageUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'用量暂时读不到, 不影响使用'**
  String get aiSettingsUsageUnavailable;

  /// No description provided for @aiSettingsPreset.
  ///
  /// In zh, this message translates to:
  /// **'服务商'**
  String get aiSettingsPreset;

  /// No description provided for @aiSettingsPresetInfo.
  ///
  /// In zh, this message translates to:
  /// **'选好服务商会自动填好接口地址和推荐设置, 每一项都还能改'**
  String get aiSettingsPresetInfo;

  /// No description provided for @aiSettingsPresetOverseasOff.
  ///
  /// In zh, this message translates to:
  /// **'{label} (境外, 未开放)'**
  String aiSettingsPresetOverseasOff(String label);

  /// No description provided for @aiSettingsOverseasOffHint.
  ///
  /// In zh, this message translates to:
  /// **'境外服务商默认关闭。如需使用, 请联系部署人员在服务器配置中开启, 并完成数据出境评估'**
  String get aiSettingsOverseasOffHint;

  /// No description provided for @aiSettingsPresetUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'{label} (暂不可用)'**
  String aiSettingsPresetUnavailable(String label);

  /// No description provided for @aiSettingsName.
  ///
  /// In zh, this message translates to:
  /// **'显示名称'**
  String get aiSettingsName;

  /// No description provided for @aiSettingsNameHint.
  ///
  /// In zh, this message translates to:
  /// **'例如: DeepSeek 正式账号'**
  String get aiSettingsNameHint;

  /// No description provided for @aiSettingsNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写显示名称'**
  String get aiSettingsNameRequired;

  /// No description provided for @aiSettingsTooLong.
  ///
  /// In zh, this message translates to:
  /// **'最多 {max} 个字符'**
  String aiSettingsTooLong(int max);

  /// No description provided for @aiSettingsBaseUrlInfo.
  ///
  /// In zh, this message translates to:
  /// **'服务商文档里的 Base URL; 只能用 https, 本机部署可以用 http://127.0.0.1'**
  String get aiSettingsBaseUrlInfo;

  /// No description provided for @aiSettingsBaseUrlRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写接口地址'**
  String get aiSettingsBaseUrlRequired;

  /// No description provided for @aiSettingsBaseUrlInvalid.
  ///
  /// In zh, this message translates to:
  /// **'接口地址格式不对, 应以 https:// 开头, 不带问号后面的参数'**
  String get aiSettingsBaseUrlInvalid;

  /// No description provided for @aiSettingsBaseUrlHttpLocalOnly.
  ///
  /// In zh, this message translates to:
  /// **'只有本机部署可以用 http, 其他服务商请用 https'**
  String get aiSettingsBaseUrlHttpLocalOnly;

  /// No description provided for @aiSettingsModelHint.
  ///
  /// In zh, this message translates to:
  /// **'填模型名称, 或点「获取模型」从列表选'**
  String get aiSettingsModelHint;

  /// No description provided for @aiSettingsModelRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写模型名称'**
  String get aiSettingsModelRequired;

  /// No description provided for @aiSettingsFetchModels.
  ///
  /// In zh, this message translates to:
  /// **'获取模型'**
  String get aiSettingsFetchModels;

  /// No description provided for @aiSettingsPickModel.
  ///
  /// In zh, this message translates to:
  /// **'从列表选择模型'**
  String get aiSettingsPickModel;

  /// No description provided for @aiSettingsModelsLoaded.
  ///
  /// In zh, this message translates to:
  /// **'找到 {count} 个模型'**
  String aiSettingsModelsLoaded(int count);

  /// No description provided for @aiSettingsModelsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'服务商没有返回模型列表, 请直接填写模型名称'**
  String get aiSettingsModelsEmpty;

  /// No description provided for @aiSettingsApiKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'粘贴服务商后台生成的密钥'**
  String get aiSettingsApiKeyHint;

  /// No description provided for @aiSettingsApiKeyNotNeededHint.
  ///
  /// In zh, this message translates to:
  /// **'本机部署通常不需要密钥, 可以留空'**
  String get aiSettingsApiKeyNotNeededHint;

  /// No description provided for @aiSettingsApiKeyRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写密钥'**
  String get aiSettingsApiKeyRequired;

  /// No description provided for @aiSettingsClearKey.
  ///
  /// In zh, this message translates to:
  /// **'清除密钥'**
  String get aiSettingsClearKey;

  /// No description provided for @aiSettingsUndoClear.
  ///
  /// In zh, this message translates to:
  /// **'撤销清除'**
  String get aiSettingsUndoClear;

  /// No description provided for @aiSettingsKeyWillClear.
  ///
  /// In zh, this message translates to:
  /// **'保存后会清除已存的密钥'**
  String get aiSettingsKeyWillClear;

  /// No description provided for @aiSettingsUrlChangedNeedKey.
  ///
  /// In zh, this message translates to:
  /// **'改了接口地址, 需要重新填写密钥'**
  String get aiSettingsUrlChangedNeedKey;

  /// No description provided for @aiSettingsUrlChangedNeedKeyDetail.
  ///
  /// In zh, this message translates to:
  /// **'为了安全, 已存的密钥只会发给原来的地址。请重新粘贴密钥后再保存。'**
  String get aiSettingsUrlChangedNeedKeyDetail;

  /// No description provided for @aiSettingsUrlChangedNeedKeyLocalDetail.
  ///
  /// In zh, this message translates to:
  /// **'为了安全, 已存的密钥只会发给原来的地址。请重新粘贴密钥; 新地址不需要密钥的, 点「清除密钥」。'**
  String get aiSettingsUrlChangedNeedKeyLocalDetail;

  /// No description provided for @aiSettingsAdvanced.
  ///
  /// In zh, this message translates to:
  /// **'高级设置'**
  String get aiSettingsAdvanced;

  /// No description provided for @aiSettingsProtocol.
  ///
  /// In zh, this message translates to:
  /// **'接口协议'**
  String get aiSettingsProtocol;

  /// No description provided for @aiSettingsProtocolInfo.
  ///
  /// In zh, this message translates to:
  /// **'国内服务商和本机部署基本都是 OpenAI 兼容; 只有 Claude 用 Anthropic'**
  String get aiSettingsProtocolInfo;

  /// No description provided for @aiSettingsProtocolOpenAi.
  ///
  /// In zh, this message translates to:
  /// **'OpenAI 兼容'**
  String get aiSettingsProtocolOpenAi;

  /// No description provided for @aiSettingsProtocolAnthropic.
  ///
  /// In zh, this message translates to:
  /// **'Anthropic'**
  String get aiSettingsProtocolAnthropic;

  /// No description provided for @aiSettingsJsonMode.
  ///
  /// In zh, this message translates to:
  /// **'JSON 输出方式'**
  String get aiSettingsJsonMode;

  /// No description provided for @aiSettingsJsonModeInfo.
  ///
  /// In zh, this message translates to:
  /// **'要求模型只回一段 JSON, 系统才能读懂结果; 服务商不支持时选「不要求」'**
  String get aiSettingsJsonModeInfo;

  /// No description provided for @aiSettingsJsonModeNone.
  ///
  /// In zh, this message translates to:
  /// **'不要求'**
  String get aiSettingsJsonModeNone;

  /// No description provided for @aiSettingsJsonModeObject.
  ///
  /// In zh, this message translates to:
  /// **'JSON 对象'**
  String get aiSettingsJsonModeObject;

  /// No description provided for @aiSettingsJsonModeSchema.
  ///
  /// In zh, this message translates to:
  /// **'按结构输出'**
  String get aiSettingsJsonModeSchema;

  /// No description provided for @aiSettingsThinking.
  ///
  /// In zh, this message translates to:
  /// **'关闭深度思考'**
  String get aiSettingsThinking;

  /// No description provided for @aiSettingsThinkingInfo.
  ///
  /// In zh, this message translates to:
  /// **'识别表格不需要深度思考, 关掉更快更省钱; 各服务商写法不同, 选好服务商会自动选对'**
  String get aiSettingsThinkingInfo;

  /// No description provided for @aiSettingsThinkingNone.
  ///
  /// In zh, this message translates to:
  /// **'不处理'**
  String get aiSettingsThinkingNone;

  /// No description provided for @aiSettingsThinkingDeepseek.
  ///
  /// In zh, this message translates to:
  /// **'DeepSeek 写法'**
  String get aiSettingsThinkingDeepseek;

  /// No description provided for @aiSettingsThinkingDashscope.
  ///
  /// In zh, this message translates to:
  /// **'通义千问写法'**
  String get aiSettingsThinkingDashscope;

  /// No description provided for @aiSettingsThinkingOpenAi.
  ///
  /// In zh, this message translates to:
  /// **'OpenAI 写法'**
  String get aiSettingsThinkingOpenAi;

  /// No description provided for @aiSettingsTemperature.
  ///
  /// In zh, this message translates to:
  /// **'固定输出(温度为 0)'**
  String get aiSettingsTemperature;

  /// No description provided for @aiSettingsTemperatureInfo.
  ///
  /// In zh, this message translates to:
  /// **'同一份文件每次识别结果尽量一致; 个别模型不接受这个参数时关掉'**
  String get aiSettingsTemperatureInfo;

  /// No description provided for @aiSettingsVision.
  ///
  /// In zh, this message translates to:
  /// **'能识别图片和扫描件'**
  String get aiSettingsVision;

  /// No description provided for @aiSettingsVisionInfo.
  ///
  /// In zh, this message translates to:
  /// **'模型支持看图时打开, 销售上传的照片和扫描版 PDF 才能识别'**
  String get aiSettingsVisionInfo;

  /// No description provided for @aiSettingsMaxTokens.
  ///
  /// In zh, this message translates to:
  /// **'最大输出长度'**
  String get aiSettingsMaxTokens;

  /// No description provided for @aiSettingsMaxTokensInfo.
  ///
  /// In zh, this message translates to:
  /// **'256 ~ 65536; 行数多的文件需要更长'**
  String get aiSettingsMaxTokensInfo;

  /// No description provided for @aiSettingsTimeout.
  ///
  /// In zh, this message translates to:
  /// **'超时秒数'**
  String get aiSettingsTimeout;

  /// No description provided for @aiSettingsTimeoutInfo.
  ///
  /// In zh, this message translates to:
  /// **'10 ~ 600; 超过这个时间还没回复就算失败'**
  String get aiSettingsTimeoutInfo;

  /// No description provided for @aiSettingsNumberRange.
  ///
  /// In zh, this message translates to:
  /// **'请输入 {min} ~ {max} 之间的整数'**
  String aiSettingsNumberRange(int min, int max);

  /// No description provided for @aiSettingsOverseasAck.
  ///
  /// In zh, this message translates to:
  /// **'客户资料(公司名、货品描述)会发送到境外服务商, 我已确认完成数据出境评估'**
  String get aiSettingsOverseasAck;

  /// No description provided for @aiSettingsOverseasAckRequired.
  ///
  /// In zh, this message translates to:
  /// **'使用境外服务商前请先勾选上面的确认'**
  String get aiSettingsOverseasAckRequired;

  /// No description provided for @aiSettingsSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get aiSettingsSave;

  /// No description provided for @aiSettingsSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存'**
  String get aiSettingsSaving;

  /// No description provided for @aiSettingsSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get aiSettingsSaved;

  /// No description provided for @aiSettingsSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败, 请稍后重试'**
  String get aiSettingsSaveFailed;

  /// No description provided for @aiSettingsFixFields.
  ///
  /// In zh, this message translates to:
  /// **'请先改好标红的项'**
  String get aiSettingsFixFields;

  /// No description provided for @aiSettingsTestNeedsKey.
  ///
  /// In zh, this message translates to:
  /// **'测试前请先填写密钥'**
  String get aiSettingsTestNeedsKey;

  /// No description provided for @aiSettingsTestStoredMismatch.
  ///
  /// In zh, this message translates to:
  /// **'用已存的密钥测试时, 接口地址和模型要与已保存的一致。请先保存, 或重新填写密钥再测试'**
  String get aiSettingsTestStoredMismatch;

  /// No description provided for @aiSettingsTestResultTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接测试'**
  String get aiSettingsTestResultTitle;

  /// No description provided for @aiSettingsStepNetwork.
  ///
  /// In zh, this message translates to:
  /// **'网络连通'**
  String get aiSettingsStepNetwork;

  /// No description provided for @aiSettingsStepAuth.
  ///
  /// In zh, this message translates to:
  /// **'密钥验证'**
  String get aiSettingsStepAuth;

  /// No description provided for @aiSettingsStepModel.
  ///
  /// In zh, this message translates to:
  /// **'模型可用'**
  String get aiSettingsStepModel;

  /// No description provided for @aiSettingsStepJson.
  ///
  /// In zh, this message translates to:
  /// **'JSON 输出'**
  String get aiSettingsStepJson;

  /// No description provided for @aiSettingsStepSkipped.
  ///
  /// In zh, this message translates to:
  /// **'未进行'**
  String get aiSettingsStepSkipped;

  /// No description provided for @aiSettingsLatency.
  ///
  /// In zh, this message translates to:
  /// **'{ms} 毫秒'**
  String aiSettingsLatency(int ms);

  /// No description provided for @aiSettingsTestPassed.
  ///
  /// In zh, this message translates to:
  /// **'连接正常, 可以使用'**
  String get aiSettingsTestPassed;

  /// No description provided for @aiSettingsTestPassedShort.
  ///
  /// In zh, this message translates to:
  /// **'通过'**
  String get aiSettingsTestPassedShort;

  /// No description provided for @aiSettingsTestFailed.
  ///
  /// In zh, this message translates to:
  /// **'连接没有通过, 请按提示检查后再试'**
  String get aiSettingsTestFailed;

  /// No description provided for @aiSettingsTestFailedShort.
  ///
  /// In zh, this message translates to:
  /// **'未通过'**
  String get aiSettingsTestFailedShort;

  /// No description provided for @aiSettingsTestWarnShort.
  ///
  /// In zh, this message translates to:
  /// **'需留意'**
  String get aiSettingsTestWarnShort;

  /// No description provided for @aiSettingsTestPassedWithNotes.
  ///
  /// In zh, this message translates to:
  /// **'连上了, 但有需要留意的地方, 请看上面的黄色提示'**
  String get aiSettingsTestPassedWithNotes;

  /// No description provided for @aiSettingsTestStoredUnsavedAdvanced.
  ///
  /// In zh, this message translates to:
  /// **'高级设置改过了, 用已存的密钥测试不会带上这些改动。请先保存再测试, 或重新填写密钥后测试'**
  String get aiSettingsTestStoredUnsavedAdvanced;

  /// No description provided for @aiSettingsModelChoices.
  ///
  /// In zh, this message translates to:
  /// **'可选模型:'**
  String get aiSettingsModelChoices;

  /// No description provided for @aiSettingsOverseasLockedShort.
  ///
  /// In zh, this message translates to:
  /// **'境外服务商暂未开放, 需要部署人员在服务器上开启'**
  String get aiSettingsOverseasLockedShort;

  /// No description provided for @aiSettingsKeyConfiguredPlain.
  ///
  /// In zh, this message translates to:
  /// **'已配置'**
  String get aiSettingsKeyConfiguredPlain;

  /// No description provided for @aiSettingsApiKeyKeepHintPlain.
  ///
  /// In zh, this message translates to:
  /// **'已配置, 不改就留空'**
  String get aiSettingsApiKeyKeepHintPlain;

  /// No description provided for @aiSettingsCurrentKey.
  ///
  /// In zh, this message translates to:
  /// **'当前密钥'**
  String get aiSettingsCurrentKey;

  /// No description provided for @salesQuoteStatusDraft.
  ///
  /// In zh, this message translates to:
  /// **'草稿'**
  String get salesQuoteStatusDraft;

  /// No description provided for @salesQuoteStatusPendingFinance.
  ///
  /// In zh, this message translates to:
  /// **'待财务核价'**
  String get salesQuoteStatusPendingFinance;

  /// No description provided for @salesQuoteStatusReturned.
  ///
  /// In zh, this message translates to:
  /// **'财务退回'**
  String get salesQuoteStatusReturned;

  /// No description provided for @salesQuoteStatusConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已核价'**
  String get salesQuoteStatusConfirmed;

  /// No description provided for @salesQuoteStatusReversed.
  ///
  /// In zh, this message translates to:
  /// **'作废'**
  String get salesQuoteStatusReversed;

  /// No description provided for @salesQuoteStatusConverted.
  ///
  /// In zh, this message translates to:
  /// **'已转订货单'**
  String get salesQuoteStatusConverted;

  /// No description provided for @salesQuoteStatusToConvert.
  ///
  /// In zh, this message translates to:
  /// **'已核价, 待转订货单'**
  String get salesQuoteStatusToConvert;

  /// No description provided for @salesQuoteStatusReadOnly.
  ///
  /// In zh, this message translates to:
  /// **'{status} · 只读'**
  String salesQuoteStatusReadOnly(String status);

  /// No description provided for @salesQuoteStatusHistory.
  ///
  /// In zh, this message translates to:
  /// **'历史记录'**
  String get salesQuoteStatusHistory;

  /// No description provided for @salesQuoteStatusBannerDraft.
  ///
  /// In zh, this message translates to:
  /// **'草稿: 填好后点「提交财务核价」, 财务定好价格和折扣后才能转订货单。'**
  String get salesQuoteStatusBannerDraft;

  /// No description provided for @salesQuoteStatusBannerPending.
  ///
  /// In zh, this message translates to:
  /// **'已提交财务核价, 正在等财务定价格。需要改内容请先「撤回」。'**
  String get salesQuoteStatusBannerPending;

  /// No description provided for @salesQuoteStatusBannerReturned.
  ///
  /// In zh, this message translates to:
  /// **'财务退回: {reason}。改好后再提交财务核价。'**
  String salesQuoteStatusBannerReturned(String reason);

  /// No description provided for @salesQuoteStatusBannerConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'财务已核价({name} · {time}), 可以转订货单了。'**
  String salesQuoteStatusBannerConfirmed(String name, String time);

  /// No description provided for @salesQuoteStatusBannerConverted.
  ///
  /// In zh, this message translates to:
  /// **'已转成订货单 {orderNo}, 报价不能再修改。'**
  String salesQuoteStatusBannerConverted(String orderNo);

  /// No description provided for @salesQuoteStatusBannerReversed.
  ///
  /// In zh, this message translates to:
  /// **'这张报价已作废, 只能查看。'**
  String get salesQuoteStatusBannerReversed;

  /// No description provided for @salesQuoteStatusFinanceFallback.
  ///
  /// In zh, this message translates to:
  /// **'财务'**
  String get salesQuoteStatusFinanceFallback;

  /// No description provided for @salesQuoteStatusFieldReturnReason.
  ///
  /// In zh, this message translates to:
  /// **'退回原因'**
  String get salesQuoteStatusFieldReturnReason;

  /// No description provided for @salesQuoteStatusFieldSubmittedAt.
  ///
  /// In zh, this message translates to:
  /// **'提交核价时间'**
  String get salesQuoteStatusFieldSubmittedAt;

  /// No description provided for @salesQuoteStatusFieldConfirmedBy.
  ///
  /// In zh, this message translates to:
  /// **'核价人'**
  String get salesQuoteStatusFieldConfirmedBy;

  /// No description provided for @salesQuoteStatusFieldConvertedOrder.
  ///
  /// In zh, this message translates to:
  /// **'转入订货单'**
  String get salesQuoteStatusFieldConvertedOrder;

  /// No description provided for @salesQuoteStatusFieldFinanceRemark.
  ///
  /// In zh, this message translates to:
  /// **'财务备注'**
  String get salesQuoteStatusFieldFinanceRemark;

  /// No description provided for @salesQuoteStatusActionSubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交财务核价'**
  String get salesQuoteStatusActionSubmit;

  /// No description provided for @salesQuoteStatusActionWithdraw.
  ///
  /// In zh, this message translates to:
  /// **'撤回'**
  String get salesQuoteStatusActionWithdraw;

  /// No description provided for @salesQuoteStatusActionReopen.
  ///
  /// In zh, this message translates to:
  /// **'重新修改'**
  String get salesQuoteStatusActionReopen;

  /// No description provided for @salesQuoteStatusActionConvert.
  ///
  /// In zh, this message translates to:
  /// **'转订货单'**
  String get salesQuoteStatusActionConvert;

  /// No description provided for @salesQuoteStatusActionReverse.
  ///
  /// In zh, this message translates to:
  /// **'作废'**
  String get salesQuoteStatusActionReverse;

  /// No description provided for @salesQuoteStatusActionEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get salesQuoteStatusActionEdit;

  /// No description provided for @salesQuoteStatusActionDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get salesQuoteStatusActionDelete;

  /// No description provided for @salesQuoteStatusActionFinanceReview.
  ///
  /// In zh, this message translates to:
  /// **'去核价'**
  String get salesQuoteStatusActionFinanceReview;

  /// No description provided for @salesQuoteStatusActionViewOrder.
  ///
  /// In zh, this message translates to:
  /// **'查看订货单'**
  String get salesQuoteStatusActionViewOrder;

  /// No description provided for @salesQuoteStatusActionBack.
  ///
  /// In zh, this message translates to:
  /// **'返回列表'**
  String get salesQuoteStatusActionBack;

  /// No description provided for @salesQuoteStatusSubmitConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'提交后财务会逐行定价格和折扣, 这期间你不能修改这张报价。确定提交?'**
  String get salesQuoteStatusSubmitConfirmBody;

  /// No description provided for @salesQuoteStatusWithdrawConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'撤回后报价回到草稿, 可以继续修改; 改好后需要重新提交财务核价。确定撤回?'**
  String get salesQuoteStatusWithdrawConfirmBody;

  /// No description provided for @salesQuoteStatusReopenConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'财务已经核好价格。重新修改会让报价回到草稿, 改完要再交财务核价才能转订货单。确定重新修改?'**
  String get salesQuoteStatusReopenConfirmBody;

  /// No description provided for @salesQuoteStatusReverseConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'作废后这张报价不能再转订货单, 也不能恢复。确定作废?'**
  String get salesQuoteStatusReverseConfirmBody;

  /// No description provided for @salesQuoteStatusDeleteConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'确定删除这张报价草稿? 删除后不能恢复。'**
  String get salesQuoteStatusDeleteConfirmBody;

  /// No description provided for @salesQuoteStatusConvertConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'根据双方同意的当前报价生成订货单草稿，带入核定单价、折扣及条款。请核对信息后保存、审查并提交财务审核。'**
  String get salesQuoteStatusConvertConfirmBody;

  /// No description provided for @salesQuoteStatusConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get salesQuoteStatusConfirm;

  /// No description provided for @salesQuoteStatusCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get salesQuoteStatusCancel;

  /// No description provided for @salesQuoteStatusSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'已提交财务核价'**
  String get salesQuoteStatusSubmitted;

  /// No description provided for @salesQuoteStatusWithdrawn.
  ///
  /// In zh, this message translates to:
  /// **'已撤回, 可以继续修改'**
  String get salesQuoteStatusWithdrawn;

  /// No description provided for @salesQuoteStatusReopened.
  ///
  /// In zh, this message translates to:
  /// **'已回到草稿, 改好后请重新提交财务核价'**
  String get salesQuoteStatusReopened;

  /// No description provided for @salesQuoteStatusReversedDone.
  ///
  /// In zh, this message translates to:
  /// **'报价已作废'**
  String get salesQuoteStatusReversedDone;

  /// No description provided for @salesQuoteStatusDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get salesQuoteStatusDeleted;

  /// No description provided for @salesQuoteStatusConvertDone.
  ///
  /// In zh, this message translates to:
  /// **'已生成订货单草稿 {billNo}'**
  String salesQuoteStatusConvertDone(String billNo);

  /// No description provided for @salesQuoteStatusActionFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作没有成功, 请稍后再试'**
  String get salesQuoteStatusActionFailed;

  /// No description provided for @salesQuoteStatusBusy.
  ///
  /// In zh, this message translates to:
  /// **'正在处理, 请稍候'**
  String get salesQuoteStatusBusy;

  /// No description provided for @salesQuoteStatusTimelineTitle.
  ///
  /// In zh, this message translates to:
  /// **'核价记录'**
  String get salesQuoteStatusTimelineTitle;

  /// No description provided for @salesQuoteStatusTimelineEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有核价记录'**
  String get salesQuoteStatusTimelineEmpty;

  /// No description provided for @salesQuoteStatusRevisionSubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交财务核价'**
  String get salesQuoteStatusRevisionSubmit;

  /// No description provided for @salesQuoteStatusRevisionWithdraw.
  ///
  /// In zh, this message translates to:
  /// **'销售撤回'**
  String get salesQuoteStatusRevisionWithdraw;

  /// No description provided for @salesQuoteStatusRevisionFinanceEdit.
  ///
  /// In zh, this message translates to:
  /// **'财务修改价格'**
  String get salesQuoteStatusRevisionFinanceEdit;

  /// No description provided for @salesQuoteStatusRevisionReturn.
  ///
  /// In zh, this message translates to:
  /// **'财务退回'**
  String get salesQuoteStatusRevisionReturn;

  /// No description provided for @salesQuoteStatusRevisionConfirm.
  ///
  /// In zh, this message translates to:
  /// **'财务确认报价'**
  String get salesQuoteStatusRevisionConfirm;

  /// No description provided for @salesQuoteStatusRevisionReopen.
  ///
  /// In zh, this message translates to:
  /// **'销售重新修改'**
  String get salesQuoteStatusRevisionReopen;

  /// No description provided for @salesQuoteStatusRevisionFinanceReopen.
  ///
  /// In zh, this message translates to:
  /// **'财务撤销确认'**
  String get salesQuoteStatusRevisionFinanceReopen;

  /// No description provided for @salesQuoteStatusRevisionOther.
  ///
  /// In zh, this message translates to:
  /// **'其它记录'**
  String get salesQuoteStatusRevisionOther;

  /// No description provided for @salesQuoteStatusRevisionOperator.
  ///
  /// In zh, this message translates to:
  /// **'操作人'**
  String get salesQuoteStatusRevisionOperator;

  /// No description provided for @salesQuoteStatusRevisionVersion.
  ///
  /// In zh, this message translates to:
  /// **'第 {revision} 版'**
  String salesQuoteStatusRevisionVersion(int revision);

  /// No description provided for @salesQuoteStatusSourceQuoteConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'报价已核价'**
  String get salesQuoteStatusSourceQuoteConfirmed;

  /// No description provided for @salesQuoteStatusSourceQuote.
  ///
  /// In zh, this message translates to:
  /// **'来源报价'**
  String get salesQuoteStatusSourceQuote;

  /// No description provided for @quoteFinanceHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'报价核价'**
  String get quoteFinanceHubTitle;

  /// No description provided for @quoteFinanceHubSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'销售报价由财务定价格和折扣, 确认后销售才能转订货单'**
  String get quoteFinanceHubSubtitle;

  /// No description provided for @quoteFinanceListTitle.
  ///
  /// In zh, this message translates to:
  /// **'报价核价'**
  String get quoteFinanceListTitle;

  /// No description provided for @quoteFinanceTabPending.
  ///
  /// In zh, this message translates to:
  /// **'待核价'**
  String get quoteFinanceTabPending;

  /// No description provided for @quoteFinanceTabConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已核价'**
  String get quoteFinanceTabConfirmed;

  /// No description provided for @quoteFinanceTabReturned.
  ///
  /// In zh, this message translates to:
  /// **'已退回'**
  String get quoteFinanceTabReturned;

  /// No description provided for @quoteFinanceSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索单号 / 客户 / 业务员'**
  String get quoteFinanceSearchHint;

  /// No description provided for @quoteFinanceRowHint.
  ///
  /// In zh, this message translates to:
  /// **'单击选中 · 双击核价'**
  String get quoteFinanceRowHint;

  /// No description provided for @quoteFinanceColBillNo.
  ///
  /// In zh, this message translates to:
  /// **'报价单号'**
  String get quoteFinanceColBillNo;

  /// No description provided for @quoteFinanceColClient.
  ///
  /// In zh, this message translates to:
  /// **'客户'**
  String get quoteFinanceColClient;

  /// No description provided for @quoteFinanceColSeller.
  ///
  /// In zh, this message translates to:
  /// **'业务员'**
  String get quoteFinanceColSeller;

  /// No description provided for @quoteFinanceColSubmittedAt.
  ///
  /// In zh, this message translates to:
  /// **'提交时间'**
  String get quoteFinanceColSubmittedAt;

  /// No description provided for @quoteFinanceColLines.
  ///
  /// In zh, this message translates to:
  /// **'明细行'**
  String get quoteFinanceColLines;

  /// No description provided for @quoteFinanceColAmount.
  ///
  /// In zh, this message translates to:
  /// **'报价金额'**
  String get quoteFinanceColAmount;

  /// No description provided for @quoteFinanceColStatus.
  ///
  /// In zh, this message translates to:
  /// **'状态 / 说明'**
  String get quoteFinanceColStatus;

  /// No description provided for @quoteFinanceStatusPending.
  ///
  /// In zh, this message translates to:
  /// **'待核价'**
  String get quoteFinanceStatusPending;

  /// No description provided for @quoteFinanceStatusResubmitted.
  ///
  /// In zh, this message translates to:
  /// **'销售改后重新提交'**
  String get quoteFinanceStatusResubmitted;

  /// No description provided for @quoteFinanceStatusNeedPrice.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{有 {count} 行没有标价}}'**
  String quoteFinanceStatusNeedPrice(int count);

  /// No description provided for @quoteFinanceStatusConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已核价 · {name}'**
  String quoteFinanceStatusConfirmed(String name);

  /// No description provided for @quoteFinanceStatusConverted.
  ///
  /// In zh, this message translates to:
  /// **'已转订货单 {orderNo}'**
  String quoteFinanceStatusConverted(String orderNo);

  /// No description provided for @quoteFinanceStatusReturned.
  ///
  /// In zh, this message translates to:
  /// **'已退回: {reason}'**
  String quoteFinanceStatusReturned(String reason);

  /// No description provided for @quoteFinanceEmptyPending.
  ///
  /// In zh, this message translates to:
  /// **'目前没有等待核价的报价'**
  String get quoteFinanceEmptyPending;

  /// No description provided for @quoteFinanceEmptyPendingHint.
  ///
  /// In zh, this message translates to:
  /// **'销售提交核价后会出现在这里; 你定好价格并确认后, 销售才能转订货单。'**
  String get quoteFinanceEmptyPendingHint;

  /// No description provided for @quoteFinanceEmptyConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'还没有已核价的报价'**
  String get quoteFinanceEmptyConfirmed;

  /// No description provided for @quoteFinanceEmptyReturned.
  ///
  /// In zh, this message translates to:
  /// **'没有退回给销售的报价'**
  String get quoteFinanceEmptyReturned;

  /// No description provided for @quoteFinanceEmptyReturnedHint.
  ///
  /// In zh, this message translates to:
  /// **'退回的报价由销售改好后, 会重新回到「待核价」。'**
  String get quoteFinanceEmptyReturnedHint;

  /// No description provided for @quoteFinanceEmptySearch.
  ///
  /// In zh, this message translates to:
  /// **'没有找到“{keyword}”相关的报价'**
  String quoteFinanceEmptySearch(String keyword);

  /// No description provided for @quoteFinanceLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'报价加载失败, 请检查网络后重试'**
  String get quoteFinanceLoadFailed;

  /// No description provided for @quoteFinanceRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get quoteFinanceRetry;

  /// No description provided for @quoteFinanceRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get quoteFinanceRefresh;

  /// No description provided for @quoteFinanceOpen.
  ///
  /// In zh, this message translates to:
  /// **'核价'**
  String get quoteFinanceOpen;

  /// No description provided for @quoteFinancePrevPage.
  ///
  /// In zh, this message translates to:
  /// **'上一页'**
  String get quoteFinancePrevPage;

  /// No description provided for @quoteFinanceNextPage.
  ///
  /// In zh, this message translates to:
  /// **'下一页'**
  String get quoteFinanceNextPage;

  /// No description provided for @quoteFinanceUnnamed.
  ///
  /// In zh, this message translates to:
  /// **'未标注'**
  String get quoteFinanceUnnamed;

  /// No description provided for @quoteFinanceReviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'报价核价'**
  String get quoteFinanceReviewTitle;

  /// No description provided for @quoteFinanceStripPending.
  ///
  /// In zh, this message translates to:
  /// **'待财务核价'**
  String get quoteFinanceStripPending;

  /// No description provided for @quoteFinanceStripConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已核价 · {name} · {time}'**
  String quoteFinanceStripConfirmed(String name, String time);

  /// No description provided for @quoteFinanceStripReturned.
  ///
  /// In zh, this message translates to:
  /// **'已退回销售 · {reason}'**
  String quoteFinanceStripReturned(String reason);

  /// No description provided for @quoteFinanceStripDraft.
  ///
  /// In zh, this message translates to:
  /// **'销售修改中'**
  String get quoteFinanceStripDraft;

  /// No description provided for @quoteFinanceStripReversed.
  ///
  /// In zh, this message translates to:
  /// **'已作废'**
  String get quoteFinanceStripReversed;

  /// No description provided for @quoteFinanceStripConverted.
  ///
  /// In zh, this message translates to:
  /// **'已转订货单 {orderNo}'**
  String quoteFinanceStripConverted(String orderNo);

  /// No description provided for @quoteFinanceRevisionBadge.
  ///
  /// In zh, this message translates to:
  /// **'第 {revision} 版'**
  String quoteFinanceRevisionBadge(int revision);

  /// No description provided for @quoteFinanceReadOnlyNotice.
  ///
  /// In zh, this message translates to:
  /// **'这张报价现在不需要你处理, 只能查看。'**
  String get quoteFinanceReadOnlyNotice;

  /// No description provided for @quoteFinanceResubmitNotice.
  ///
  /// In zh, this message translates to:
  /// **'销售改后重新提交。标黄的行, 折扣和你上次确认的不同, 请重点核对。'**
  String get quoteFinanceResubmitNotice;

  /// No description provided for @quoteFinanceNeedPriceNotice.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{有 {count} 行货品没有标价。请填写成交单价, 或在行菜单里选「设为赠品/0价」, 然后再确认报价。}}'**
  String quoteFinanceNeedPriceNotice(int count);

  /// No description provided for @quoteFinanceGoMaintainPrice.
  ///
  /// In zh, this message translates to:
  /// **'去货品资料维护标价'**
  String get quoteFinanceGoMaintainPrice;

  /// No description provided for @quoteFinanceInfoTitle.
  ///
  /// In zh, this message translates to:
  /// **'报价信息'**
  String get quoteFinanceInfoTitle;

  /// No description provided for @quoteFinanceFieldClient.
  ///
  /// In zh, this message translates to:
  /// **'客户'**
  String get quoteFinanceFieldClient;

  /// No description provided for @quoteFinanceFieldSeller.
  ///
  /// In zh, this message translates to:
  /// **'业务员'**
  String get quoteFinanceFieldSeller;

  /// No description provided for @quoteFinanceFieldMaker.
  ///
  /// In zh, this message translates to:
  /// **'制单员'**
  String get quoteFinanceFieldMaker;

  /// No description provided for @quoteFinanceFieldBillDate.
  ///
  /// In zh, this message translates to:
  /// **'单据日期'**
  String get quoteFinanceFieldBillDate;

  /// No description provided for @quoteFinanceFieldSubmittedAt.
  ///
  /// In zh, this message translates to:
  /// **'提交时间'**
  String get quoteFinanceFieldSubmittedAt;

  /// No description provided for @quoteFinanceFieldDeliverDate.
  ///
  /// In zh, this message translates to:
  /// **'交货日'**
  String get quoteFinanceFieldDeliverDate;

  /// No description provided for @quoteFinanceFieldContractNo.
  ///
  /// In zh, this message translates to:
  /// **'合同号'**
  String get quoteFinanceFieldContractNo;

  /// No description provided for @quoteFinanceFieldCurrency.
  ///
  /// In zh, this message translates to:
  /// **'币种'**
  String get quoteFinanceFieldCurrency;

  /// No description provided for @quoteFinanceFieldFileCurrency.
  ///
  /// In zh, this message translates to:
  /// **'客户文件币种'**
  String get quoteFinanceFieldFileCurrency;

  /// No description provided for @quoteFinanceFileRateHint.
  ///
  /// In zh, this message translates to:
  /// **'文件币种 {currency}, 按财务参考汇率 {rate} 折算成本币'**
  String quoteFinanceFileRateHint(String currency, String rate);

  /// No description provided for @quoteFinanceFieldRemark.
  ///
  /// In zh, this message translates to:
  /// **'销售备注'**
  String get quoteFinanceFieldRemark;

  /// No description provided for @quoteFinanceFieldValidUntil.
  ///
  /// In zh, this message translates to:
  /// **'有效期'**
  String get quoteFinanceFieldValidUntil;

  /// No description provided for @quoteFinanceFieldSettlement.
  ///
  /// In zh, this message translates to:
  /// **'结账方式'**
  String get quoteFinanceFieldSettlement;

  /// No description provided for @quoteFinanceFieldFinanceRemark.
  ///
  /// In zh, this message translates to:
  /// **'财务备注'**
  String get quoteFinanceFieldFinanceRemark;

  /// No description provided for @quoteFinanceFinanceRemarkHint.
  ///
  /// In zh, this message translates to:
  /// **'写给销售看的说明(选填)'**
  String get quoteFinanceFinanceRemarkHint;

  /// No description provided for @quoteFinanceSettlementNone.
  ///
  /// In zh, this message translates to:
  /// **'不指定'**
  String get quoteFinanceSettlementNone;

  /// No description provided for @quoteFinanceAttachmentsTitle.
  ///
  /// In zh, this message translates to:
  /// **'客户文件和附件'**
  String get quoteFinanceAttachmentsTitle;

  /// No description provided for @quoteFinanceLinesTitle.
  ///
  /// In zh, this message translates to:
  /// **'货品明细'**
  String get quoteFinanceLinesTitle;

  /// No description provided for @quoteFinanceColGoods.
  ///
  /// In zh, this message translates to:
  /// **'货品名称'**
  String get quoteFinanceColGoods;

  /// No description provided for @quoteFinanceColCode.
  ///
  /// In zh, this message translates to:
  /// **'编号'**
  String get quoteFinanceColCode;

  /// No description provided for @quoteFinanceColColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色'**
  String get quoteFinanceColColor;

  /// No description provided for @quoteFinanceColQty.
  ///
  /// In zh, this message translates to:
  /// **'数量'**
  String get quoteFinanceColQty;

  /// No description provided for @quoteFinanceColUnit.
  ///
  /// In zh, this message translates to:
  /// **'单位'**
  String get quoteFinanceColUnit;

  /// No description provided for @quoteFinanceColListPrice.
  ///
  /// In zh, this message translates to:
  /// **'标价'**
  String get quoteFinanceColListPrice;

  /// No description provided for @quoteFinanceColListPriceInfo.
  ///
  /// In zh, this message translates to:
  /// **'货品资料里的售价。没有标价, 或成交单价高于标价时, 由财务直接定成交单价; 低于标价一律算成折扣。'**
  String get quoteFinanceColListPriceInfo;

  /// No description provided for @quoteFinanceColFilePrice.
  ///
  /// In zh, this message translates to:
  /// **'文件单价(原币)'**
  String get quoteFinanceColFilePrice;

  /// No description provided for @quoteFinanceColFilePriceLocal.
  ///
  /// In zh, this message translates to:
  /// **'折合本币'**
  String get quoteFinanceColFilePriceLocal;

  /// No description provided for @quoteFinanceColDealPrice.
  ///
  /// In zh, this message translates to:
  /// **'成交单价'**
  String get quoteFinanceColDealPrice;

  /// No description provided for @quoteFinanceColDealPriceInfo.
  ///
  /// In zh, this message translates to:
  /// **'客户最终每件付多少钱。改成交单价会自动算出折扣; 改折扣会自动算出成交单价。'**
  String get quoteFinanceColDealPriceInfo;

  /// No description provided for @quoteFinanceColDiscount.
  ///
  /// In zh, this message translates to:
  /// **'折扣'**
  String get quoteFinanceColDiscount;

  /// No description provided for @quoteFinanceColDiscountInfo.
  ///
  /// In zh, this message translates to:
  /// **'折扣 = 成交单价 ÷ 标价, 保留 4 位小数, 1 表示按标价。'**
  String get quoteFinanceColDiscountInfo;

  /// No description provided for @quoteFinanceColLineAmount.
  ///
  /// In zh, this message translates to:
  /// **'金额'**
  String get quoteFinanceColLineAmount;

  /// No description provided for @quoteFinanceColFileDiff.
  ///
  /// In zh, this message translates to:
  /// **'与文件差额'**
  String get quoteFinanceColFileDiff;

  /// No description provided for @quoteFinanceColFileDiffInfo.
  ///
  /// In zh, this message translates to:
  /// **'本行金额减去客户文件里的金额(已折合本币)。0 表示和客户文件一致。'**
  String get quoteFinanceColFileDiffInfo;

  /// No description provided for @quoteFinanceColLastConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'上次确认折扣'**
  String get quoteFinanceColLastConfirmed;

  /// No description provided for @quoteFinanceColSalesProposed.
  ///
  /// In zh, this message translates to:
  /// **'销售提交折扣'**
  String get quoteFinanceColSalesProposed;

  /// No description provided for @quoteFinanceColFileModel.
  ///
  /// In zh, this message translates to:
  /// **'文件型号'**
  String get quoteFinanceColFileModel;

  /// No description provided for @quoteFinanceColFileName.
  ///
  /// In zh, this message translates to:
  /// **'文件品名'**
  String get quoteFinanceColFileName;

  /// No description provided for @quoteFinanceColRemark.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get quoteFinanceColRemark;

  /// No description provided for @quoteFinanceNoListPrice.
  ///
  /// In zh, this message translates to:
  /// **'未定价'**
  String get quoteFinanceNoListPrice;

  /// No description provided for @quoteFinanceFinancePriceChip.
  ///
  /// In zh, this message translates to:
  /// **'财务定价'**
  String get quoteFinanceFinancePriceChip;

  /// No description provided for @quoteFinanceGiveawayChip.
  ///
  /// In zh, this message translates to:
  /// **'赠品/0价'**
  String get quoteFinanceGiveawayChip;

  /// No description provided for @quoteFinanceFileMatch.
  ///
  /// In zh, this message translates to:
  /// **'一致'**
  String get quoteFinanceFileMatch;

  /// No description provided for @quoteFinanceErrorDealPrice.
  ///
  /// In zh, this message translates to:
  /// **'请填写大于 0 的数字; 0 价请在行菜单选「设为赠品/0价」'**
  String get quoteFinanceErrorDealPrice;

  /// No description provided for @quoteFinanceErrorFinancePrice.
  ///
  /// In zh, this message translates to:
  /// **'请填写不小于 0 的数字'**
  String get quoteFinanceErrorFinancePrice;

  /// No description provided for @quoteFinanceErrorDiscount.
  ///
  /// In zh, this message translates to:
  /// **'折扣要大于 0、不超过 1, 最多 4 位小数'**
  String get quoteFinanceErrorDiscount;

  /// No description provided for @quoteFinanceErrorNeedPrice.
  ///
  /// In zh, this message translates to:
  /// **'请填写成交单价'**
  String get quoteFinanceErrorNeedPrice;

  /// No description provided for @quoteFinanceMenuMasterMode.
  ///
  /// In zh, this message translates to:
  /// **'按标价打折'**
  String get quoteFinanceMenuMasterMode;

  /// No description provided for @quoteFinanceMenuGiveaway.
  ///
  /// In zh, this message translates to:
  /// **'设为赠品/0价'**
  String get quoteFinanceMenuGiveaway;

  /// No description provided for @quoteFinanceMenuRestore.
  ///
  /// In zh, this message translates to:
  /// **'撤销本行修改'**
  String get quoteFinanceMenuRestore;

  /// No description provided for @quoteFinanceBatchDiscount.
  ///
  /// In zh, this message translates to:
  /// **'批量设折扣'**
  String get quoteFinanceBatchDiscount;

  /// No description provided for @quoteFinanceBatchDiscountCount.
  ///
  /// In zh, this message translates to:
  /// **'批量设折扣({count})'**
  String quoteFinanceBatchDiscountCount(int count);

  /// No description provided for @quoteFinanceBatchDiscountTitle.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{给勾选的 {count} 行设折扣}}'**
  String quoteFinanceBatchDiscountTitle(int count);

  /// No description provided for @quoteFinanceBatchDiscountHint.
  ///
  /// In zh, this message translates to:
  /// **'例如 0.95 表示按标价的 95%'**
  String get quoteFinanceBatchDiscountHint;

  /// No description provided for @quoteFinanceBatchApply.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get quoteFinanceBatchApply;

  /// No description provided for @quoteFinanceBatchApplied.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{已给 {count} 行设好折扣}}'**
  String quoteFinanceBatchApplied(int count);

  /// No description provided for @quoteFinanceBatchSkipped.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 行没有标价或由财务定价, 已跳过}}'**
  String quoteFinanceBatchSkipped(int count);

  /// No description provided for @quoteFinanceBatchNeedSelection.
  ///
  /// In zh, this message translates to:
  /// **'请先勾选要改折扣的行'**
  String get quoteFinanceBatchNeedSelection;

  /// No description provided for @quoteFinanceCheckedEditHint.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{本行已勾选: 改折扣会一起改勾选的 {count} 行}}'**
  String quoteFinanceCheckedEditHint(int count);

  /// No description provided for @quoteFinanceActionSave.
  ///
  /// In zh, this message translates to:
  /// **'保存修改'**
  String get quoteFinanceActionSave;

  /// No description provided for @quoteFinanceActionSaving.
  ///
  /// In zh, this message translates to:
  /// **'保存中…'**
  String get quoteFinanceActionSaving;

  /// No description provided for @quoteFinanceActionReturn.
  ///
  /// In zh, this message translates to:
  /// **'退回销售'**
  String get quoteFinanceActionReturn;

  /// No description provided for @quoteFinanceActionConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认报价'**
  String get quoteFinanceActionConfirm;

  /// No description provided for @quoteFinanceActionReopen.
  ///
  /// In zh, this message translates to:
  /// **'撤销确认再修改'**
  String get quoteFinanceActionReopen;

  /// No description provided for @quoteFinanceActionBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get quoteFinanceActionBack;

  /// No description provided for @quoteFinanceSaved.
  ///
  /// In zh, this message translates to:
  /// **'修改已保存'**
  String get quoteFinanceSaved;

  /// No description provided for @quoteFinanceNothingToSave.
  ///
  /// In zh, this message translates to:
  /// **'没有需要保存的修改'**
  String get quoteFinanceNothingToSave;

  /// No description provided for @quoteFinanceFixErrors.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{有 {count} 行填写不对, 请先改好}}'**
  String quoteFinanceFixErrors(int count);

  /// No description provided for @quoteFinanceClaimNotReady.
  ///
  /// In zh, this message translates to:
  /// **'还没有取得这张报价的核价占用, 请点「重新认领并刷新」'**
  String get quoteFinanceClaimNotReady;

  /// No description provided for @quoteFinanceSaveFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先保存修改, 再确认报价'**
  String get quoteFinanceSaveFirst;

  /// No description provided for @quoteFinanceConfirmBlocked.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{还有 {count} 行没有价格, 不能确认。请填写成交单价或设为赠品/0价。}}'**
  String quoteFinanceConfirmBlocked(int count);

  /// No description provided for @quoteFinanceConfirmedDone.
  ///
  /// In zh, this message translates to:
  /// **'报价已确认, 已通知销售转订货单'**
  String get quoteFinanceConfirmedDone;

  /// No description provided for @quoteFinanceReturnedDone.
  ///
  /// In zh, this message translates to:
  /// **'已退回销售, 销售会收到通知'**
  String get quoteFinanceReturnedDone;

  /// No description provided for @quoteFinanceReopenedDone.
  ///
  /// In zh, this message translates to:
  /// **'已撤销确认, 可以继续修改价格'**
  String get quoteFinanceReopenedDone;

  /// No description provided for @quoteFinanceLoadDetailFailed.
  ///
  /// In zh, this message translates to:
  /// **'报价详情加载失败, 请检查网络或权限后重试'**
  String get quoteFinanceLoadDetailFailed;

  /// No description provided for @quoteFinanceActionFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作没有成功, 请稍后再试'**
  String get quoteFinanceActionFailed;

  /// No description provided for @quoteFinanceUnsavedTitle.
  ///
  /// In zh, this message translates to:
  /// **'有修改还没保存'**
  String get quoteFinanceUnsavedTitle;

  /// No description provided for @quoteFinanceUnsavedBody.
  ///
  /// In zh, this message translates to:
  /// **'离开后这些修改会丢失。确定离开?'**
  String get quoteFinanceUnsavedBody;

  /// No description provided for @quoteFinanceLeave.
  ///
  /// In zh, this message translates to:
  /// **'离开'**
  String get quoteFinanceLeave;

  /// No description provided for @quoteFinanceStay.
  ///
  /// In zh, this message translates to:
  /// **'继续修改'**
  String get quoteFinanceStay;

  /// No description provided for @quoteFinanceBusy.
  ///
  /// In zh, this message translates to:
  /// **'正在处理, 请稍候'**
  String get quoteFinanceBusy;

  /// No description provided for @quoteFinanceSaving.
  ///
  /// In zh, this message translates to:
  /// **'正在保存修改'**
  String get quoteFinanceSaving;

  /// No description provided for @quoteFinanceSessionChanged.
  ///
  /// In zh, this message translates to:
  /// **'登录身份已变化, 请重新打开报价'**
  String get quoteFinanceSessionChanged;

  /// No description provided for @quoteFinanceConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认报价 {billNo}'**
  String quoteFinanceConfirmTitle(String billNo);

  /// No description provided for @quoteFinanceConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'确认后价格和折扣就定下来了, 销售可以转成订货单。以后要改, 可以在转单前「撤销确认再修改」。'**
  String get quoteFinanceConfirmBody;

  /// No description provided for @quoteFinanceConfirmResponsibility.
  ///
  /// In zh, this message translates to:
  /// **'报价核价确认'**
  String get quoteFinanceConfirmResponsibility;

  /// No description provided for @quoteFinanceConfirmResponsibilityDesc.
  ///
  /// In zh, this message translates to:
  /// **'确认后系统会记录你是本次核价人。'**
  String get quoteFinanceConfirmResponsibilityDesc;

  /// No description provided for @quoteFinanceConfirmTotal.
  ///
  /// In zh, this message translates to:
  /// **'报价金额 {amount}'**
  String quoteFinanceConfirmTotal(String amount);

  /// No description provided for @quoteFinanceReturnTitle.
  ///
  /// In zh, this message translates to:
  /// **'退回销售 {billNo}'**
  String quoteFinanceReturnTitle(String billNo);

  /// No description provided for @quoteFinanceReturnBody.
  ///
  /// In zh, this message translates to:
  /// **'退回后报价回到销售手上, 销售改好再提交。请写明原因, 销售会看到。'**
  String get quoteFinanceReturnBody;

  /// No description provided for @quoteFinanceReturnChipQty.
  ///
  /// In zh, this message translates to:
  /// **'客户要改数量'**
  String get quoteFinanceReturnChipQty;

  /// No description provided for @quoteFinanceReturnChipGoods.
  ///
  /// In zh, this message translates to:
  /// **'缺货品需补充'**
  String get quoteFinanceReturnChipGoods;

  /// No description provided for @quoteFinanceReturnChipPrice.
  ///
  /// In zh, this message translates to:
  /// **'价格需销售与客户确认'**
  String get quoteFinanceReturnChipPrice;

  /// No description provided for @quoteFinanceReturnReasonLabel.
  ///
  /// In zh, this message translates to:
  /// **'退回原因(必填)'**
  String get quoteFinanceReturnReasonLabel;

  /// No description provided for @quoteFinanceReturnReasonRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写退回原因'**
  String get quoteFinanceReturnReasonRequired;

  /// No description provided for @quoteFinanceReturnSubmit.
  ///
  /// In zh, this message translates to:
  /// **'确认退回'**
  String get quoteFinanceReturnSubmit;

  /// No description provided for @quoteFinanceReopenTitle.
  ///
  /// In zh, this message translates to:
  /// **'撤销确认再修改'**
  String get quoteFinanceReopenTitle;

  /// No description provided for @quoteFinanceReopenBody.
  ///
  /// In zh, this message translates to:
  /// **'报价会回到「待核价」, 你可以继续修改价格, 改好后要重新确认。这期间销售不能转订货单。确定撤销?'**
  String get quoteFinanceReopenBody;

  /// No description provided for @quoteFinanceCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get quoteFinanceCancel;

  /// No description provided for @quoteFinanceRevisionTitle.
  ///
  /// In zh, this message translates to:
  /// **'核价记录'**
  String get quoteFinanceRevisionTitle;

  /// No description provided for @quoteFinanceTotalQty.
  ///
  /// In zh, this message translates to:
  /// **'合计数量'**
  String get quoteFinanceTotalQty;

  /// No description provided for @quoteFinanceTotalAmount.
  ///
  /// In zh, this message translates to:
  /// **'合计金额'**
  String get quoteFinanceTotalAmount;

  /// No description provided for @quoteFinanceTotalPreview.
  ///
  /// In zh, this message translates to:
  /// **'合计金额(未保存预览)'**
  String get quoteFinanceTotalPreview;

  /// No description provided for @quoteFinanceOrderSourceQuote.
  ///
  /// In zh, this message translates to:
  /// **'来源报价 {billNo}'**
  String quoteFinanceOrderSourceQuote(String billNo);

  /// No description provided for @quoteFinanceOrderQuoteConfirmedBy.
  ///
  /// In zh, this message translates to:
  /// **'报价已核价 · {name}'**
  String quoteFinanceOrderQuoteConfirmedBy(String name);

  /// No description provided for @quoteFinanceOrderAllMatch.
  ///
  /// In zh, this message translates to:
  /// **'报价已核价 · 一致'**
  String get quoteFinanceOrderAllMatch;

  /// No description provided for @quoteFinanceOrderMismatch.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{有 {count} 行和报价不同}}'**
  String quoteFinanceOrderMismatch(int count);

  /// No description provided for @quoteFinanceOrderChipHint.
  ///
  /// In zh, this message translates to:
  /// **'这张订单由财务核过价的报价转来, 价格和折扣与报价一致时, 本次只需核对信用和条款。'**
  String get quoteFinanceOrderChipHint;

  /// No description provided for @quoteFinanceOrderColQuotePrice.
  ///
  /// In zh, this message translates to:
  /// **'报价单价'**
  String get quoteFinanceOrderColQuotePrice;

  /// No description provided for @quoteFinanceOrderColQuoteDiscount.
  ///
  /// In zh, this message translates to:
  /// **'报价折扣'**
  String get quoteFinanceOrderColQuoteDiscount;

  /// No description provided for @quoteFinanceOrderColMatch.
  ///
  /// In zh, this message translates to:
  /// **'与报价'**
  String get quoteFinanceOrderColMatch;

  /// No description provided for @quoteFinanceOrderMatchYes.
  ///
  /// In zh, this message translates to:
  /// **'一致'**
  String get quoteFinanceOrderMatchYes;

  /// No description provided for @quoteFinanceOrderMatchNo.
  ///
  /// In zh, this message translates to:
  /// **'不同'**
  String get quoteFinanceOrderMatchNo;

  /// No description provided for @quoteFinanceOrderColFilePrice.
  ///
  /// In zh, this message translates to:
  /// **'文件单价({currency})'**
  String quoteFinanceOrderColFilePrice(String currency);

  /// No description provided for @quoteFinanceOrderFileCurrencyUnknown.
  ///
  /// In zh, this message translates to:
  /// **'原币'**
  String get quoteFinanceOrderFileCurrencyUnknown;

  /// No description provided for @quoteFinanceOrderColFileModel.
  ///
  /// In zh, this message translates to:
  /// **'文件型号'**
  String get quoteFinanceOrderColFileModel;

  /// No description provided for @quoteFinanceOrderColFileName.
  ///
  /// In zh, this message translates to:
  /// **'文件品名'**
  String get quoteFinanceOrderColFileName;

  /// No description provided for @quoteFinanceAboveListHint.
  ///
  /// In zh, this message translates to:
  /// **'高于标价, 按财务定价保存(折扣为 1)'**
  String get quoteFinanceAboveListHint;

  /// No description provided for @quoteFinanceMenuRefreshMaster.
  ///
  /// In zh, this message translates to:
  /// **'按最新标价刷新'**
  String get quoteFinanceMenuRefreshMaster;

  /// No description provided for @quoteFinanceRefreshMasterChip.
  ///
  /// In zh, this message translates to:
  /// **'按货品资料最新标价 {price} 刷新, 折扣不变; 保存后可再改折扣'**
  String quoteFinanceRefreshMasterChip(String price);

  /// No description provided for @quoteFinanceListPriceLatest.
  ///
  /// In zh, this message translates to:
  /// **'{price}, 资料已改为 {latest}'**
  String quoteFinanceListPriceLatest(String price, String latest);

  /// No description provided for @quoteFinanceStatusClaimedBy.
  ///
  /// In zh, this message translates to:
  /// **'{name} 正在核价'**
  String quoteFinanceStatusClaimedBy(String name);

  /// No description provided for @quoteFinanceStatusClaimedByMe.
  ///
  /// In zh, this message translates to:
  /// **'你正在核价'**
  String get quoteFinanceStatusClaimedByMe;

  /// No description provided for @quoteFinanceFileRateMissing.
  ///
  /// In zh, this message translates to:
  /// **'文件币种 {currency}, 还没有财务参考汇率, 折合本币先空着'**
  String quoteFinanceFileRateMissing(String currency);

  /// No description provided for @salesQuoteStatusImportTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择已核价的报价单'**
  String get salesQuoteStatusImportTitle;

  /// No description provided for @salesQuoteStatusImportEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无已核价、可以转订货单的报价'**
  String get salesQuoteStatusImportEmpty;

  /// No description provided for @salesQuoteStatusImportLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'报价加载失败, 请稍后重试'**
  String get salesQuoteStatusImportLoadFailed;

  /// No description provided for @salesIntakeApprovedOrderHint.
  ///
  /// In zh, this message translates to:
  /// **'已审核的订单请用改量或修改, 不能整单重新识别'**
  String get salesIntakeApprovedOrderHint;

  /// No description provided for @salesIntakeReplaceTitle.
  ///
  /// In zh, this message translates to:
  /// **'明细里已经有货品'**
  String get salesIntakeReplaceTitle;

  /// No description provided for @salesIntakeReplaceMessage.
  ///
  /// In zh, this message translates to:
  /// **'要用识别结果替换现有明细, 还是追加在后面?'**
  String get salesIntakeReplaceMessage;

  /// No description provided for @salesIntakeReplace.
  ///
  /// In zh, this message translates to:
  /// **'替换'**
  String get salesIntakeReplace;

  /// No description provided for @salesIntakeAppend.
  ///
  /// In zh, this message translates to:
  /// **'追加'**
  String get salesIntakeAppend;

  /// No description provided for @salesIntakeApplied.
  ///
  /// In zh, this message translates to:
  /// **'已导入 {count} 行, 其中 {review} 行有黄色标记, 请核对'**
  String salesIntakeApplied(int count, int review);

  /// No description provided for @salesIntakeAppliedAllMatched.
  ///
  /// In zh, this message translates to:
  /// **'已导入 {count} 行'**
  String salesIntakeAppliedAllMatched(int count);

  /// No description provided for @salesIntakeAttachFailed.
  ///
  /// In zh, this message translates to:
  /// **'原文件没能加入附件, 可在附件区手动上传'**
  String get salesIntakeAttachFailed;

  /// No description provided for @salesIntakeProgressTitle.
  ///
  /// In zh, this message translates to:
  /// **'正在识别客户文件'**
  String get salesIntakeProgressTitle;

  /// No description provided for @salesIntakeStageUpload.
  ///
  /// In zh, this message translates to:
  /// **'上传文件'**
  String get salesIntakeStageUpload;

  /// No description provided for @salesIntakeStageRead.
  ///
  /// In zh, this message translates to:
  /// **'读取表格'**
  String get salesIntakeStageRead;

  /// No description provided for @salesIntakeStageLayout.
  ///
  /// In zh, this message translates to:
  /// **'识别表头与列'**
  String get salesIntakeStageLayout;

  /// No description provided for @salesIntakeStageGoods.
  ///
  /// In zh, this message translates to:
  /// **'匹配货品'**
  String get salesIntakeStageGoods;

  /// No description provided for @salesIntakeStageClient.
  ///
  /// In zh, this message translates to:
  /// **'匹配客户'**
  String get salesIntakeStageClient;

  /// No description provided for @salesIntakeStagePricing.
  ///
  /// In zh, this message translates to:
  /// **'计算折扣'**
  String get salesIntakeStagePricing;

  /// No description provided for @salesIntakeSendWholeFileTitle.
  ///
  /// In zh, this message translates to:
  /// **'整份文件会发送给 AI 服务识别'**
  String get salesIntakeSendWholeFileTitle;

  /// No description provided for @salesIntakeSendWholeFileMessage.
  ///
  /// In zh, this message translates to:
  /// **'这是 PDF/图片, 系统需要把整份文件发给 AI 服务来识别。文件里如有银行账号等敏感信息, 请先确认可以发送。'**
  String get salesIntakeSendWholeFileMessage;

  /// No description provided for @salesIntakeSendWholeFileConfirm.
  ///
  /// In zh, this message translates to:
  /// **'继续识别'**
  String get salesIntakeSendWholeFileConfirm;

  /// No description provided for @salesIntakeAiRequired.
  ///
  /// In zh, this message translates to:
  /// **'PDF/图片需要开启 AI 才能识别, 请上传 Excel 或联系管理员'**
  String get salesIntakeAiRequired;

  /// No description provided for @salesIntakeVisionRequired.
  ///
  /// In zh, this message translates to:
  /// **'这是图片格式的文件, 需要管理员在 AI 服务设置中启用支持图片识别的模型'**
  String get salesIntakeVisionRequired;

  /// No description provided for @salesIntakeFileTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件太大, 最大 {max}'**
  String salesIntakeFileTooLarge(String max);

  /// No description provided for @salesIntakeFileUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'没能读取这个文件, 请重新选择'**
  String get salesIntakeFileUnreadable;

  /// No description provided for @salesIntakeFileTypeUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'只能识别 Excel、CSV、PDF 或图片文件'**
  String get salesIntakeFileTypeUnsupported;

  /// No description provided for @salesIntakeFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'没能识别这个文件'**
  String get salesIntakeFailedTitle;

  /// No description provided for @salesIntakeResultUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'识别结果无法读取, 请重新识别'**
  String get salesIntakeResultUnreadable;

  /// No description provided for @salesIntakeNoLines.
  ///
  /// In zh, this message translates to:
  /// **'文件里没找到货品明细, 请确认上传的是报价单或形式发票'**
  String get salesIntakeNoLines;

  /// No description provided for @salesIntakeCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get salesIntakeCancel;

  /// No description provided for @salesIntakeCreateClientTitle.
  ///
  /// In zh, this message translates to:
  /// **'用文件信息新建客户'**
  String get salesIntakeCreateClientTitle;

  /// No description provided for @salesIntakeCreateClientIntro.
  ///
  /// In zh, this message translates to:
  /// **'将按下面的信息新建客户, 负责人是你, 分类放在「未分类」。'**
  String get salesIntakeCreateClientIntro;

  /// No description provided for @salesIntakeCreateClientName.
  ///
  /// In zh, this message translates to:
  /// **'客户简称'**
  String get salesIntakeCreateClientName;

  /// No description provided for @salesIntakeCreateClientNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写客户简称'**
  String get salesIntakeCreateClientNameRequired;

  /// No description provided for @salesIntakeCreateClientConfirm.
  ///
  /// In zh, this message translates to:
  /// **'新建客户'**
  String get salesIntakeCreateClientConfirm;

  /// No description provided for @salesIntakeCreateClientDone.
  ///
  /// In zh, this message translates to:
  /// **'已新建客户 {name}'**
  String salesIntakeCreateClientDone(String name);

  /// No description provided for @salesIntakeCreateClientExists.
  ///
  /// In zh, this message translates to:
  /// **'这个客户已经存在, 已为你选上'**
  String get salesIntakeCreateClientExists;

  /// No description provided for @salesIntakeCreateClientFailed.
  ///
  /// In zh, this message translates to:
  /// **'新建客户没有成功, 请稍后重试'**
  String get salesIntakeCreateClientFailed;

  /// No description provided for @salesIntakeFieldFullName.
  ///
  /// In zh, this message translates to:
  /// **'全称'**
  String get salesIntakeFieldFullName;

  /// No description provided for @salesIntakeFieldNameEn.
  ///
  /// In zh, this message translates to:
  /// **'外文名称'**
  String get salesIntakeFieldNameEn;

  /// No description provided for @salesIntakeFieldLinkman.
  ///
  /// In zh, this message translates to:
  /// **'联系人'**
  String get salesIntakeFieldLinkman;

  /// No description provided for @salesIntakeFieldEmail.
  ///
  /// In zh, this message translates to:
  /// **'邮箱'**
  String get salesIntakeFieldEmail;

  /// No description provided for @salesIntakeFieldPhone.
  ///
  /// In zh, this message translates to:
  /// **'电话'**
  String get salesIntakeFieldPhone;

  /// No description provided for @salesIntakeFieldAddress.
  ///
  /// In zh, this message translates to:
  /// **'地址'**
  String get salesIntakeFieldAddress;

  /// No description provided for @salesIntakeFieldTaxId.
  ///
  /// In zh, this message translates to:
  /// **'税号'**
  String get salesIntakeFieldTaxId;

  /// No description provided for @salesIntakeFieldPlace.
  ///
  /// In zh, this message translates to:
  /// **'国家/地区'**
  String get salesIntakeFieldPlace;

  /// No description provided for @salesIntakeReviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'核对识别结果'**
  String get salesIntakeReviewTitle;

  /// No description provided for @salesIntakeReviewSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'{file} · 共 {count} 行明细'**
  String salesIntakeReviewSubtitle(String file, int count);

  /// No description provided for @salesIntakeClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get salesIntakeClose;

  /// No description provided for @salesIntakeStepClient.
  ///
  /// In zh, this message translates to:
  /// **'客户'**
  String get salesIntakeStepClient;

  /// No description provided for @salesIntakeStepGoods.
  ///
  /// In zh, this message translates to:
  /// **'货品'**
  String get salesIntakeStepGoods;

  /// No description provided for @salesIntakeClientResolved.
  ///
  /// In zh, this message translates to:
  /// **'客户: {name}'**
  String salesIntakeClientResolved(String name);

  /// No description provided for @salesIntakeClientChange.
  ///
  /// In zh, this message translates to:
  /// **'换一个'**
  String get salesIntakeClientChange;

  /// No description provided for @salesIntakeClientPickOther.
  ///
  /// In zh, this message translates to:
  /// **'选其它客户…'**
  String get salesIntakeClientPickOther;

  /// No description provided for @salesIntakeClientCreate.
  ///
  /// In zh, this message translates to:
  /// **'用文件信息新建客户'**
  String get salesIntakeClientCreate;

  /// No description provided for @salesIntakeClientBuyer.
  ///
  /// In zh, this message translates to:
  /// **'文件上的买方: {name}'**
  String salesIntakeClientBuyer(String name);

  /// No description provided for @salesIntakeClientNotFound.
  ///
  /// In zh, this message translates to:
  /// **'没在你的客户里找到这个买方'**
  String get salesIntakeClientNotFound;

  /// No description provided for @salesIntakeClientSuggestions.
  ///
  /// In zh, this message translates to:
  /// **'像是下面这些客户, 请选一个:'**
  String get salesIntakeClientSuggestions;

  /// No description provided for @salesIntakeClientNone.
  ///
  /// In zh, this message translates to:
  /// **'还没选客户, 导入后也可以在表头再选'**
  String get salesIntakeClientNone;

  /// No description provided for @salesIntakeNoVisibleClients.
  ///
  /// In zh, this message translates to:
  /// **'你名下还没有客户资料, 请联系主管在客户资料里把客户分配给你'**
  String get salesIntakeNoVisibleClients;

  /// No description provided for @salesIntakeEnrichSummary.
  ///
  /// In zh, this message translates to:
  /// **'文件里有客户的{fields}, 保存时补进客户资料'**
  String salesIntakeEnrichSummary(String fields);

  /// No description provided for @salesIntakeEnrichShow.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get salesIntakeEnrichShow;

  /// No description provided for @salesIntakeEnrichHide.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get salesIntakeEnrichHide;

  /// No description provided for @salesIntakeEnrichDiffers.
  ///
  /// In zh, this message translates to:
  /// **'文件里的值不同, 现在是: {current}'**
  String salesIntakeEnrichDiffers(String current);

  /// No description provided for @salesIntakeEnrichCurrentEmpty.
  ///
  /// In zh, this message translates to:
  /// **'客户资料里还没填'**
  String get salesIntakeEnrichCurrentEmpty;

  /// No description provided for @salesIntakeFilterReview.
  ///
  /// In zh, this message translates to:
  /// **'需要核对 ({count})'**
  String salesIntakeFilterReview(int count);

  /// No description provided for @salesIntakeFilterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部 ({count})'**
  String salesIntakeFilterAll(int count);

  /// No description provided for @salesIntakeMatchedCollapsed.
  ///
  /// In zh, this message translates to:
  /// **'{count} 行已自动对应'**
  String salesIntakeMatchedCollapsed(int count);

  /// No description provided for @salesIntakeExpand.
  ///
  /// In zh, this message translates to:
  /// **'展开'**
  String get salesIntakeExpand;

  /// No description provided for @salesIntakeCollapse.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get salesIntakeCollapse;

  /// No description provided for @salesIntakeNoReviewLines.
  ///
  /// In zh, this message translates to:
  /// **'所有行都已自动对应, 可以直接导入'**
  String get salesIntakeNoReviewLines;

  /// No description provided for @salesIntakeLineNo.
  ///
  /// In zh, this message translates to:
  /// **'第 {no} 行'**
  String salesIntakeLineNo(String no);

  /// No description provided for @salesIntakeQty.
  ///
  /// In zh, this message translates to:
  /// **'数量 {qty}'**
  String salesIntakeQty(String qty);

  /// No description provided for @salesIntakeFilePrice.
  ///
  /// In zh, this message translates to:
  /// **'文件单价 {price}'**
  String salesIntakeFilePrice(String price);

  /// No description provided for @salesIntakeFilePriceWithCurrency.
  ///
  /// In zh, this message translates to:
  /// **'文件单价 {price} {currency}'**
  String salesIntakeFilePriceWithCurrency(String price, String currency);

  /// No description provided for @salesIntakeStatusMatched.
  ///
  /// In zh, this message translates to:
  /// **'已对应'**
  String get salesIntakeStatusMatched;

  /// No description provided for @salesIntakeStatusConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认'**
  String get salesIntakeStatusConfirmed;

  /// No description provided for @salesIntakeStatusReview.
  ///
  /// In zh, this message translates to:
  /// **'请核对'**
  String get salesIntakeStatusReview;

  /// No description provided for @salesIntakeStatusUnmatched.
  ///
  /// In zh, this message translates to:
  /// **'没找到'**
  String get salesIntakeStatusUnmatched;

  /// No description provided for @salesIntakeStatusBlocked.
  ///
  /// In zh, this message translates to:
  /// **'不能导入'**
  String get salesIntakeStatusBlocked;

  /// No description provided for @salesIntakeGoodsLabel.
  ///
  /// In zh, this message translates to:
  /// **'对应货品'**
  String get salesIntakeGoodsLabel;

  /// No description provided for @salesIntakeGoodsHint.
  ///
  /// In zh, this message translates to:
  /// **'请选择货品'**
  String get salesIntakeGoodsHint;

  /// No description provided for @salesIntakeConfirmChoice.
  ///
  /// In zh, this message translates to:
  /// **'就是它'**
  String get salesIntakeConfirmChoice;

  /// No description provided for @salesIntakePickFromMaster.
  ///
  /// In zh, this message translates to:
  /// **'从货品资料选择…'**
  String get salesIntakePickFromMaster;

  /// No description provided for @salesIntakeSplit.
  ///
  /// In zh, this message translates to:
  /// **'拆成 {count} 行'**
  String salesIntakeSplit(int count);

  /// No description provided for @salesIntakeMerge.
  ///
  /// In zh, this message translates to:
  /// **'合回一行'**
  String get salesIntakeMerge;

  /// No description provided for @salesIntakeBundleHint.
  ///
  /// In zh, this message translates to:
  /// **'这一行是组合件, 可以拆开逐个选货品'**
  String get salesIntakeBundleHint;

  /// No description provided for @salesIntakeSetNameEn.
  ///
  /// In zh, this message translates to:
  /// **'设为货品英文名: {text}'**
  String salesIntakeSetNameEn(String text);

  /// No description provided for @salesIntakeInclude.
  ///
  /// In zh, this message translates to:
  /// **'导入这一行'**
  String get salesIntakeInclude;

  /// No description provided for @salesIntakeDiscountPreview.
  ///
  /// In zh, this message translates to:
  /// **'折扣 {discount}'**
  String salesIntakeDiscountPreview(String discount);

  /// No description provided for @salesIntakeDiscountPending.
  ///
  /// In zh, this message translates to:
  /// **'折扣待定'**
  String get salesIntakeDiscountPending;

  /// No description provided for @salesIntakePricingNoListPrice.
  ///
  /// In zh, this message translates to:
  /// **'这个货品还没有标价'**
  String get salesIntakePricingNoListPrice;

  /// No description provided for @salesIntakePricingAboveList.
  ///
  /// In zh, this message translates to:
  /// **'文件单价高于标价'**
  String get salesIntakePricingAboveList;

  /// No description provided for @salesIntakePricingOutOfRange.
  ///
  /// In zh, this message translates to:
  /// **'折扣异常, 可能对应错货品'**
  String get salesIntakePricingOutOfRange;

  /// No description provided for @salesIntakePricingAmbiguous.
  ///
  /// In zh, this message translates to:
  /// **'看不出文件是按人民币还是外币报价, 折扣请核对'**
  String get salesIntakePricingAmbiguous;

  /// No description provided for @salesIntakePricingRateMissing.
  ///
  /// In zh, this message translates to:
  /// **'外币参考汇率还没维护, 折扣没能算出'**
  String get salesIntakePricingRateMissing;

  /// No description provided for @salesIntakeUnmatchedRemarkHint.
  ///
  /// In zh, this message translates to:
  /// **'不导入, 文件原文会写进备注'**
  String get salesIntakeUnmatchedRemarkHint;

  /// No description provided for @salesIntakeBlockedHint.
  ///
  /// In zh, this message translates to:
  /// **'订货单不能直接导入, 要先做报价单交给财务定价'**
  String get salesIntakeBlockedHint;

  /// No description provided for @salesIntakeBlockedTitle.
  ///
  /// In zh, this message translates to:
  /// **'这 {count} 个货品还没有标价(或文件单价高于标价)'**
  String salesIntakeBlockedTitle(int count);

  /// No description provided for @salesIntakeBlockedMessage.
  ///
  /// In zh, this message translates to:
  /// **'订货单不能直接导入这些货品, 要先做报价单交给财务定价。'**
  String get salesIntakeBlockedMessage;

  /// No description provided for @salesIntakeHandoffToQuote.
  ///
  /// In zh, this message translates to:
  /// **'改为新建报价单'**
  String get salesIntakeHandoffToQuote;

  /// No description provided for @salesIntakeDuplicateTitle.
  ///
  /// In zh, this message translates to:
  /// **'这个文件可能已经录过'**
  String get salesIntakeDuplicateTitle;

  /// No description provided for @salesIntakeDuplicateItem.
  ///
  /// In zh, this message translates to:
  /// **'{doc} {billNo} ({date}, {reason})'**
  String salesIntakeDuplicateItem(
    String doc,
    String billNo,
    String date,
    String reason,
  );

  /// No description provided for @salesIntakeDuplicateMessage.
  ///
  /// In zh, this message translates to:
  /// **'已有 {items}, 确定还要再建一张吗?'**
  String salesIntakeDuplicateMessage(String items);

  /// No description provided for @salesIntakeDocTypeQuote.
  ///
  /// In zh, this message translates to:
  /// **'报价单'**
  String get salesIntakeDocTypeQuote;

  /// No description provided for @salesIntakeDocTypeOrder.
  ///
  /// In zh, this message translates to:
  /// **'订货单'**
  String get salesIntakeDocTypeOrder;

  /// No description provided for @salesIntakeOtherSheets.
  ///
  /// In zh, this message translates to:
  /// **'文件里还有工作表 {sheets} 也像明细表, 这次只识别了「{current}」。如需识别那张表, 请重新上传这个文件, 核对时点那张表即可。'**
  String salesIntakeOtherSheets(String sheets, String current);

  /// No description provided for @salesIntakeOtherSheetItem.
  ///
  /// In zh, this message translates to:
  /// **'{name}({count} 行)'**
  String salesIntakeOtherSheetItem(String name, int count);

  /// No description provided for @salesIntakeOtherSheetsLead.
  ///
  /// In zh, this message translates to:
  /// **'这次识别的是工作表「{current}」。点下面的工作表可改为识别那一张 (每次只识别一张, 不会合在一起)。'**
  String salesIntakeOtherSheetsLead(String current);

  /// No description provided for @salesIntakeOtherSheetChip.
  ///
  /// In zh, this message translates to:
  /// **'另有工作表 {name} 也像明细表 ({count} 行)'**
  String salesIntakeOtherSheetChip(String name, int count);

  /// No description provided for @salesIntakeOtherSheetTooltip.
  ///
  /// In zh, this message translates to:
  /// **'改为识别这张表'**
  String get salesIntakeOtherSheetTooltip;

  /// No description provided for @salesIntakeSheetProgressSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'{file} · 工作表 {sheet}'**
  String salesIntakeSheetProgressSubtitle(String file, String sheet);

  /// No description provided for @salesIntakePriceMaskedNotice.
  ///
  /// In zh, this message translates to:
  /// **'你看不到价格, 折扣会在保存时按文件单价自动计算'**
  String get salesIntakePriceMaskedNotice;

  /// No description provided for @salesIntakeCurrencyNotice.
  ///
  /// In zh, this message translates to:
  /// **'文件是 {currency} 报价, 按财务参考汇率 {rate} 折算, 单据按{base}保存'**
  String salesIntakeCurrencyNotice(String currency, String rate, String base);

  /// No description provided for @salesIntakeRateMissingNotice.
  ///
  /// In zh, this message translates to:
  /// **'{currency} 的参考汇率还没维护, 部分折扣没能算出, 请财务在币种资料中填写'**
  String salesIntakeRateMissingNotice(String currency);

  /// No description provided for @salesIntakeSummary.
  ///
  /// In zh, this message translates to:
  /// **'将导入 {rows} 行 · {review} 行导入后黄色提醒核对 · {skipped} 行不导入'**
  String salesIntakeSummary(int rows, int review, int skipped);

  /// No description provided for @salesIntakeImportAll.
  ///
  /// In zh, this message translates to:
  /// **'全部导入 ({count} 行)'**
  String salesIntakeImportAll(int count);

  /// No description provided for @salesIntakeNothingToImport.
  ///
  /// In zh, this message translates to:
  /// **'还没有可导入的货品'**
  String get salesIntakeNothingToImport;

  /// No description provided for @salesIntakePickedManually.
  ///
  /// In zh, this message translates to:
  /// **'从货品资料选择'**
  String get salesIntakePickedManually;

  /// No description provided for @salesIntakeRemarkLineItem.
  ///
  /// In zh, this message translates to:
  /// **'{label} × {qty}'**
  String salesIntakeRemarkLineItem(String label, String qty);

  /// No description provided for @salesIntakeRemarkUnmatched.
  ///
  /// In zh, this message translates to:
  /// **'以下 {count} 行没找到对应货品: {lines}'**
  String salesIntakeRemarkUnmatched(int count, String lines);

  /// No description provided for @salesIntakeRemarkUnpriced.
  ///
  /// In zh, this message translates to:
  /// **'以下 {count} 行还没有标价(或文件单价高于标价), 没有导入: {lines}'**
  String salesIntakeRemarkUnpriced(int count, String lines);

  /// No description provided for @salesIntakeRemarkBundlePrice.
  ///
  /// In zh, this message translates to:
  /// **'组合件 {bundle} 整套文件单价 {price}'**
  String salesIntakeRemarkBundlePrice(String bundle, String price);

  /// No description provided for @salesIntakeMarkerDefault.
  ///
  /// In zh, this message translates to:
  /// **'识别结果需要核对'**
  String get salesIntakeMarkerDefault;

  /// No description provided for @salesIntakeMarkerUnit.
  ///
  /// In zh, this message translates to:
  /// **'文件数量单位不是个, 请核对数量'**
  String get salesIntakeMarkerUnit;

  /// No description provided for @salesIntakeMarkerQuotePricing.
  ///
  /// In zh, this message translates to:
  /// **'这个货品还没有标价(或文件单价高于标价), 待财务定价'**
  String get salesIntakeMarkerQuotePricing;

  /// No description provided for @salesIntakeMarkerQuoteDiscount.
  ///
  /// In zh, this message translates to:
  /// **'折扣没能自动算出, 财务核价时确定'**
  String get salesIntakeMarkerQuoteDiscount;

  /// No description provided for @salesIntakeMarkerOrderDiscount.
  ///
  /// In zh, this message translates to:
  /// **'折扣没能自动算出, 请按文件单价核对后填写'**
  String get salesIntakeMarkerOrderDiscount;

  /// No description provided for @salesIntakeQuoteLineReplaced.
  ///
  /// In zh, this message translates to:
  /// **'这一行原来是报价里财务核定的货品, 换成别的货品后不再按报价的单价和折扣, 保存时按货品标价重新计算'**
  String get salesIntakeQuoteLineReplaced;

  /// No description provided for @salesIntakeMarkerBundlePart.
  ///
  /// In zh, this message translates to:
  /// **'组合件已拆开, 请核对货品和折扣'**
  String get salesIntakeMarkerBundlePart;

  /// No description provided for @salesIntakeColClientModel.
  ///
  /// In zh, this message translates to:
  /// **'文件型号'**
  String get salesIntakeColClientModel;

  /// No description provided for @salesIntakeColClientModelInfo.
  ///
  /// In zh, this message translates to:
  /// **'客户文件里的型号/货号。保存后系统会记住客户的叫法, 下次识别更准。'**
  String get salesIntakeColClientModelInfo;

  /// No description provided for @salesIntakeColClientGoodsName.
  ///
  /// In zh, this message translates to:
  /// **'文件品名'**
  String get salesIntakeColClientGoodsName;

  /// No description provided for @salesIntakeColClientGoodsNameInfo.
  ///
  /// In zh, this message translates to:
  /// **'客户文件里的品名。手工选货品时会带出货品的英文名称, 可改。'**
  String get salesIntakeColClientGoodsNameInfo;

  /// No description provided for @salesIntakeColClientPrice.
  ///
  /// In zh, this message translates to:
  /// **'文件单价'**
  String get salesIntakeColClientPrice;

  /// No description provided for @salesIntakeColClientPriceWithCurrency.
  ///
  /// In zh, this message translates to:
  /// **'文件单价({currency})'**
  String salesIntakeColClientPriceWithCurrency(String currency);

  /// No description provided for @salesIntakeColClientPriceInfo.
  ///
  /// In zh, this message translates to:
  /// **'客户文件里的单价(文件币种), 只作核对参考; 单价以货品资料标价为准, 折扣按它计算。'**
  String get salesIntakeColClientPriceInfo;

  /// No description provided for @salesIntakeQuotePriceHint.
  ///
  /// In zh, this message translates to:
  /// **'单价由货品标价带入，可修改本次报价的单价和折扣，不改变货品资料。提交后由财务核价；没有单价可留空交财务填写。'**
  String get salesIntakeQuotePriceHint;

  /// No description provided for @salesIntakeFinancePriced.
  ///
  /// In zh, this message translates to:
  /// **'财务定价'**
  String get salesIntakeFinancePriced;

  /// No description provided for @salesIntakePendingFinancePrice.
  ///
  /// In zh, this message translates to:
  /// **'待财务定价'**
  String get salesIntakePendingFinancePrice;

  /// No description provided for @salesIntakeQuoteDiscountPending.
  ///
  /// In zh, this message translates to:
  /// **'财务核价时填写'**
  String get salesIntakeQuoteDiscountPending;

  /// No description provided for @salesIntakeMaskedDiscount.
  ///
  /// In zh, this message translates to:
  /// **'保存时自动计算'**
  String get salesIntakeMaskedDiscount;

  /// No description provided for @salesIntakeQuoteLockedDiscount.
  ///
  /// In zh, this message translates to:
  /// **'(报价核定)'**
  String get salesIntakeQuoteLockedDiscount;

  /// No description provided for @salesIntakeQuoteLockedDiscountInfo.
  ///
  /// In zh, this message translates to:
  /// **'该行折扣已由财务在报价中核定, 如需改价请重新打开报价'**
  String get salesIntakeQuoteLockedDiscountInfo;

  /// No description provided for @quoteTemplateDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载报价表格'**
  String get quoteTemplateDownload;

  /// No description provided for @quoteTemplateChoose.
  ///
  /// In zh, this message translates to:
  /// **'选择客户报价模板'**
  String get quoteTemplateChoose;

  /// No description provided for @quoteTemplateChooseHint.
  ///
  /// In zh, this message translates to:
  /// **'选择一个或多个模板。多个模板将打包下载，也可以使用系统默认格式。'**
  String get quoteTemplateChooseHint;

  /// No description provided for @quoteTemplateVersionUsage.
  ///
  /// In zh, this message translates to:
  /// **'版本 {version} · 已使用 {count} 次'**
  String quoteTemplateVersionUsage(int version, int count);

  /// No description provided for @quoteTemplateStandard.
  ///
  /// In zh, this message translates to:
  /// **'使用默认格式'**
  String get quoteTemplateStandard;

  /// No description provided for @quoteTemplateDownloadAll.
  ///
  /// In zh, this message translates to:
  /// **'全部下载'**
  String get quoteTemplateDownloadAll;

  /// No description provided for @quoteTemplateDownloadSelected.
  ///
  /// In zh, this message translates to:
  /// **'下载所选'**
  String get quoteTemplateDownloadSelected;

  /// No description provided for @businessColumnAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加列'**
  String get businessColumnAdd;

  /// No description provided for @businessColumnName.
  ///
  /// In zh, this message translates to:
  /// **'列名称'**
  String get businessColumnName;

  /// No description provided for @businessColumnSearch.
  ///
  /// In zh, this message translates to:
  /// **'输入名称，搜索已有表头'**
  String get businessColumnSearch;

  /// No description provided for @businessColumnReuseHint.
  ///
  /// In zh, this message translates to:
  /// **'选择已有表头，或创建新列。保存后可复用，新单据默认不添加。'**
  String get businessColumnReuseHint;

  /// No description provided for @businessColumnSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统表头'**
  String get businessColumnSystem;

  /// No description provided for @businessColumnReference.
  ///
  /// In zh, this message translates to:
  /// **'仅记录信息'**
  String get businessColumnReference;

  /// No description provided for @businessColumnLimit.
  ///
  /// In zh, this message translates to:
  /// **'每张单据最多添加 32 个扩展列'**
  String get businessColumnLimit;

  /// No description provided for @businessColumnAmountHint.
  ///
  /// In zh, this message translates to:
  /// **'按照添加顺序，对每行原金额依次计算；拖动表头只调整显示顺序，不改变计算顺序。空值跳过，除数不能为 0，结果必须精确且不为负数。'**
  String get businessColumnAmountHint;

  /// No description provided for @businessColumnType.
  ///
  /// In zh, this message translates to:
  /// **'内容类型'**
  String get businessColumnType;

  /// No description provided for @businessColumnText.
  ///
  /// In zh, this message translates to:
  /// **'文字'**
  String get businessColumnText;

  /// No description provided for @businessColumnNumber.
  ///
  /// In zh, this message translates to:
  /// **'数字'**
  String get businessColumnNumber;

  /// No description provided for @businessColumnCalculation.
  ///
  /// In zh, this message translates to:
  /// **'金额计算'**
  String get businessColumnCalculation;

  /// No description provided for @businessColumnAddAmount.
  ///
  /// In zh, this message translates to:
  /// **'加 (+)'**
  String get businessColumnAddAmount;

  /// No description provided for @businessColumnSubtractAmount.
  ///
  /// In zh, this message translates to:
  /// **'减 (−)'**
  String get businessColumnSubtractAmount;

  /// No description provided for @businessColumnMultiplyAmount.
  ///
  /// In zh, this message translates to:
  /// **'乘 (×)'**
  String get businessColumnMultiplyAmount;

  /// No description provided for @businessColumnDivideAmount.
  ///
  /// In zh, this message translates to:
  /// **'除 (÷)'**
  String get businessColumnDivideAmount;

  /// No description provided for @businessColumnCreate.
  ///
  /// In zh, this message translates to:
  /// **'创建并添加'**
  String get businessColumnCreate;

  /// No description provided for @businessColumnLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取表头失败，请重试'**
  String get businessColumnLoadFailed;

  /// No description provided for @businessColumnSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存表头失败，请重试'**
  String get businessColumnSaveFailed;

  /// No description provided for @businessColumnInvalid.
  ///
  /// In zh, this message translates to:
  /// **'附加列数字或计算有误，请检查数字、除数以及最终金额'**
  String get businessColumnInvalid;

  /// No description provided for @businessColumnNameEn.
  ///
  /// In zh, this message translates to:
  /// **'英文名称'**
  String get businessColumnNameEn;

  /// No description provided for @costWorkspaceTitle.
  ///
  /// In zh, this message translates to:
  /// **'成本工作台'**
  String get costWorkspaceTitle;

  /// No description provided for @costEstimate.
  ///
  /// In zh, this message translates to:
  /// **'成本测算'**
  String get costEstimate;

  /// No description provided for @costActual.
  ///
  /// In zh, this message translates to:
  /// **'实际核对'**
  String get costActual;

  /// No description provided for @costVersions.
  ///
  /// In zh, this message translates to:
  /// **'成本版本'**
  String get costVersions;

  /// No description provided for @costNew.
  ///
  /// In zh, this message translates to:
  /// **'新建成本单'**
  String get costNew;

  /// No description provided for @costName.
  ///
  /// In zh, this message translates to:
  /// **'成本方案名称'**
  String get costName;

  /// No description provided for @costBatch.
  ///
  /// In zh, this message translates to:
  /// **'测算数量'**
  String get costBatch;

  /// No description provided for @costCustomer.
  ///
  /// In zh, this message translates to:
  /// **'适用客户'**
  String get costCustomer;

  /// No description provided for @costCurrency.
  ///
  /// In zh, this message translates to:
  /// **'成本币种'**
  String get costCurrency;

  /// No description provided for @costExchangeRate.
  ///
  /// In zh, this message translates to:
  /// **'折合本币汇率'**
  String get costExchangeRate;

  /// No description provided for @costEffectiveDate.
  ///
  /// In zh, this message translates to:
  /// **'取价日期'**
  String get costEffectiveDate;

  /// No description provided for @costUsageStrategy.
  ///
  /// In zh, this message translates to:
  /// **'用量选择'**
  String get costUsageStrategy;

  /// No description provided for @costActualFirst.
  ///
  /// In zh, this message translates to:
  /// **'真实量优先，无数据用设计量'**
  String get costActualFirst;

  /// No description provided for @costDesignOnly.
  ///
  /// In zh, this message translates to:
  /// **'按设计用量'**
  String get costDesignOnly;

  /// No description provided for @costPriceStrategy.
  ///
  /// In zh, this message translates to:
  /// **'取价方式'**
  String get costPriceStrategy;

  /// No description provided for @costApprovedPrice.
  ///
  /// In zh, this message translates to:
  /// **'已批准来源价格'**
  String get costApprovedPrice;

  /// No description provided for @costManualPrice.
  ///
  /// In zh, this message translates to:
  /// **'人工方案'**
  String get costManualPrice;

  /// No description provided for @costNotes.
  ///
  /// In zh, this message translates to:
  /// **'说明'**
  String get costNotes;

  /// No description provided for @costMaterial.
  ///
  /// In zh, this message translates to:
  /// **'材料成本'**
  String get costMaterial;

  /// No description provided for @costProcess.
  ///
  /// In zh, this message translates to:
  /// **'加工成本'**
  String get costProcess;

  /// No description provided for @costManagement.
  ///
  /// In zh, this message translates to:
  /// **'管理分摊'**
  String get costManagement;

  /// No description provided for @costOther.
  ///
  /// In zh, this message translates to:
  /// **'其他费用'**
  String get costOther;

  /// No description provided for @costKnownTotal.
  ///
  /// In zh, this message translates to:
  /// **'已知成本合计'**
  String get costKnownTotal;

  /// No description provided for @costUnitCost.
  ///
  /// In zh, this message translates to:
  /// **'本产品单位成本'**
  String get costUnitCost;

  /// No description provided for @costStructure.
  ///
  /// In zh, this message translates to:
  /// **'组装结构'**
  String get costStructure;

  /// No description provided for @costFees.
  ///
  /// In zh, this message translates to:
  /// **'工序与费用'**
  String get costFees;

  /// No description provided for @costGoodsName.
  ///
  /// In zh, this message translates to:
  /// **'货品名称'**
  String get costGoodsName;

  /// No description provided for @costGoodsCode.
  ///
  /// In zh, this message translates to:
  /// **'货品编号'**
  String get costGoodsCode;

  /// No description provided for @costColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色'**
  String get costColor;

  /// No description provided for @costUnit.
  ///
  /// In zh, this message translates to:
  /// **'基本单位'**
  String get costUnit;

  /// No description provided for @costAdoptedQty.
  ///
  /// In zh, this message translates to:
  /// **'本次采用量'**
  String get costAdoptedQty;

  /// No description provided for @costUsageSource.
  ///
  /// In zh, this message translates to:
  /// **'采用来源'**
  String get costUsageSource;

  /// No description provided for @costPricingQty.
  ///
  /// In zh, this message translates to:
  /// **'计价用量'**
  String get costPricingQty;

  /// No description provided for @costPrice.
  ///
  /// In zh, this message translates to:
  /// **'采用单价'**
  String get costPrice;

  /// No description provided for @costPriceUnitRate.
  ///
  /// In zh, this message translates to:
  /// **'计价单位换算率'**
  String get costPriceUnitRate;

  /// No description provided for @costPriceSource.
  ///
  /// In zh, this message translates to:
  /// **'价格来源'**
  String get costPriceSource;

  /// No description provided for @costLineAmount.
  ///
  /// In zh, this message translates to:
  /// **'测算金额'**
  String get costLineAmount;

  /// No description provided for @costUnitContribution.
  ///
  /// In zh, this message translates to:
  /// **'每成品成本贡献'**
  String get costUnitContribution;

  /// No description provided for @costStatus.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get costStatus;

  /// No description provided for @costIncluded.
  ///
  /// In zh, this message translates to:
  /// **'参与合计'**
  String get costIncluded;

  /// No description provided for @costExplanation.
  ///
  /// In zh, this message translates to:
  /// **'计算依据'**
  String get costExplanation;

  /// No description provided for @costOverrideReason.
  ///
  /// In zh, this message translates to:
  /// **'本单覆盖原因'**
  String get costOverrideReason;

  /// No description provided for @costRestoreRecommended.
  ///
  /// In zh, this message translates to:
  /// **'恢复推荐值'**
  String get costRestoreRecommended;

  /// No description provided for @costAddPriceColumn.
  ///
  /// In zh, this message translates to:
  /// **'添加费用价格列'**
  String get costAddPriceColumn;

  /// No description provided for @costFeeName.
  ///
  /// In zh, this message translates to:
  /// **'费用名称'**
  String get costFeeName;

  /// No description provided for @costFeeMethod.
  ///
  /// In zh, this message translates to:
  /// **'计算方式'**
  String get costFeeMethod;

  /// No description provided for @costFeeCategory.
  ///
  /// In zh, this message translates to:
  /// **'成本类别'**
  String get costFeeCategory;

  /// No description provided for @costFeeBase.
  ///
  /// In zh, this message translates to:
  /// **'计费基数'**
  String get costFeeBase;

  /// No description provided for @costFeeQuantity.
  ///
  /// In zh, this message translates to:
  /// **'计价数量'**
  String get costFeeQuantity;

  /// No description provided for @costPerQuantity.
  ///
  /// In zh, this message translates to:
  /// **'单价 × 物料计价数量'**
  String get costPerQuantity;

  /// No description provided for @costPerUnit.
  ///
  /// In zh, this message translates to:
  /// **'每成品固定单价'**
  String get costPerUnit;

  /// No description provided for @costFixedBatch.
  ///
  /// In zh, this message translates to:
  /// **'本批固定额'**
  String get costFixedBatch;

  /// No description provided for @costPercent.
  ///
  /// In zh, this message translates to:
  /// **'按基数百分比'**
  String get costPercent;

  /// No description provided for @costPerCycle.
  ///
  /// In zh, this message translates to:
  /// **'每机器周期'**
  String get costPerCycle;

  /// No description provided for @costValue.
  ///
  /// In zh, this message translates to:
  /// **'单价或费率'**
  String get costValue;

  /// No description provided for @costNotApplicable.
  ///
  /// In zh, this message translates to:
  /// **'不适用'**
  String get costNotApplicable;

  /// No description provided for @costPending.
  ///
  /// In zh, this message translates to:
  /// **'待完善'**
  String get costPending;

  /// No description provided for @costComplete.
  ///
  /// In zh, this message translates to:
  /// **'已核清'**
  String get costComplete;

  /// No description provided for @costDraft.
  ///
  /// In zh, this message translates to:
  /// **'草稿'**
  String get costDraft;

  /// No description provided for @costConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已确认'**
  String get costConfirmed;

  /// No description provided for @costReview.
  ///
  /// In zh, this message translates to:
  /// **'待审核'**
  String get costReview;

  /// No description provided for @costSaveDraft.
  ///
  /// In zh, this message translates to:
  /// **'保存草稿'**
  String get costSaveDraft;

  /// No description provided for @costRecalculate.
  ///
  /// In zh, this message translates to:
  /// **'校验重算'**
  String get costRecalculate;

  /// No description provided for @costConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认成本版本'**
  String get costConfirm;

  /// No description provided for @costCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制为新草稿'**
  String get costCopy;

  /// No description provided for @costSaveTemplate.
  ///
  /// In zh, this message translates to:
  /// **'保存为成本模板'**
  String get costSaveTemplate;

  /// No description provided for @costTemplate.
  ///
  /// In zh, this message translates to:
  /// **'成本模板'**
  String get costTemplate;

  /// No description provided for @costNoTemplate.
  ///
  /// In zh, this message translates to:
  /// **'自动匹配模板'**
  String get costNoTemplate;

  /// No description provided for @costDownloadExcel.
  ///
  /// In zh, this message translates to:
  /// **'下载成本 Excel'**
  String get costDownloadExcel;

  /// No description provided for @costDownloadPdf.
  ///
  /// In zh, this message translates to:
  /// **'下载成本 PDF'**
  String get costDownloadPdf;

  /// No description provided for @costSaved.
  ///
  /// In zh, this message translates to:
  /// **'成本草稿已保存'**
  String get costSaved;

  /// No description provided for @costConfirmPrompt.
  ///
  /// In zh, this message translates to:
  /// **'确认后冻结本次用量、价格及费用。以后修改需复制新版本。'**
  String get costConfirmPrompt;

  /// No description provided for @costLeavePrompt.
  ///
  /// In zh, this message translates to:
  /// **'当前输入尚未保存到服务器。先保存草稿再切换。'**
  String get costLeavePrompt;

  /// No description provided for @costCalculationStale.
  ///
  /// In zh, this message translates to:
  /// **'输入已改变，金额等待重算'**
  String get costCalculationStale;

  /// No description provided for @costConflict.
  ///
  /// In zh, this message translates to:
  /// **'服务器版本已变化；本机输入已保留，请比较后恢复。'**
  String get costConflict;

  /// No description provided for @costRecoverLocal.
  ///
  /// In zh, this message translates to:
  /// **'恢复本机草稿'**
  String get costRecoverLocal;

  /// No description provided for @costHistory.
  ///
  /// In zh, this message translates to:
  /// **'历史快照'**
  String get costHistory;

  /// No description provided for @costVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本'**
  String get costVersion;

  /// No description provided for @costUpdated.
  ///
  /// In zh, this message translates to:
  /// **'更新时间'**
  String get costUpdated;

  /// No description provided for @costAction.
  ///
  /// In zh, this message translates to:
  /// **'操作'**
  String get costAction;

  /// No description provided for @costOpen.
  ///
  /// In zh, this message translates to:
  /// **'打开'**
  String get costOpen;

  /// No description provided for @costDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get costDelete;

  /// No description provided for @costDeleteFeePrompt.
  ///
  /// In zh, this message translates to:
  /// **'删除这项费用会改变本单成本，历史版本保留。'**
  String get costDeleteFeePrompt;

  /// No description provided for @costEmpty.
  ///
  /// In zh, this message translates to:
  /// **'尚无成本单，点击新建带出组装信息。'**
  String get costEmpty;

  /// No description provided for @costNoActual.
  ///
  /// In zh, this message translates to:
  /// **'尚无可核对的实际成本来源'**
  String get costNoActual;

  /// No description provided for @costActualKnown.
  ///
  /// In zh, this message translates to:
  /// **'已归集投入'**
  String get costActualKnown;

  /// No description provided for @costActualOutput.
  ///
  /// In zh, this message translates to:
  /// **'已分摊产出'**
  String get costActualOutput;

  /// No description provided for @costActualWip.
  ///
  /// In zh, this message translates to:
  /// **'在制余额'**
  String get costActualWip;

  /// No description provided for @costActualUnclassified.
  ///
  /// In zh, this message translates to:
  /// **'待分类金额'**
  String get costActualUnclassified;

  /// No description provided for @costActualIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'尚未覆盖全部人工及间接费用'**
  String get costActualIncomplete;

  /// No description provided for @costSourceDocument.
  ///
  /// In zh, this message translates to:
  /// **'来源单据'**
  String get costSourceDocument;

  /// No description provided for @costSourceType.
  ///
  /// In zh, this message translates to:
  /// **'来源类型'**
  String get costSourceType;

  /// No description provided for @costLocalAmount.
  ///
  /// In zh, this message translates to:
  /// **'本币金额'**
  String get costLocalAmount;

  /// No description provided for @costActualQty.
  ///
  /// In zh, this message translates to:
  /// **'实际数量'**
  String get costActualQty;

  /// No description provided for @costActualFrom.
  ///
  /// In zh, this message translates to:
  /// **'开始日期'**
  String get costActualFrom;

  /// No description provided for @costActualTo.
  ///
  /// In zh, this message translates to:
  /// **'截止日期'**
  String get costActualTo;

  /// No description provided for @costSegment.
  ///
  /// In zh, this message translates to:
  /// **'执行批次编号'**
  String get costSegment;

  /// No description provided for @costLegacy.
  ///
  /// In zh, this message translates to:
  /// **'旧主档成本参考'**
  String get costLegacy;

  /// No description provided for @costLossPolicy.
  ///
  /// In zh, this message translates to:
  /// **'委外允许损耗'**
  String get costLossPolicy;

  /// No description provided for @costLossPolicyHint.
  ///
  /// In zh, this message translates to:
  /// **'仅为委外合同默认值，不参与成本测算和真实用量学习。'**
  String get costLossPolicyHint;

  /// No description provided for @costDecimalInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的非负十进制数'**
  String get costDecimalInvalid;

  /// No description provided for @costRequiredName.
  ///
  /// In zh, this message translates to:
  /// **'请输入名称'**
  String get costRequiredName;

  /// No description provided for @costNoPermission.
  ///
  /// In zh, this message translates to:
  /// **'没有成本查看权限'**
  String get costNoPermission;

  /// No description provided for @costManual.
  ///
  /// In zh, this message translates to:
  /// **'本单覆盖'**
  String get costManual;

  /// No description provided for @costYes.
  ///
  /// In zh, this message translates to:
  /// **'是'**
  String get costYes;

  /// No description provided for @costNo.
  ///
  /// In zh, this message translates to:
  /// **'否'**
  String get costNo;

  /// No description provided for @costCopySuffix.
  ///
  /// In zh, this message translates to:
  /// **'副本'**
  String get costCopySuffix;

  /// No description provided for @costTotalLabel.
  ///
  /// In zh, this message translates to:
  /// **'整单成本'**
  String get costTotalLabel;

  /// No description provided for @costSource.
  ///
  /// In zh, this message translates to:
  /// **'来源'**
  String get costSource;

  /// No description provided for @costTemplateSaved.
  ///
  /// In zh, this message translates to:
  /// **'成本模板已保存'**
  String get costTemplateSaved;

  /// No description provided for @costFeeApplicability.
  ///
  /// In zh, this message translates to:
  /// **'填入单价即采用；清空为待填，选不适用才移除。'**
  String get costFeeApplicability;

  /// No description provided for @costSnapshotReadOnly.
  ///
  /// In zh, this message translates to:
  /// **'历史快照只读'**
  String get costSnapshotReadOnly;

  /// No description provided for @costImport.
  ///
  /// In zh, this message translates to:
  /// **'导入成本表'**
  String get costImport;

  /// No description provided for @costImportBlock.
  ///
  /// In zh, this message translates to:
  /// **'产品区块'**
  String get costImportBlock;

  /// No description provided for @costImportReview.
  ///
  /// In zh, this message translates to:
  /// **'逐行确认映射；缓存价格按本成本单币种核对，不自动采用外链公式。'**
  String get costImportReview;

  /// No description provided for @costImportKind.
  ///
  /// In zh, this message translates to:
  /// **'采用方式'**
  String get costImportKind;

  /// No description provided for @costImportMaterial.
  ///
  /// In zh, this message translates to:
  /// **'对应物料价格'**
  String get costImportMaterial;

  /// No description provided for @costImportFee.
  ///
  /// In zh, this message translates to:
  /// **'每产品费用'**
  String get costImportFee;

  /// No description provided for @costImportSkip.
  ///
  /// In zh, this message translates to:
  /// **'跳过此行'**
  String get costImportSkip;

  /// No description provided for @costImportTarget.
  ///
  /// In zh, this message translates to:
  /// **'对应物料'**
  String get costImportTarget;

  /// No description provided for @costImportReviewed.
  ///
  /// In zh, this message translates to:
  /// **'已核对'**
  String get costImportReviewed;

  /// No description provided for @costImportApply.
  ///
  /// In zh, this message translates to:
  /// **'采用到本单'**
  String get costImportApply;

  /// No description provided for @costImportNeedsReview.
  ///
  /// In zh, this message translates to:
  /// **'每行须确认；跳过须填写原因，物料须选择对应项。'**
  String get costImportNeedsReview;

  /// No description provided for @costCompare.
  ///
  /// In zh, this message translates to:
  /// **'比较版本'**
  String get costCompare;

  /// No description provided for @costCompareBefore.
  ///
  /// In zh, this message translates to:
  /// **'比较基线'**
  String get costCompareBefore;

  /// No description provided for @costBefore.
  ///
  /// In zh, this message translates to:
  /// **'修改前'**
  String get costBefore;

  /// No description provided for @costAfter.
  ///
  /// In zh, this message translates to:
  /// **'修改后'**
  String get costAfter;

  /// No description provided for @costUnchanged.
  ///
  /// In zh, this message translates to:
  /// **'未修改'**
  String get costUnchanged;

  /// No description provided for @costDirectConsumption.
  ///
  /// In zh, this message translates to:
  /// **'直接耗用'**
  String get costDirectConsumption;

  /// No description provided for @costPeriodicAllocation.
  ///
  /// In zh, this message translates to:
  /// **'周期分摊'**
  String get costPeriodicAllocation;

  /// No description provided for @costFeeEvidence.
  ///
  /// In zh, this message translates to:
  /// **'已确认加工费'**
  String get costFeeEvidence;

  /// No description provided for @costNormalLoss.
  ///
  /// In zh, this message translates to:
  /// **'已确认损耗'**
  String get costNormalLoss;

  /// No description provided for @costTaxMode.
  ///
  /// In zh, this message translates to:
  /// **'计价税口径'**
  String get costTaxMode;

  /// No description provided for @costTaxRecorded.
  ///
  /// In zh, this message translates to:
  /// **'按原记录价计成本'**
  String get costTaxRecorded;

  /// No description provided for @costTaxExclude.
  ///
  /// In zh, this message translates to:
  /// **'确认含税并扣除税额'**
  String get costTaxExclude;

  /// No description provided for @costTaxUnconfirmed.
  ///
  /// In zh, this message translates to:
  /// **'尚未确认计价口径'**
  String get costTaxUnconfirmed;

  /// No description provided for @costTaxConfirmedReason.
  ///
  /// In zh, this message translates to:
  /// **'已核对原始单据的计价税口径'**
  String get costTaxConfirmedReason;

  /// No description provided for @costFeeReuse.
  ///
  /// In zh, this message translates to:
  /// **'搜索已有费用列'**
  String get costFeeReuse;

  /// No description provided for @costDeleteColumn.
  ///
  /// In zh, this message translates to:
  /// **'移除费用列'**
  String get costDeleteColumn;

  /// No description provided for @costRoute.
  ///
  /// In zh, this message translates to:
  /// **'计价方式'**
  String get costRoute;

  /// No description provided for @costRouteAuto.
  ///
  /// In zh, this message translates to:
  /// **'按货品来源'**
  String get costRouteAuto;

  /// No description provided for @costRouteMake.
  ///
  /// In zh, this message translates to:
  /// **'自制展开'**
  String get costRouteMake;

  /// No description provided for @costRouteBuy.
  ///
  /// In zh, this message translates to:
  /// **'外购计价'**
  String get costRouteBuy;

  /// No description provided for @costRouteSubcontract.
  ///
  /// In zh, this message translates to:
  /// **'委外加工'**
  String get costRouteSubcontract;

  /// No description provided for @costRouteCustomer.
  ///
  /// In zh, this message translates to:
  /// **'客供料'**
  String get costRouteCustomer;

  /// No description provided for @costLossRange.
  ///
  /// In zh, this message translates to:
  /// **'请输入0到100，最多2位小数'**
  String get costLossRange;

  /// No description provided for @costScopeInput.
  ///
  /// In zh, this message translates to:
  /// **'原成本对象全部投入'**
  String get costScopeInput;

  /// No description provided for @costPeriodOutput.
  ///
  /// In zh, this message translates to:
  /// **'本次范围产出成本'**
  String get costPeriodOutput;

  /// No description provided for @costExcludedOutput.
  ///
  /// In zh, this message translates to:
  /// **'范围外已分配'**
  String get costExcludedOutput;

  /// No description provided for @costBudgetBaseline.
  ///
  /// In zh, this message translates to:
  /// **'已确认测算基线'**
  String get costBudgetBaseline;

  /// No description provided for @costBudgetLocal.
  ///
  /// In zh, this message translates to:
  /// **'基线完整测算（本币）'**
  String get costBudgetLocal;

  /// No description provided for @costActualRecorded.
  ///
  /// In zh, this message translates to:
  /// **'已归集实际（本币）'**
  String get costActualRecorded;

  /// No description provided for @costBasisMismatch.
  ///
  /// In zh, this message translates to:
  /// **'基线产量或币种依据与本次实际范围不一致，不计算差额。'**
  String get costBasisMismatch;

  /// No description provided for @costCoverageMismatch.
  ///
  /// In zh, this message translates to:
  /// **'实际人工及间接费尚未完整归集，仅并列展示，不计算全成本差额。'**
  String get costCoverageMismatch;

  /// No description provided for @costVariance.
  ///
  /// In zh, this message translates to:
  /// **'同口径成本差额'**
  String get costVariance;

  /// No description provided for @costDirectCost.
  ///
  /// In zh, this message translates to:
  /// **'材料与加工小计'**
  String get costDirectCost;

  /// No description provided for @inventoryCostTitle.
  ///
  /// In zh, this message translates to:
  /// **'实际成本过账'**
  String get inventoryCostTitle;

  /// No description provided for @inventoryCostPolicy.
  ///
  /// In zh, this message translates to:
  /// **'对账与启用策略'**
  String get inventoryCostPolicy;

  /// No description provided for @inventoryCostPolicyHint.
  ///
  /// In zh, this message translates to:
  /// **'先核对原库存价值与历史成本凭证。启用后仅追加新凭证；历史冲突和跨期差额须单独核定。'**
  String get inventoryCostPolicyHint;

  /// No description provided for @inventoryCostEnabled.
  ///
  /// In zh, this message translates to:
  /// **'实际成本过账已启用'**
  String get inventoryCostEnabled;

  /// No description provided for @inventoryCostDisabled.
  ///
  /// In zh, this message translates to:
  /// **'待对账启用'**
  String get inventoryCostDisabled;

  /// No description provided for @inventoryCostEnable.
  ///
  /// In zh, this message translates to:
  /// **'确认启用实际成本过账'**
  String get inventoryCostEnable;

  /// No description provided for @inventoryCostDisable.
  ///
  /// In zh, this message translates to:
  /// **'确认暂停新增实际成本过账'**
  String get inventoryCostDisable;

  /// No description provided for @inventoryCostEffectiveDate.
  ///
  /// In zh, this message translates to:
  /// **'启用生效日'**
  String get inventoryCostEffectiveDate;

  /// No description provided for @inventoryCostEvidence.
  ///
  /// In zh, this message translates to:
  /// **'实际对账依据'**
  String get inventoryCostEvidence;

  /// No description provided for @inventoryCostEvidenceRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写至少 8 个字符的实际对账依据'**
  String get inventoryCostEvidenceRequired;

  /// No description provided for @inventoryCostFrom.
  ///
  /// In zh, this message translates to:
  /// **'来源日期起'**
  String get inventoryCostFrom;

  /// No description provided for @inventoryCostTo.
  ///
  /// In zh, this message translates to:
  /// **'来源日期止'**
  String get inventoryCostTo;

  /// No description provided for @inventoryCostInvalidRange.
  ///
  /// In zh, this message translates to:
  /// **'来源开始日期不能晚于结束日期'**
  String get inventoryCostInvalidRange;

  /// No description provided for @inventoryCostLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'实际成本过账数据加载失败，请重试'**
  String get inventoryCostLoadFailed;

  /// No description provided for @inventoryCostWriteFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败，请刷新核对后重试'**
  String get inventoryCostWriteFailed;

  /// No description provided for @inventoryCostStatus.
  ///
  /// In zh, this message translates to:
  /// **'过账状态'**
  String get inventoryCostStatus;

  /// No description provided for @inventoryCostAmount.
  ///
  /// In zh, this message translates to:
  /// **'原价值变动（本币）'**
  String get inventoryCostAmount;

  /// No description provided for @inventoryCostBusinessDate.
  ///
  /// In zh, this message translates to:
  /// **'来源业务日'**
  String get inventoryCostBusinessDate;

  /// No description provided for @inventoryCostSourcePeriod.
  ///
  /// In zh, this message translates to:
  /// **'来源期间'**
  String get inventoryCostSourcePeriod;

  /// No description provided for @inventoryCostTargetPeriod.
  ///
  /// In zh, this message translates to:
  /// **'入账期间'**
  String get inventoryCostTargetPeriod;

  /// No description provided for @inventoryCostSourceType.
  ///
  /// In zh, this message translates to:
  /// **'来源类型'**
  String get inventoryCostSourceType;

  /// No description provided for @inventoryCostSourceDocument.
  ///
  /// In zh, this message translates to:
  /// **'原单据标识'**
  String get inventoryCostSourceDocument;

  /// No description provided for @inventoryCostSource.
  ///
  /// In zh, this message translates to:
  /// **'原价值过账标识'**
  String get inventoryCostSource;

  /// No description provided for @inventoryCostRevision.
  ///
  /// In zh, this message translates to:
  /// **'价值修订'**
  String get inventoryCostRevision;

  /// No description provided for @inventoryCostVoucher.
  ///
  /// In zh, this message translates to:
  /// **'总账凭证标识'**
  String get inventoryCostVoucher;

  /// No description provided for @inventoryCostAssignPeriod.
  ///
  /// In zh, this message translates to:
  /// **'指定入账期间'**
  String get inventoryCostAssignPeriod;

  /// No description provided for @inventoryCostReason.
  ///
  /// In zh, this message translates to:
  /// **'核定原因'**
  String get inventoryCostReason;

  /// No description provided for @inventoryCostReasonRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写至少 4 个字符的核定原因'**
  String get inventoryCostReasonRequired;

  /// No description provided for @inventoryCostNoOpenPeriod.
  ///
  /// In zh, this message translates to:
  /// **'查询范围内没有开放期间，请调整日期范围'**
  String get inventoryCostNoOpenPeriod;

  /// No description provided for @inventoryCostPost.
  ///
  /// In zh, this message translates to:
  /// **'追加成本凭证'**
  String get inventoryCostPost;

  /// No description provided for @inventoryCostPostHint.
  ///
  /// In zh, this message translates to:
  /// **'按原价值变动逐笔生成借贷平衡凭证，包含退回及后补差额；重试不重复入账，不改写旧凭证。'**
  String get inventoryCostPostHint;

  /// No description provided for @inventoryCostClosePeriod.
  ///
  /// In zh, this message translates to:
  /// **'关闭成本期间'**
  String get inventoryCostClosePeriod;

  /// No description provided for @inventoryCostCloseHint.
  ///
  /// In zh, this message translates to:
  /// **'关闭后禁止回写本期间。以后收到的差额需核定新的开放入账期间。'**
  String get inventoryCostCloseHint;

  /// No description provided for @inventoryCostPendingCount.
  ///
  /// In zh, this message translates to:
  /// **'期间待处理笔数'**
  String get inventoryCostPendingCount;

  /// No description provided for @inventoryCostOpen.
  ///
  /// In zh, this message translates to:
  /// **'开放'**
  String get inventoryCostOpen;

  /// No description provided for @inventoryCostClosed.
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get inventoryCostClosed;

  /// No description provided for @inventoryCostPosted.
  ///
  /// In zh, this message translates to:
  /// **'已入账'**
  String get inventoryCostPosted;

  /// No description provided for @inventoryCostReady.
  ///
  /// In zh, this message translates to:
  /// **'可入账'**
  String get inventoryCostReady;

  /// No description provided for @inventoryCostBeforeCutover.
  ///
  /// In zh, this message translates to:
  /// **'切换前历史'**
  String get inventoryCostBeforeCutover;

  /// No description provided for @inventoryCostSourcePending.
  ///
  /// In zh, this message translates to:
  /// **'来源身份待核实'**
  String get inventoryCostSourcePending;

  /// No description provided for @inventoryCostValuePending.
  ///
  /// In zh, this message translates to:
  /// **'成本待核清'**
  String get inventoryCostValuePending;

  /// No description provided for @inventoryCostLegacyConflict.
  ///
  /// In zh, this message translates to:
  /// **'历史凭证待对账'**
  String get inventoryCostLegacyConflict;

  /// No description provided for @inventoryCostTargetClosed.
  ///
  /// In zh, this message translates to:
  /// **'目标期间已关闭'**
  String get inventoryCostTargetClosed;

  /// No description provided for @inventoryCostTargetRequired.
  ///
  /// In zh, this message translates to:
  /// **'待核定入账期间'**
  String get inventoryCostTargetRequired;

  /// No description provided for @inventoryCostNoAccess.
  ///
  /// In zh, this message translates to:
  /// **'没有查看实际成本过账的权限'**
  String get inventoryCostNoAccess;

  /// No description provided for @costConvertCurrency.
  ///
  /// In zh, this message translates to:
  /// **'转换成本币种'**
  String get costConvertCurrency;

  /// No description provided for @costCurrencyConversionHint.
  ///
  /// In zh, this message translates to:
  /// **'服务端按来源与目标汇率转换金额，用量和百分比保持不变。成功后才替换本单输入，失败保留原值。'**
  String get costCurrencyConversionHint;

  /// No description provided for @costSourceExchangeRate.
  ///
  /// In zh, this message translates to:
  /// **'当前币种折合本币汇率'**
  String get costSourceExchangeRate;

  /// No description provided for @costTargetExchangeRate.
  ///
  /// In zh, this message translates to:
  /// **'目标币种折合本币汇率'**
  String get costTargetExchangeRate;

  /// No description provided for @costExchangeRateRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入明确且大于0的十进制汇率'**
  String get costExchangeRateRequired;

  /// No description provided for @costPriceNormalizedHelp.
  ///
  /// In zh, this message translates to:
  /// **'单价按本成本单币种和物料基本单位显示。原始采购单价、计价单位换算及税口径在来源详情查看。'**
  String get costPriceNormalizedHelp;

  /// No description provided for @costCurrencyConverted.
  ///
  /// In zh, this message translates to:
  /// **'成本金额已按目标币种转换，尚未保存'**
  String get costCurrencyConverted;

  /// No description provided for @costUnitContributionShort.
  ///
  /// In zh, this message translates to:
  /// **'单位成本'**
  String get costUnitContributionShort;

  /// No description provided for @costLineAmountShort.
  ///
  /// In zh, this message translates to:
  /// **'测算金额'**
  String get costLineAmountShort;

  /// No description provided for @costPendingItems.
  ///
  /// In zh, this message translates to:
  /// **'待核项目'**
  String get costPendingItems;

  /// No description provided for @costViewEvidence.
  ///
  /// In zh, this message translates to:
  /// **'查看依据'**
  String get costViewEvidence;

  /// No description provided for @costViewSource.
  ///
  /// In zh, this message translates to:
  /// **'查看来源'**
  String get costViewSource;

  /// No description provided for @costEvidenceField.
  ///
  /// In zh, this message translates to:
  /// **'依据项目'**
  String get costEvidenceField;

  /// No description provided for @costEvidenceValue.
  ///
  /// In zh, this message translates to:
  /// **'记录值'**
  String get costEvidenceValue;

  /// No description provided for @costEvidenceScope.
  ///
  /// In zh, this message translates to:
  /// **'成本范围'**
  String get costEvidenceScope;

  /// No description provided for @costEvidenceNextStep.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get costEvidenceNextStep;

  /// No description provided for @costCopyValue.
  ///
  /// In zh, this message translates to:
  /// **'复制记录值'**
  String get costCopyValue;

  /// No description provided for @costSourceUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可打开的来源入口，可复制标识交由负责岗位核对。'**
  String get costSourceUnavailable;

  /// No description provided for @costGapLabor.
  ///
  /// In zh, this message translates to:
  /// **'实际人工尚未归集'**
  String get costGapLabor;

  /// No description provided for @costGapOverhead.
  ///
  /// In zh, this message translates to:
  /// **'制造间接费用尚未归集'**
  String get costGapOverhead;

  /// No description provided for @costGapNoValuation.
  ///
  /// In zh, this message translates to:
  /// **'没有可核定的库存成本依据'**
  String get costGapNoValuation;

  /// No description provided for @costGapIdentity.
  ///
  /// In zh, this message translates to:
  /// **'历史物料身份或单位缺失'**
  String get costGapIdentity;

  /// No description provided for @costGapRevision.
  ///
  /// In zh, this message translates to:
  /// **'投入来源的修订证据缺失'**
  String get costGapRevision;

  /// No description provided for @costGapNoApprovedRevision.
  ///
  /// In zh, this message translates to:
  /// **'尚无已批准的成本版本'**
  String get costGapNoApprovedRevision;

  /// No description provided for @costGapApplying.
  ///
  /// In zh, this message translates to:
  /// **'成本分摊正在更新'**
  String get costGapApplying;

  /// No description provided for @costGapSourceRefresh.
  ///
  /// In zh, this message translates to:
  /// **'来源数据待刷新'**
  String get costGapSourceRefresh;

  /// No description provided for @costGapClassification.
  ///
  /// In zh, this message translates to:
  /// **'投入成本待分类'**
  String get costGapClassification;

  /// No description provided for @costGapOutputBasis.
  ///
  /// In zh, this message translates to:
  /// **'有效产出基数待核实'**
  String get costGapOutputBasis;

  /// No description provided for @costGapScope.
  ///
  /// In zh, this message translates to:
  /// **'归集范围尚未完整'**
  String get costGapScope;

  /// No description provided for @costGapInput.
  ///
  /// In zh, this message translates to:
  /// **'投入金额尚未核定'**
  String get costGapInput;

  /// No description provided for @costGapOther.
  ///
  /// In zh, this message translates to:
  /// **'还有成本依据需要核对'**
  String get costGapOther;

  /// No description provided for @costGapActionCharges.
  ///
  /// In zh, this message translates to:
  /// **'补齐实际费用来源，再重新核对'**
  String get costGapActionCharges;

  /// No description provided for @costGapActionHistory.
  ///
  /// In zh, this message translates to:
  /// **'核对历史原单和单位，缺证据不以当前主档回填'**
  String get costGapActionHistory;

  /// No description provided for @costGapActionRefresh.
  ///
  /// In zh, this message translates to:
  /// **'等待成本任务完成后刷新，仍未完成则核对来源任务'**
  String get costGapActionRefresh;

  /// No description provided for @costGapActionSource.
  ///
  /// In zh, this message translates to:
  /// **'查看来源凭证、退料和产出记录，补全后刷新'**
  String get costGapActionSource;

  /// No description provided for @costAmountBasis.
  ///
  /// In zh, this message translates to:
  /// **'金额依据'**
  String get costAmountBasis;

  /// No description provided for @costBookedBasis.
  ///
  /// In zh, this message translates to:
  /// **'已过账本币金额'**
  String get costBookedBasis;

  /// No description provided for @costLegacyBasis.
  ///
  /// In zh, this message translates to:
  /// **'历史金额口径未验证'**
  String get costLegacyBasis;

  /// No description provided for @costQuantityBasis.
  ///
  /// In zh, this message translates to:
  /// **'数量依据'**
  String get costQuantityBasis;

  /// No description provided for @costValueRevision.
  ///
  /// In zh, this message translates to:
  /// **'价值修订号'**
  String get costValueRevision;

  /// No description provided for @costAmountLower.
  ///
  /// In zh, this message translates to:
  /// **'金额下限（本币）'**
  String get costAmountLower;

  /// No description provided for @costAmountUpper.
  ///
  /// In zh, this message translates to:
  /// **'金额上限（本币）'**
  String get costAmountUpper;

  /// No description provided for @costSourceIdentifier.
  ///
  /// In zh, this message translates to:
  /// **'来源单据标识'**
  String get costSourceIdentifier;

  /// No description provided for @costSourceLineIdentifier.
  ///
  /// In zh, this message translates to:
  /// **'来源明细标识'**
  String get costSourceLineIdentifier;

  /// No description provided for @costEvidenceIdentifier.
  ///
  /// In zh, this message translates to:
  /// **'依据标识'**
  String get costEvidenceIdentifier;

  /// No description provided for @costGapCode.
  ///
  /// In zh, this message translates to:
  /// **'核对原因编码'**
  String get costGapCode;

  /// No description provided for @costDailyTable.
  ///
  /// In zh, this message translates to:
  /// **'成本表'**
  String get costDailyTable;

  /// No description provided for @costCalculationSettings.
  ///
  /// In zh, this message translates to:
  /// **'计算设置'**
  String get costCalculationSettings;

  /// No description provided for @costAdjustment.
  ///
  /// In zh, this message translates to:
  /// **'调整用量'**
  String get costAdjustment;

  /// No description provided for @costFinishAdjustment.
  ///
  /// In zh, this message translates to:
  /// **'完成调整'**
  String get costFinishAdjustment;

  /// No description provided for @costMoreActions.
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get costMoreActions;

  /// No description provided for @costRefreshSources.
  ///
  /// In zh, this message translates to:
  /// **'刷新来源价格与用量'**
  String get costRefreshSources;

  /// No description provided for @costDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get costDownload;

  /// No description provided for @costDownloadFormat.
  ///
  /// In zh, this message translates to:
  /// **'文件格式'**
  String get costDownloadFormat;

  /// No description provided for @costAdvancedOptions.
  ///
  /// In zh, this message translates to:
  /// **'高级选项'**
  String get costAdvancedOptions;

  /// No description provided for @costOptionalCustomer.
  ///
  /// In zh, this message translates to:
  /// **'指定客户（可选）'**
  String get costOptionalCustomer;

  /// No description provided for @costAutoCalculating.
  ///
  /// In zh, this message translates to:
  /// **'正在自动计算…'**
  String get costAutoCalculating;

  /// No description provided for @costAutomaticReady.
  ///
  /// In zh, this message translates to:
  /// **'已自动计算'**
  String get costAutomaticReady;

  /// No description provided for @costNeedsReviewCount.
  ///
  /// In zh, this message translates to:
  /// **'待核 {count} 项'**
  String costNeedsReviewCount(int count);

  /// No description provided for @costOnlyPending.
  ///
  /// In zh, this message translates to:
  /// **'只看待核'**
  String get costOnlyPending;

  /// No description provided for @costAllMaterials.
  ///
  /// In zh, this message translates to:
  /// **'全部物料'**
  String get costAllMaterials;

  /// No description provided for @costPerProductPrice.
  ///
  /// In zh, this message translates to:
  /// **'每成品费用'**
  String get costPerProductPrice;

  /// No description provided for @costMissingPriceInput.
  ///
  /// In zh, this message translates to:
  /// **'填入单价'**
  String get costMissingPriceInput;

  /// No description provided for @costDefaultFeeHelp.
  ///
  /// In zh, this message translates to:
  /// **'添加后直接在对应行填写每件产品的费用；不同算法可在高级选项中选择。'**
  String get costDefaultFeeHelp;

  /// No description provided for @costKnownPartial.
  ///
  /// In zh, this message translates to:
  /// **'已知部分成本'**
  String get costKnownPartial;

  /// No description provided for @costPriceAvailable.
  ///
  /// In zh, this message translates to:
  /// **'已取得'**
  String get costPriceAvailable;

  /// No description provided for @costAutoPrice.
  ///
  /// In zh, this message translates to:
  /// **'自动可靠来源'**
  String get costAutoPrice;

  /// No description provided for @costResultNotUpdated.
  ///
  /// In zh, this message translates to:
  /// **'结果尚未更新，请重试'**
  String get costResultNotUpdated;

  /// No description provided for @costActualFilters.
  ///
  /// In zh, this message translates to:
  /// **'筛选实际范围'**
  String get costActualFilters;

  /// No description provided for @costReturnToTable.
  ///
  /// In zh, this message translates to:
  /// **'返回成本表'**
  String get costReturnToTable;

  /// No description provided for @costActualEvidence.
  ///
  /// In zh, this message translates to:
  /// **'实际成本依据'**
  String get costActualEvidence;

  /// No description provided for @costSavedHistory.
  ///
  /// In zh, this message translates to:
  /// **'历史成本记录'**
  String get costSavedHistory;

  /// No description provided for @costAdjustEstimateQuantity.
  ///
  /// In zh, this message translates to:
  /// **'调整数量'**
  String get costAdjustEstimateQuantity;

  /// No description provided for @costEstimateBasis.
  ///
  /// In zh, this message translates to:
  /// **'按{quantity}{unit}测算'**
  String costEstimateBasis(String quantity, String unit);

  /// No description provided for @costEstimateBasisWithoutUnit.
  ///
  /// In zh, this message translates to:
  /// **'按数量{quantity}测算'**
  String costEstimateBasisWithoutUnit(String quantity);

  /// No description provided for @costProductionLoading.
  ///
  /// In zh, this message translates to:
  /// **'读取已审生产记录…'**
  String get costProductionLoading;

  /// No description provided for @costProductionUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'生产记录暂不可用，点击重试'**
  String get costProductionUnavailable;

  /// No description provided for @costProductionNone.
  ///
  /// In zh, this message translates to:
  /// **'暂无可见的已审生产记录'**
  String get costProductionNone;

  /// No description provided for @costProductionUnitPending.
  ///
  /// In zh, this message translates to:
  /// **'生产数量的原报工单位待核实'**
  String get costProductionUnitPending;

  /// No description provided for @costRecentProductionLabel.
  ///
  /// In zh, this message translates to:
  /// **'最近生产批次 {scope} · 已审有效产量 {quantity}{unit}'**
  String costRecentProductionLabel(String scope, String quantity, String unit);

  /// No description provided for @costProductionScopeHelp.
  ///
  /// In zh, this message translates to:
  /// **'当前可见生产范围的旁证：已审核报工完成量扣除已确认FQC失效；返工恢复按原来源抵扣。未审核草稿不计入，与入库数量、成本测算数量分开，不代表成本已核清。'**
  String get costProductionScopeHelp;

  /// No description provided for @costProductionBatch.
  ///
  /// In zh, this message translates to:
  /// **'生产批次'**
  String get costProductionBatch;

  /// No description provided for @costApprovedEffectiveOutput.
  ///
  /// In zh, this message translates to:
  /// **'已审有效产量'**
  String get costApprovedEffectiveOutput;

  /// No description provided for @costApprovedReportedOutput.
  ///
  /// In zh, this message translates to:
  /// **'原已审报工完成量'**
  String get costApprovedReportedOutput;

  /// No description provided for @costFqcDeductedOutput.
  ///
  /// In zh, this message translates to:
  /// **'FQC确认扣减量'**
  String get costFqcDeductedOutput;

  /// No description provided for @costReportedDefectOutput.
  ///
  /// In zh, this message translates to:
  /// **'另报不良数量'**
  String get costReportedDefectOutput;

  /// No description provided for @costProductionFirstReport.
  ///
  /// In zh, this message translates to:
  /// **'范围内首次报工日期'**
  String get costProductionFirstReport;

  /// No description provided for @costProductionLastReport.
  ///
  /// In zh, this message translates to:
  /// **'范围内最后报工日期'**
  String get costProductionLastReport;

  /// No description provided for @costProductionReportCount.
  ///
  /// In zh, this message translates to:
  /// **'有效已审报工记录数'**
  String get costProductionReportCount;

  /// No description provided for @costProductionMemberCount.
  ///
  /// In zh, this message translates to:
  /// **'范围内生产任务数'**
  String get costProductionMemberCount;

  /// No description provided for @costProductionDraftReports.
  ///
  /// In zh, this message translates to:
  /// **'另有未审核报工'**
  String get costProductionDraftReports;

  /// No description provided for @costProductionEvidence.
  ///
  /// In zh, this message translates to:
  /// **'当前已审生产依据'**
  String get costProductionEvidence;

  /// No description provided for @costProductionOpenCosts.
  ///
  /// In zh, this message translates to:
  /// **'查看该批次成本依据'**
  String get costProductionOpenCosts;

  /// No description provided for @costProductionPending.
  ///
  /// In zh, this message translates to:
  /// **'生产数量待核实，查看依据'**
  String get costProductionPending;

  /// No description provided for @costProductionSource.
  ///
  /// In zh, this message translates to:
  /// **'计算依据'**
  String get costProductionSource;

  /// No description provided for @costProductionCopyScope.
  ///
  /// In zh, this message translates to:
  /// **'复制批次标识'**
  String get costProductionCopyScope;

  /// No description provided for @costProductionSourceReport.
  ///
  /// In zh, this message translates to:
  /// **'仅计入已审核且未撤回的报工'**
  String get costProductionSourceReport;

  /// No description provided for @costProductionSourceFamily.
  ///
  /// In zh, this message translates to:
  /// **'汇总同源拆批及追加生产范围'**
  String get costProductionSourceFamily;

  /// No description provided for @costProductionSourceProgress.
  ///
  /// In zh, this message translates to:
  /// **'扣除确认的FQC失效，返工恢复抵回原来源'**
  String get costProductionSourceProgress;

  /// No description provided for @costProductionSourceUnit.
  ///
  /// In zh, this message translates to:
  /// **'保留原报工计量单位及换算证据'**
  String get costProductionSourceUnit;

  /// No description provided for @costProductionSourceDefects.
  ///
  /// In zh, this message translates to:
  /// **'另报不良独立列示，不重复扣减有效完成量'**
  String get costProductionSourceDefects;

  /// No description provided for @costProductionSourceOther.
  ///
  /// In zh, this message translates to:
  /// **'由生产报工及其关联记录提供'**
  String get costProductionSourceOther;

  /// No description provided for @costProductionProgressPending.
  ///
  /// In zh, this message translates to:
  /// **'报工与车间进度尚未核对一致，暂不显示产量'**
  String get costProductionProgressPending;

  /// No description provided for @costPerUnitLabel.
  ///
  /// In zh, this message translates to:
  /// **'每{unit}成本'**
  String costPerUnitLabel(String unit);

  /// No description provided for @costAutomaticPriceHelp.
  ///
  /// In zh, this message translates to:
  /// **'自动取自{source}，可以直接修改；修改后本单采用手工单价。'**
  String costAutomaticPriceHelp(String source);

  /// No description provided for @costEstimateAmountHelp.
  ///
  /// In zh, this message translates to:
  /// **'本物料的计价用量×采用单价，加上本行费用。例如按1000件测算、每件用料2个，则按2000个计价。这是成本测算金额，不是生产实产或实际过账金额。'**
  String get costEstimateAmountHelp;

  /// No description provided for @costUnitContributionHelp.
  ///
  /// In zh, this message translates to:
  /// **'本行材料及费用对每一个成品计量单位的成本贡献；测算金额除以测算数量。成品单位由本成本版本确定。'**
  String get costUnitContributionHelp;

  /// No description provided for @costMaterialPriceNotApplied.
  ///
  /// In zh, this message translates to:
  /// **'汇总件或客供材料不单独计入材料单价；查看计算依据了解本行口径。'**
  String get costMaterialPriceNotApplied;

  /// No description provided for @salesQuoteCustomerConfirm.
  ///
  /// In zh, this message translates to:
  /// **'登记客户同意'**
  String get salesQuoteCustomerConfirm;

  /// No description provided for @salesQuoteCustomerConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'确认客户已同意当前版本的货品、数量、单价、折扣与商业条款。登记后可生成订货单草稿；报价再次修改后须重新核价并取得客户同意。'**
  String get salesQuoteCustomerConfirmBody;

  /// No description provided for @salesQuoteCustomerConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'已登记客户同意，可生成订货单'**
  String get salesQuoteCustomerConfirmed;

  /// No description provided for @salesQuoteAwaitingCustomer.
  ///
  /// In zh, this message translates to:
  /// **'待客户同意'**
  String get salesQuoteAwaitingCustomer;

  /// No description provided for @salesQuoteAwaitingConversion.
  ///
  /// In zh, this message translates to:
  /// **'待生成订货单'**
  String get salesQuoteAwaitingConversion;

  /// No description provided for @salesQuoteAwaitingCustomerBody.
  ///
  /// In zh, this message translates to:
  /// **'财务已核价，请与客户确认当前报价；客户同意后登记确认并生成订货单，也可重新修改报价或取消。'**
  String get salesQuoteAwaitingCustomerBody;

  /// No description provided for @salesQuoteCancelQuote.
  ///
  /// In zh, this message translates to:
  /// **'取消报价'**
  String get salesQuoteCancelQuote;

  /// No description provided for @salesQuoteCancelReason.
  ///
  /// In zh, this message translates to:
  /// **'取消原因（如客户未接受报价、订单未取得）'**
  String get salesQuoteCancelReason;

  /// No description provided for @salesQuoteCancelReasonRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写取消原因'**
  String get salesQuoteCancelReasonRequired;

  /// No description provided for @salesQuoteCancelledDone.
  ///
  /// In zh, this message translates to:
  /// **'报价已取消，历史记录保留'**
  String get salesQuoteCancelledDone;

  /// No description provided for @quoteTemplateMissingTitle.
  ///
  /// In zh, this message translates to:
  /// **'此客户还没有报价模板'**
  String get quoteTemplateMissingTitle;

  /// No description provided for @quoteTemplateMissingHint.
  ///
  /// In zh, this message translates to:
  /// **'上传客户的 Excel 模板，核对列对应关系后保存。也可以先用标准格式下载。'**
  String get quoteTemplateMissingHint;

  /// No description provided for @quoteTemplateUpload.
  ///
  /// In zh, this message translates to:
  /// **'上传并学习模板'**
  String get quoteTemplateUpload;

  /// No description provided for @quoteTemplateReviewTitle.
  ///
  /// In zh, this message translates to:
  /// **'核对客户模板'**
  String get quoteTemplateReviewTitle;

  /// No description provided for @quoteTemplateReviewHint.
  ///
  /// In zh, this message translates to:
  /// **'核对工作表和字段后，保存为此客户的报价模板。相似版式更新版本，不同版式保留供选择。'**
  String get quoteTemplateReviewHint;

  /// No description provided for @quoteTemplateSaveDownload.
  ///
  /// In zh, this message translates to:
  /// **'保存模板并下载'**
  String get quoteTemplateSaveDownload;

  /// No description provided for @quoteTemplateSheet.
  ///
  /// In zh, this message translates to:
  /// **'工作表'**
  String get quoteTemplateSheet;

  /// No description provided for @quoteTemplateReference.
  ///
  /// In zh, this message translates to:
  /// **'参考列（仅填本单同名信息）'**
  String get quoteTemplateReference;

  /// No description provided for @quoteTemplateFileRequired.
  ///
  /// In zh, this message translates to:
  /// **'请上传 15 MB 以内的 xlsx 或 xls 文件'**
  String get quoteTemplateFileRequired;

  /// No description provided for @quoteTemplateUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'无法读取可回填模板，请检查 Excel 表头'**
  String get quoteTemplateUnreadable;

  /// No description provided for @quoteTemplateSaved.
  ///
  /// In zh, this message translates to:
  /// **'客户报价模板已保存'**
  String get quoteTemplateSaved;

  /// No description provided for @quoteTemplateLearningTitle.
  ///
  /// In zh, this message translates to:
  /// **'学习客户报价模板'**
  String get quoteTemplateLearningTitle;

  /// No description provided for @aiChatTitle.
  ///
  /// In zh, this message translates to:
  /// **'AI 工作助手'**
  String get aiChatTitle;

  /// No description provided for @aiChatOpen.
  ///
  /// In zh, this message translates to:
  /// **'打开 AI 工作助手（可上下拖动）'**
  String get aiChatOpen;

  /// No description provided for @aiChatClose.
  ///
  /// In zh, this message translates to:
  /// **'收起对话'**
  String get aiChatClose;

  /// No description provided for @aiChatReset.
  ///
  /// In zh, this message translates to:
  /// **'新对话'**
  String get aiChatReset;

  /// No description provided for @aiChatResetTitle.
  ///
  /// In zh, this message translates to:
  /// **'开始新对话？'**
  String get aiChatResetTitle;

  /// No description provided for @aiChatResetHint.
  ///
  /// In zh, this message translates to:
  /// **'当前对话和未使用的文件将从此窗口清除。已执行的业务操作不会撤销。'**
  String get aiChatResetHint;

  /// No description provided for @aiChatCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get aiChatCancel;

  /// No description provided for @aiChatConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get aiChatConfirm;

  /// No description provided for @aiChatWelcome.
  ///
  /// In zh, this message translates to:
  /// **'今天需要处理什么？'**
  String get aiChatWelcome;

  /// No description provided for @aiChatBoundary.
  ///
  /// In zh, this message translates to:
  /// **'按当前账号权限回答；数据查询与操作由系统逐次校验。'**
  String get aiChatBoundary;

  /// No description provided for @aiChatUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'暂时只能回答部分业务问题。'**
  String get aiChatUnavailable;

  /// No description provided for @aiChatLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法连接 AI 助手，请重试。'**
  String get aiChatLoadFailed;

  /// No description provided for @aiChatRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get aiChatRetry;

  /// No description provided for @aiChatLabel.
  ///
  /// In zh, this message translates to:
  /// **'对话内容'**
  String get aiChatLabel;

  /// No description provided for @aiChatHint.
  ///
  /// In zh, this message translates to:
  /// **'输入消息…'**
  String get aiChatHint;

  /// No description provided for @aiChatHintNoUpload.
  ///
  /// In zh, this message translates to:
  /// **'输入消息…'**
  String get aiChatHintNoUpload;

  /// No description provided for @aiChatSend.
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get aiChatSend;

  /// No description provided for @aiChatAttach.
  ///
  /// In zh, this message translates to:
  /// **'上传文件'**
  String get aiChatAttach;

  /// No description provided for @aiChatRemoveFile.
  ///
  /// In zh, this message translates to:
  /// **'移除文件'**
  String get aiChatRemoveFile;

  /// No description provided for @aiChatFileHint.
  ///
  /// In zh, this message translates to:
  /// **'支持 Excel、CSV/TXT、PDF、图片和 DOCX，最大15MB；先识别用途，再辅助填写。'**
  String get aiChatFileHint;

  /// No description provided for @aiChatFileFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法读取文件，请重新选择。'**
  String get aiChatFileFailed;

  /// No description provided for @aiChatFileLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件不能超过 15 MB。'**
  String get aiChatFileLarge;

  /// No description provided for @aiChatFileMemory.
  ///
  /// In zh, this message translates to:
  /// **'本次对话的文件已达容量上限，请开始新对话后上传。'**
  String get aiChatFileMemory;

  /// No description provided for @aiChatSending.
  ///
  /// In zh, this message translates to:
  /// **'正在理解问题…'**
  String get aiChatSending;

  /// No description provided for @aiChatUploading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取报价文件…'**
  String get aiChatUploading;

  /// No description provided for @aiChatStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get aiChatStop;

  /// No description provided for @aiChatStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止本次处理'**
  String get aiChatStopped;

  /// No description provided for @aiChatFailed.
  ///
  /// In zh, this message translates to:
  /// **'处理未完成，请稍后重试。'**
  String get aiChatFailed;

  /// No description provided for @aiChatTimeout.
  ///
  /// In zh, this message translates to:
  /// **'处理时间较长，已停止等待。请稍后重试。'**
  String get aiChatTimeout;

  /// No description provided for @aiChatGone.
  ///
  /// In zh, this message translates to:
  /// **'这次处理已过期，请开始新对话。'**
  String get aiChatGone;

  /// No description provided for @aiChatPermissionChanged.
  ///
  /// In zh, this message translates to:
  /// **'当前权限或会话已变化，对话已清除。请刷新后重试。'**
  String get aiChatPermissionChanged;

  /// No description provided for @aiChatOpenDraft.
  ///
  /// In zh, this message translates to:
  /// **'核对并新建订货单'**
  String get aiChatOpenDraft;

  /// No description provided for @aiChatDraftHint.
  ///
  /// In zh, this message translates to:
  /// **'请核对客户、货品、数量和价格后保存。'**
  String get aiChatDraftHint;

  /// No description provided for @aiChatUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'此操作暂不支持，请到对应业务页面处理。'**
  String get aiChatUnsupported;

  /// No description provided for @aiChatEmptyReply.
  ///
  /// In zh, this message translates to:
  /// **'本次未返回可显示的答复，请重新描述你的问题。'**
  String get aiChatEmptyReply;

  /// No description provided for @aiChatYou.
  ///
  /// In zh, this message translates to:
  /// **'你'**
  String get aiChatYou;

  /// No description provided for @aiChatAssistant.
  ///
  /// In zh, this message translates to:
  /// **'助手'**
  String get aiChatAssistant;

  /// No description provided for @aiChatDraftUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'无法打开此草稿，请重新上传文件。'**
  String get aiChatDraftUnavailable;

  /// No description provided for @aiChatConfirmPermission.
  ///
  /// In zh, this message translates to:
  /// **'核对授权内容'**
  String get aiChatConfirmPermission;

  /// No description provided for @aiChatPermissionDone.
  ///
  /// In zh, this message translates to:
  /// **'授权已完成'**
  String get aiChatPermissionDone;

  /// No description provided for @aiChatMoveUp.
  ///
  /// In zh, this message translates to:
  /// **'向上移动助手'**
  String get aiChatMoveUp;

  /// No description provided for @aiChatMoveDown.
  ///
  /// In zh, this message translates to:
  /// **'向下移动助手'**
  String get aiChatMoveDown;

  /// No description provided for @aiChatPageAware.
  ///
  /// In zh, this message translates to:
  /// **'正在帮助：当前页面'**
  String get aiChatPageAware;

  /// No description provided for @aiChatPageOff.
  ///
  /// In zh, this message translates to:
  /// **'结合当前页面回答'**
  String get aiChatPageOff;

  /// No description provided for @aiChatPageHint.
  ///
  /// In zh, this message translates to:
  /// **'只使用页面与字段说明，不读取你的表单内容。'**
  String get aiChatPageHint;

  /// No description provided for @aiChatPageQuestion.
  ///
  /// In zh, this message translates to:
  /// **'这个页面怎么填写？请举个例子。'**
  String get aiChatPageQuestion;

  /// No description provided for @aiChatGrantDetails.
  ///
  /// In zh, this message translates to:
  /// **'请核对目标人员、权限和范围，确认后需重新验证密码。'**
  String get aiChatGrantDetails;

  /// No description provided for @aiChatGrantExpired.
  ///
  /// In zh, this message translates to:
  /// **'授权建议已过期，请重新发起。'**
  String get aiChatGrantExpired;

  /// No description provided for @aiChatGrantUnknown.
  ///
  /// In zh, this message translates to:
  /// **'授权结果暂未确认。请在权限管理页核查，再决定是否重试。'**
  String get aiChatGrantUnknown;

  /// No description provided for @aiChatAttachmentQuestion.
  ///
  /// In zh, this message translates to:
  /// **'请分析这份文件，判断适合办理的业务并辅助填写。'**
  String get aiChatAttachmentQuestion;

  /// No description provided for @aiChatLimit.
  ///
  /// In zh, this message translates to:
  /// **'本次对话较长，请开始新对话后继续。'**
  String get aiChatLimit;

  /// No description provided for @aiChatPermissionTarget.
  ///
  /// In zh, this message translates to:
  /// **'目标人员'**
  String get aiChatPermissionTarget;

  /// No description provided for @aiChatPermissionItem.
  ///
  /// In zh, this message translates to:
  /// **'授予权限'**
  String get aiChatPermissionItem;

  /// No description provided for @aiChatPermissionScope.
  ///
  /// In zh, this message translates to:
  /// **'数据范围'**
  String get aiChatPermissionScope;

  /// No description provided for @aiChatPermissionExpiry.
  ///
  /// In zh, this message translates to:
  /// **'有效期至'**
  String get aiChatPermissionExpiry;

  /// No description provided for @aiChatPendingGrant.
  ///
  /// In zh, this message translates to:
  /// **'待你核对确认'**
  String get aiChatPendingGrant;

  /// No description provided for @aiChatFileReady.
  ///
  /// In zh, this message translates to:
  /// **'已读取文件，可继续发送问题'**
  String get aiChatFileReady;

  /// No description provided for @aiChatSendAgain.
  ///
  /// In zh, this message translates to:
  /// **'再次发送'**
  String get aiChatSendAgain;

  /// No description provided for @aiChatDraftOpened.
  ///
  /// In zh, this message translates to:
  /// **'已打开核对页面'**
  String get aiChatDraftOpened;

  /// No description provided for @aiChatFileMissing.
  ///
  /// In zh, this message translates to:
  /// **'原文件已不在此对话中，请重新上传后新建，确保来源文件一同保存。'**
  String get aiChatFileMissing;

  /// No description provided for @aiChatPrivacyNotice.
  ///
  /// In zh, this message translates to:
  /// **'对话文字由管理员配置的 AI 服务处理，请勿输入密码等敏感信息。'**
  String get aiChatPrivacyNotice;

  /// No description provided for @aiChatReceived.
  ///
  /// In zh, this message translates to:
  /// **'已送达，正在等待回复…'**
  String get aiChatReceived;

  /// No description provided for @aiChatRequestRejected.
  ///
  /// In zh, this message translates to:
  /// **'这条消息未成功提交。'**
  String get aiChatRequestRejected;

  /// No description provided for @aiChatDeliveryUnknown.
  ///
  /// In zh, this message translates to:
  /// **'送达状态未确认；再次发送会发起新请求。'**
  String get aiChatDeliveryUnknown;

  /// No description provided for @aiChatReplyFailed.
  ///
  /// In zh, this message translates to:
  /// **'消息已送达，AI 未能完成回复。'**
  String get aiChatReplyFailed;

  /// No description provided for @aiChatReplyInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'消息已受理，暂未能读取结果。'**
  String get aiChatReplyInterrupted;

  /// No description provided for @aiChatWaitingStopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止等待这条消息的回复。'**
  String get aiChatWaitingStopped;

  /// No description provided for @aiChatRetryMessage.
  ///
  /// In zh, this message translates to:
  /// **'重试此消息'**
  String get aiChatRetryMessage;

  /// No description provided for @aiChatCheckReply.
  ///
  /// In zh, this message translates to:
  /// **'重新查看结果'**
  String get aiChatCheckReply;

  /// No description provided for @aiChatInfo.
  ///
  /// In zh, this message translates to:
  /// **'AI 使用说明'**
  String get aiChatInfo;

  /// No description provided for @aiChatInfoDone.
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get aiChatInfoDone;

  /// No description provided for @aiChatDocumentReading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取文件'**
  String get aiChatDocumentReading;

  /// No description provided for @aiChatDocumentParsing.
  ///
  /// In zh, this message translates to:
  /// **'正在识别文件内容'**
  String get aiChatDocumentParsing;

  /// No description provided for @aiChatDocumentClassifying.
  ///
  /// In zh, this message translates to:
  /// **'正在判断文件用途'**
  String get aiChatDocumentClassifying;

  /// No description provided for @aiChatDocumentReady.
  ///
  /// In zh, this message translates to:
  /// **'文件已分析'**
  String get aiChatDocumentReady;

  /// No description provided for @aiChatDocumentSourceMismatch.
  ///
  /// In zh, this message translates to:
  /// **'文件来源校验失败，请重新选择原文件。'**
  String get aiChatDocumentSourceMismatch;

  /// No description provided for @aiChatDocumentOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'页面未能打开，请重试。'**
  String get aiChatDocumentOpenFailed;

  /// No description provided for @aiChatDocumentManualSave.
  ///
  /// In zh, this message translates to:
  /// **'尚未保存，请核对后保存。'**
  String get aiChatDocumentManualSave;

  /// No description provided for @aiChatDocumentPlanSteps.
  ///
  /// In zh, this message translates to:
  /// **'处理步骤'**
  String get aiChatDocumentPlanSteps;

  /// No description provided for @aiChatDocumentUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前用途尚未接入辅助填写，请按识别说明到对应页面处理。'**
  String get aiChatDocumentUnsupported;

  /// No description provided for @aiChatDocumentOpened.
  ///
  /// In zh, this message translates to:
  /// **'表单已打开，请到表单或任务中心继续。'**
  String get aiChatDocumentOpened;

  /// No description provided for @aiChatGuidedParsing.
  ///
  /// In zh, this message translates to:
  /// **'识别文件'**
  String get aiChatGuidedParsing;

  /// No description provided for @aiChatGuidedValidating.
  ///
  /// In zh, this message translates to:
  /// **'正在检查文件'**
  String get aiChatGuidedValidating;

  /// No description provided for @aiChatGuidedRecognizing.
  ///
  /// In zh, this message translates to:
  /// **'正在识别客户与明细'**
  String get aiChatGuidedRecognizing;

  /// No description provided for @aiChatGuidedMatching.
  ///
  /// In zh, this message translates to:
  /// **'客户与货品匹配'**
  String get aiChatGuidedMatching;

  /// No description provided for @aiChatGuidedReview.
  ///
  /// In zh, this message translates to:
  /// **'等待核对匹配结果'**
  String get aiChatGuidedReview;

  /// No description provided for @aiChatGuidedFilling.
  ///
  /// In zh, this message translates to:
  /// **'正在填入已核对的内容'**
  String get aiChatGuidedFilling;

  /// No description provided for @aiChatGuidedHeader.
  ///
  /// In zh, this message translates to:
  /// **'填写表头'**
  String get aiChatGuidedHeader;

  /// No description provided for @aiChatGuidedRows.
  ///
  /// In zh, this message translates to:
  /// **'填写明细'**
  String get aiChatGuidedRows;

  /// No description provided for @aiChatGuidedFilled.
  ///
  /// In zh, this message translates to:
  /// **'已填写'**
  String get aiChatGuidedFilled;

  /// No description provided for @aiChatGuidedManualSave.
  ///
  /// In zh, this message translates to:
  /// **'核对后保存'**
  String get aiChatGuidedManualSave;

  /// No description provided for @aiChatGuidedWaiting.
  ///
  /// In zh, this message translates to:
  /// **'已暂停，请核对后继续'**
  String get aiChatGuidedWaiting;

  /// No description provided for @aiChatGuidedExisting.
  ///
  /// In zh, this message translates to:
  /// **'已保留你的现有输入，请核对后继续。'**
  String get aiChatGuidedExisting;

  /// No description provided for @aiChatGuidedNoMasterWrites.
  ///
  /// In zh, this message translates to:
  /// **'原文件已保留；新增客户、货品或扩展列需要你到对应页面操作。'**
  String get aiChatGuidedNoMasterWrites;

  /// No description provided for @aiChatGuidedMasterManual.
  ///
  /// In zh, this message translates to:
  /// **'新增主档需要你手动操作，请先完成后再选择。'**
  String get aiChatGuidedMasterManual;

  /// No description provided for @aiChatGuidedClient.
  ///
  /// In zh, this message translates to:
  /// **'客户'**
  String get aiChatGuidedClient;

  /// No description provided for @aiChatGuidedFilledFields.
  ///
  /// In zh, this message translates to:
  /// **'已填写内容'**
  String get aiChatGuidedFilledFields;

  /// No description provided for @aiChatGuidedLocalSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'本机草稿保存失败，原文件仍在当前页面。请保持页面并重试，勿关闭。'**
  String get aiChatGuidedLocalSaveFailed;

  /// No description provided for @aiChatGuidedExpenseSaved.
  ///
  /// In zh, this message translates to:
  /// **'报销单已保存'**
  String get aiChatGuidedExpenseSaved;

  /// No description provided for @aiChatGuidedInvoiceRegister.
  ///
  /// In zh, this message translates to:
  /// **'上传原件并登记发票'**
  String get aiChatGuidedInvoiceRegister;

  /// No description provided for @aiChatGuidedOpenSaved.
  ///
  /// In zh, this message translates to:
  /// **'查看已保存的报销单'**
  String get aiChatGuidedOpenSaved;

  /// No description provided for @aiChatGuidedUploadUncertain.
  ///
  /// In zh, this message translates to:
  /// **'原件上传结果未确认，未重复上传。请查看已保存报销中的原件后再核对。'**
  String get aiChatGuidedUploadUncertain;

  /// No description provided for @aiChatGuidedInvoiceFields.
  ///
  /// In zh, this message translates to:
  /// **'发票信息'**
  String get aiChatGuidedInvoiceFields;

  /// No description provided for @aiChatGuidedInvoiceReview.
  ///
  /// In zh, this message translates to:
  /// **'请对照原发票核对。'**
  String get aiChatGuidedInvoiceReview;

  /// No description provided for @aiChatInvoiceInvoiceType.
  ///
  /// In zh, this message translates to:
  /// **'发票类型'**
  String get aiChatInvoiceInvoiceType;

  /// No description provided for @aiChatInvoiceInvoiceCode.
  ///
  /// In zh, this message translates to:
  /// **'发票代码'**
  String get aiChatInvoiceInvoiceCode;

  /// No description provided for @aiChatInvoiceInvoiceNo.
  ///
  /// In zh, this message translates to:
  /// **'发票号码'**
  String get aiChatInvoiceInvoiceNo;

  /// No description provided for @aiChatInvoiceIssueDate.
  ///
  /// In zh, this message translates to:
  /// **'开票日期'**
  String get aiChatInvoiceIssueDate;

  /// No description provided for @aiChatInvoiceSellerName.
  ///
  /// In zh, this message translates to:
  /// **'销售方名称'**
  String get aiChatInvoiceSellerName;

  /// No description provided for @aiChatInvoiceSellerTaxNo.
  ///
  /// In zh, this message translates to:
  /// **'销售方税号'**
  String get aiChatInvoiceSellerTaxNo;

  /// No description provided for @aiChatInvoiceBuyerName.
  ///
  /// In zh, this message translates to:
  /// **'购买方名称'**
  String get aiChatInvoiceBuyerName;

  /// No description provided for @aiChatInvoiceBuyerTaxNo.
  ///
  /// In zh, this message translates to:
  /// **'购买方税号'**
  String get aiChatInvoiceBuyerTaxNo;

  /// No description provided for @aiChatInvoiceAmountExclTax.
  ///
  /// In zh, this message translates to:
  /// **'不含税金额'**
  String get aiChatInvoiceAmountExclTax;

  /// No description provided for @aiChatInvoiceTaxAmount.
  ///
  /// In zh, this message translates to:
  /// **'税额'**
  String get aiChatInvoiceTaxAmount;

  /// No description provided for @aiChatInvoiceTotalAmount.
  ///
  /// In zh, this message translates to:
  /// **'价税合计'**
  String get aiChatInvoiceTotalAmount;

  /// No description provided for @aiChatInvoiceItemSummary.
  ///
  /// In zh, this message translates to:
  /// **'项目摘要'**
  String get aiChatInvoiceItemSummary;

  /// No description provided for @aiChatInvoiceTypeGeneral.
  ///
  /// In zh, this message translates to:
  /// **'增值税电子普票'**
  String get aiChatInvoiceTypeGeneral;

  /// No description provided for @aiChatInvoiceTypeSpecial.
  ///
  /// In zh, this message translates to:
  /// **'增值税专票'**
  String get aiChatInvoiceTypeSpecial;

  /// No description provided for @aiChatInvoiceTypeDigital.
  ///
  /// In zh, this message translates to:
  /// **'数电发票'**
  String get aiChatInvoiceTypeDigital;

  /// No description provided for @aiChatInvoiceTypePaperGeneral.
  ///
  /// In zh, this message translates to:
  /// **'纸质普票'**
  String get aiChatInvoiceTypePaperGeneral;

  /// No description provided for @aiChatInvoiceTypePaperSpecial.
  ///
  /// In zh, this message translates to:
  /// **'纸质专票'**
  String get aiChatInvoiceTypePaperSpecial;

  /// No description provided for @aiChatInvoiceTypeOther.
  ///
  /// In zh, this message translates to:
  /// **'其他票据'**
  String get aiChatInvoiceTypeOther;

  /// No description provided for @aiChatGuidedQuoteRequest.
  ///
  /// In zh, this message translates to:
  /// **'请根据这份文件新建销售报价单，供我核对。'**
  String get aiChatGuidedQuoteRequest;

  /// No description provided for @aiChatGuidedOrderRequest.
  ///
  /// In zh, this message translates to:
  /// **'请根据这份文件填写当前销售订货单，供我核对。'**
  String get aiChatGuidedOrderRequest;

  /// No description provided for @aiChatDocumentLongRequest.
  ///
  /// In zh, this message translates to:
  /// **'文件处理说明较长，尚未完整分析全部要求。请明确选择要继续的流程。'**
  String get aiChatDocumentLongRequest;

  /// No description provided for @quoteTemplateMappingRequired.
  ///
  /// In zh, this message translates to:
  /// **'请保留数量，以及型号或品名字段'**
  String get quoteTemplateMappingRequired;

  /// No description provided for @quoteTemplateMappingDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'同一字段只能对应一列，请调整重复对应'**
  String get quoteTemplateMappingDuplicate;

  /// No description provided for @aiAuditTitle.
  ///
  /// In zh, this message translates to:
  /// **'使用记录与费用'**
  String get aiAuditTitle;

  /// No description provided for @aiAuditRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新记录'**
  String get aiAuditRefresh;

  /// No description provided for @aiAuditLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'记录暂时读不到，请重试。'**
  String get aiAuditLoadFailed;

  /// No description provided for @aiAuditPeriod.
  ///
  /// In zh, this message translates to:
  /// **'时间'**
  String get aiAuditPeriod;

  /// No description provided for @aiAuditRecentDays.
  ///
  /// In zh, this message translates to:
  /// **'近 {days} 天'**
  String aiAuditRecentDays(int days);

  /// No description provided for @aiAuditUser.
  ///
  /// In zh, this message translates to:
  /// **'使用人'**
  String get aiAuditUser;

  /// No description provided for @aiAuditAllUsers.
  ///
  /// In zh, this message translates to:
  /// **'全部员工'**
  String get aiAuditAllUsers;

  /// No description provided for @aiAuditProvider.
  ///
  /// In zh, this message translates to:
  /// **'AI 服务'**
  String get aiAuditProvider;

  /// No description provided for @aiAuditAllProviders.
  ///
  /// In zh, this message translates to:
  /// **'全部服务'**
  String get aiAuditAllProviders;

  /// No description provided for @aiAuditSummary.
  ///
  /// In zh, this message translates to:
  /// **'记录 {uses} 条 · 调用模型 {calls} 次'**
  String aiAuditSummary(int uses, int calls);

  /// No description provided for @aiAuditPlatformOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅统计本平台。估算费用按设置的单价计算。'**
  String get aiAuditPlatformOnly;

  /// No description provided for @aiAuditByUser.
  ///
  /// In zh, this message translates to:
  /// **'按员工查看'**
  String get aiAuditByUser;

  /// No description provided for @aiAuditUses.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条'**
  String aiAuditUses(int count);

  /// No description provided for @aiAuditEmpty.
  ///
  /// In zh, this message translates to:
  /// **'这段时间没有记录。'**
  String get aiAuditEmpty;

  /// No description provided for @aiAuditPagination.
  ///
  /// In zh, this message translates to:
  /// **'共 {total} 条 · 第 {page} 页'**
  String aiAuditPagination(int total, int page);

  /// No description provided for @aiAuditPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一页'**
  String get aiAuditPrevious;

  /// No description provided for @aiAuditNext.
  ///
  /// In zh, this message translates to:
  /// **'下一页'**
  String get aiAuditNext;

  /// No description provided for @aiAuditBillingTitle.
  ///
  /// In zh, this message translates to:
  /// **'计费方式与套餐额度'**
  String get aiAuditBillingTitle;

  /// No description provided for @aiAuditSelectProvider.
  ///
  /// In zh, this message translates to:
  /// **'选择服务'**
  String get aiAuditSelectProvider;

  /// No description provided for @aiAuditActualCost.
  ///
  /// In zh, this message translates to:
  /// **'实际费用：{currency} {amount}'**
  String aiAuditActualCost(String currency, String amount);

  /// No description provided for @aiAuditEstimatedCost.
  ///
  /// In zh, this message translates to:
  /// **'估算费用：{currency} {amount}'**
  String aiAuditEstimatedCost(String currency, String amount);

  /// No description provided for @aiAuditUnknownCost.
  ///
  /// In zh, this message translates to:
  /// **'{count} 次调用费用待确认'**
  String aiAuditUnknownCost(int count);

  /// No description provided for @aiAuditLocalOnly.
  ///
  /// In zh, this message translates to:
  /// **'本地处理，未调用模型'**
  String get aiAuditLocalOnly;

  /// No description provided for @aiAuditCostPending.
  ///
  /// In zh, this message translates to:
  /// **'费用尚未核定'**
  String get aiAuditCostPending;

  /// No description provided for @aiAuditQuestionMissing.
  ///
  /// In zh, this message translates to:
  /// **'{kind} · 未保留问题内容'**
  String aiAuditQuestionMissing(String kind);

  /// No description provided for @aiAuditSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get aiAuditSucceeded;

  /// No description provided for @aiAuditFailed.
  ///
  /// In zh, this message translates to:
  /// **'未完成'**
  String get aiAuditFailed;

  /// No description provided for @aiAuditCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get aiAuditCancelled;

  /// No description provided for @aiAuditQueued.
  ///
  /// In zh, this message translates to:
  /// **'排队中'**
  String get aiAuditQueued;

  /// No description provided for @aiAuditRunning.
  ///
  /// In zh, this message translates to:
  /// **'处理中'**
  String get aiAuditRunning;

  /// No description provided for @aiAuditKindChat.
  ///
  /// In zh, this message translates to:
  /// **'工作对话'**
  String get aiAuditKindChat;

  /// No description provided for @aiAuditKindDocument.
  ///
  /// In zh, this message translates to:
  /// **'文件分析'**
  String get aiAuditKindDocument;

  /// No description provided for @aiAuditKindSales.
  ///
  /// In zh, this message translates to:
  /// **'销售文件填写'**
  String get aiAuditKindSales;

  /// No description provided for @aiAuditKindOther.
  ///
  /// In zh, this message translates to:
  /// **'AI 处理'**
  String get aiAuditKindOther;

  /// No description provided for @aiAuditPurpose.
  ///
  /// In zh, this message translates to:
  /// **'用途：{kind}'**
  String aiAuditPurpose(String kind);

  /// No description provided for @aiAuditNonWorkRefused.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝非工作问题'**
  String get aiAuditNonWorkRefused;

  /// No description provided for @aiAuditTokens.
  ///
  /// In zh, this message translates to:
  /// **'调用模型 {calls} 次 · 输入 {input} · 输出 {output}'**
  String aiAuditTokens(int calls, String input, String output);

  /// No description provided for @aiAuditTokenCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} token'**
  String aiAuditTokenCount(int count);

  /// No description provided for @aiAuditNotReturned.
  ///
  /// In zh, this message translates to:
  /// **'未返回'**
  String get aiAuditNotReturned;

  /// No description provided for @aiAuditPersonUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未登记姓名'**
  String get aiAuditPersonUnknown;

  /// No description provided for @aiAuditBillingLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'计费设置暂时读不到。'**
  String get aiAuditBillingLoadFailed;

  /// No description provided for @aiAuditPriceInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请填写有效的输入、输出单价。'**
  String get aiAuditPriceInvalid;

  /// No description provided for @aiAuditBillingSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存，仅影响后续调用。'**
  String get aiAuditBillingSaved;

  /// No description provided for @aiAuditSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请重试。'**
  String get aiAuditSaveFailed;

  /// No description provided for @aiAuditModel.
  ///
  /// In zh, this message translates to:
  /// **'模型：{model}'**
  String aiAuditModel(String model);

  /// No description provided for @aiAuditReloadBilling.
  ///
  /// In zh, this message translates to:
  /// **'重新读取计费设置'**
  String get aiAuditReloadBilling;

  /// No description provided for @aiAuditBillingMode.
  ///
  /// In zh, this message translates to:
  /// **'计费方式'**
  String get aiAuditBillingMode;

  /// No description provided for @aiAuditUnknownBilling.
  ///
  /// In zh, this message translates to:
  /// **'尚未设置'**
  String get aiAuditUnknownBilling;

  /// No description provided for @aiAuditMetered.
  ///
  /// In zh, this message translates to:
  /// **'按用量计费'**
  String get aiAuditMetered;

  /// No description provided for @aiAuditSubscription.
  ///
  /// In zh, this message translates to:
  /// **'套餐'**
  String get aiAuditSubscription;

  /// No description provided for @aiAuditCurrency.
  ///
  /// In zh, this message translates to:
  /// **'币种'**
  String get aiAuditCurrency;

  /// No description provided for @aiAuditCny.
  ///
  /// In zh, this message translates to:
  /// **'人民币 CNY'**
  String get aiAuditCny;

  /// No description provided for @aiAuditUsd.
  ///
  /// In zh, this message translates to:
  /// **'美元 USD'**
  String get aiAuditUsd;

  /// No description provided for @aiAuditInputPrice.
  ///
  /// In zh, this message translates to:
  /// **'每百万输入 token 单价'**
  String get aiAuditInputPrice;

  /// No description provided for @aiAuditOutputPrice.
  ///
  /// In zh, this message translates to:
  /// **'每百万输出 token 单价'**
  String get aiAuditOutputPrice;

  /// No description provided for @aiAuditPriceHint.
  ///
  /// In zh, this message translates to:
  /// **'请按服务商账单填写。这里计算估算费用，不是服务商扣费账单。'**
  String get aiAuditPriceHint;

  /// No description provided for @aiAuditFiveHourQuota.
  ///
  /// In zh, this message translates to:
  /// **'五小时余额：暂未接入'**
  String get aiAuditFiveHourQuota;

  /// No description provided for @aiAuditWeeklyQuota.
  ///
  /// In zh, this message translates to:
  /// **'每周余额：暂未接入'**
  String get aiAuditWeeklyQuota;

  /// No description provided for @aiAuditQuotaHint.
  ///
  /// In zh, this message translates to:
  /// **'需要服务商提供额度查询接口。'**
  String get aiAuditQuotaHint;

  /// No description provided for @aiAuditSaveBilling.
  ///
  /// In zh, this message translates to:
  /// **'保存计费设置'**
  String get aiAuditSaveBilling;

  /// No description provided for @aiAuditEur.
  ///
  /// In zh, this message translates to:
  /// **'欧元 EUR'**
  String get aiAuditEur;

  /// No description provided for @aiAuditHkd.
  ///
  /// In zh, this message translates to:
  /// **'港币 HKD'**
  String get aiAuditHkd;

  /// No description provided for @aiAuditJpy.
  ///
  /// In zh, this message translates to:
  /// **'日元 JPY'**
  String get aiAuditJpy;

  /// No description provided for @aiAuditKrw.
  ///
  /// In zh, this message translates to:
  /// **'韩元 KRW'**
  String get aiAuditKrw;

  /// No description provided for @aiAuditPurposeCost.
  ///
  /// In zh, this message translates to:
  /// **'查成本'**
  String get aiAuditPurposeCost;

  /// No description provided for @aiAuditPurposeStock.
  ///
  /// In zh, this message translates to:
  /// **'查库存'**
  String get aiAuditPurposeStock;

  /// No description provided for @aiAuditPurposeCredit.
  ///
  /// In zh, this message translates to:
  /// **'查客户信用'**
  String get aiAuditPurposeCredit;

  /// No description provided for @aiAuditPurposeOrder.
  ///
  /// In zh, this message translates to:
  /// **'准备订货单'**
  String get aiAuditPurposeOrder;

  /// No description provided for @aiAuditPurposeQuote.
  ///
  /// In zh, this message translates to:
  /// **'准备报价单'**
  String get aiAuditPurposeQuote;

  /// No description provided for @aiAuditPurposeExpense.
  ///
  /// In zh, this message translates to:
  /// **'准备报销申请'**
  String get aiAuditPurposeExpense;

  /// No description provided for @aiAuditPurposeProduction.
  ///
  /// In zh, this message translates to:
  /// **'查在产产品'**
  String get aiAuditPurposeProduction;

  /// No description provided for @aiAuditPurposeWorkbench.
  ///
  /// In zh, this message translates to:
  /// **'查工作待办'**
  String get aiAuditPurposeWorkbench;

  /// No description provided for @aiAuditPurposePageHelp.
  ///
  /// In zh, this message translates to:
  /// **'了解页面填写方法'**
  String get aiAuditPurposePageHelp;

  /// No description provided for @aiAuditPurposeGrant.
  ///
  /// In zh, this message translates to:
  /// **'准备授权建议'**
  String get aiAuditPurposeGrant;

  /// No description provided for @aiAuditProviders.
  ///
  /// In zh, this message translates to:
  /// **'服务：{names}'**
  String aiAuditProviders(String names);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ko', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ko':
      return AppLocalizationsKo();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
