import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
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
  ];

  /// 应用标题
  ///
  /// In zh, this message translates to:
  /// **'优腾·综合管理平台'**
  String get appTitle;

  /// 应用代号
  ///
  /// In zh, this message translates to:
  /// **'UTEN IMP'**
  String get appName;

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

  /// No description provided for @commonDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get commonDelete;

  /// No description provided for @commonEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get commonEdit;

  /// No description provided for @commonAdd.
  ///
  /// In zh, this message translates to:
  /// **'新增'**
  String get commonAdd;

  /// No description provided for @commonSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get commonSearch;

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

  /// No description provided for @commonClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get commonClose;

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

  /// No description provided for @commonFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败'**
  String get commonFailed;

  /// No description provided for @commonMore.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get commonMore;

  /// No description provided for @commonViewAll.
  ///
  /// In zh, this message translates to:
  /// **'查看全部'**
  String get commonViewAll;

  /// No description provided for @commonAction.
  ///
  /// In zh, this message translates to:
  /// **'操作'**
  String get commonAction;

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

  /// No description provided for @loginRememberMe.
  ///
  /// In zh, this message translates to:
  /// **'记住此设备'**
  String get loginRememberMe;

  /// No description provided for @loginForgotPassword.
  ///
  /// In zh, this message translates to:
  /// **'忘记密码？'**
  String get loginForgotPassword;

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

  /// No description provided for @loginSuccess.
  ///
  /// In zh, this message translates to:
  /// **'登录成功'**
  String get loginSuccess;

  /// No description provided for @loginFailed.
  ///
  /// In zh, this message translates to:
  /// **'账号或密码错误'**
  String get loginFailed;

  /// No description provided for @loginFooter.
  ///
  /// In zh, this message translates to:
  /// **'© 2026 优腾 · 综合管理平台'**
  String get loginFooter;

  /// No description provided for @navDashboard.
  ///
  /// In zh, this message translates to:
  /// **'工作台'**
  String get navDashboard;

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

  /// No description provided for @dashboardWelcome.
  ///
  /// In zh, this message translates to:
  /// **'欢迎，{name}'**
  String dashboardWelcome(Object name);

  /// No description provided for @dashboardWelcomeSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'今天也要加油哦'**
  String get dashboardWelcomeSubtitle;

  /// No description provided for @dashboardTodayStats.
  ///
  /// In zh, this message translates to:
  /// **'今日概览'**
  String get dashboardTodayStats;

  /// No description provided for @dashboardQuickActions.
  ///
  /// In zh, this message translates to:
  /// **'快捷操作'**
  String get dashboardQuickActions;

  /// No description provided for @statTodayOutput.
  ///
  /// In zh, this message translates to:
  /// **'今日产量'**
  String get statTodayOutput;

  /// No description provided for @statOutputUnit.
  ///
  /// In zh, this message translates to:
  /// **'件'**
  String get statOutputUnit;

  /// No description provided for @statInventory.
  ///
  /// In zh, this message translates to:
  /// **'当前库存'**
  String get statInventory;

  /// No description provided for @statOnlineEmployees.
  ///
  /// In zh, this message translates to:
  /// **'在线员工'**
  String get statOnlineEmployees;

  /// No description provided for @statPendingTodos.
  ///
  /// In zh, this message translates to:
  /// **'待办事项'**
  String get statPendingTodos;

  /// No description provided for @statTrendUp.
  ///
  /// In zh, this message translates to:
  /// **'较昨日 +{percent}%'**
  String statTrendUp(Object percent);

  /// No description provided for @statTrendDown.
  ///
  /// In zh, this message translates to:
  /// **'较昨日 {percent}%'**
  String statTrendDown(Object percent);

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

  /// No description provided for @settingsThemeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settingsThemeSystem;

  /// No description provided for @settingsLanguage.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageZh.
  ///
  /// In zh, this message translates to:
  /// **'简体中文'**
  String get settingsLanguageZh;

  /// No description provided for @settingsLanguageEn.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get settingsLanguageEn;

  /// No description provided for @settingsFontSize.
  ///
  /// In zh, this message translates to:
  /// **'字号'**
  String get settingsFontSize;

  /// No description provided for @settingsFontSmall.
  ///
  /// In zh, this message translates to:
  /// **'小'**
  String get settingsFontSmall;

  /// No description provided for @settingsFontMedium.
  ///
  /// In zh, this message translates to:
  /// **'中'**
  String get settingsFontMedium;

  /// No description provided for @settingsFontLarge.
  ///
  /// In zh, this message translates to:
  /// **'大'**
  String get settingsFontLarge;

  /// No description provided for @settingsFontXLarge.
  ///
  /// In zh, this message translates to:
  /// **'超大'**
  String get settingsFontXLarge;

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

  /// No description provided for @settingsPerformanceAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get settingsPerformanceAuto;

  /// No description provided for @settingsPerformanceLite.
  ///
  /// In zh, this message translates to:
  /// **'省电'**
  String get settingsPerformanceLite;

  /// No description provided for @settingsPerformanceStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get settingsPerformanceStandard;

  /// No description provided for @settingsPerformanceRich.
  ///
  /// In zh, this message translates to:
  /// **'极致'**
  String get settingsPerformanceRich;

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

  /// No description provided for @profileTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get profileTitle;

  /// No description provided for @profileEditProfile.
  ///
  /// In zh, this message translates to:
  /// **'编辑资料'**
  String get profileEditProfile;

  /// No description provided for @profileChangePassword.
  ///
  /// In zh, this message translates to:
  /// **'修改密码'**
  String get profileChangePassword;

  /// No description provided for @profileEmployeeCode.
  ///
  /// In zh, this message translates to:
  /// **'工号'**
  String get profileEmployeeCode;

  /// No description provided for @profileDepartment.
  ///
  /// In zh, this message translates to:
  /// **'部门'**
  String get profileDepartment;

  /// No description provided for @profilePosition.
  ///
  /// In zh, this message translates to:
  /// **'岗位'**
  String get profilePosition;

  /// No description provided for @entrySubtitle.
  ///
  /// In zh, this message translates to:
  /// **'请选择登录方式'**
  String get entrySubtitle;

  /// No description provided for @entryStaff.
  ///
  /// In zh, this message translates to:
  /// **'内部人员登录'**
  String get entryStaff;

  /// No description provided for @entryVisitor.
  ///
  /// In zh, this message translates to:
  /// **'访客登录'**
  String get entryVisitor;

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

  /// No description provided for @visitorCodeSent.
  ///
  /// In zh, this message translates to:
  /// **'验证码已发送'**
  String get visitorCodeSent;

  /// No description provided for @visitorCodeSentDev.
  ///
  /// In zh, this message translates to:
  /// **'验证码：{code}（开发期）'**
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

  /// No description provided for @visitorApplyHostHint.
  ///
  /// In zh, this message translates to:
  /// **'选择要拜访的同事'**
  String get visitorApplyHostHint;

  /// No description provided for @visitorApplyDept.
  ///
  /// In zh, this message translates to:
  /// **'接待部门'**
  String get visitorApplyDept;

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

  /// No description provided for @visitorDetailVehicle.
  ///
  /// In zh, this message translates to:
  /// **'车辆'**
  String get visitorDetailVehicle;

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

  /// No description provided for @visitorApprovalProcessed.
  ///
  /// In zh, this message translates to:
  /// **'已处理'**
  String get visitorApprovalProcessed;

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

  /// No description provided for @visitorApprovalRejectReason.
  ///
  /// In zh, this message translates to:
  /// **'拒绝原因'**
  String get visitorApprovalRejectReason;

  /// No description provided for @visitorApprovalRejectReasonHint.
  ///
  /// In zh, this message translates to:
  /// **'请填写拒绝原因（选填）'**
  String get visitorApprovalRejectReasonHint;

  /// No description provided for @visitorApprovalConfirmApprove.
  ///
  /// In zh, this message translates to:
  /// **'确认批准该访客来访？'**
  String get visitorApprovalConfirmApprove;

  /// No description provided for @visitorApprovalConfirmReject.
  ///
  /// In zh, this message translates to:
  /// **'确认拒绝该访客来访？'**
  String get visitorApprovalConfirmReject;

  /// No description provided for @visitorApprovalHostConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'接待人已确认'**
  String get visitorApprovalHostConfirmed;

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

  /// No description provided for @myVisitorsConfirmHint.
  ///
  /// In zh, this message translates to:
  /// **'确认接待该访客？'**
  String get myVisitorsConfirmHint;

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

  /// No description provided for @securityManualInputHint.
  ///
  /// In zh, this message translates to:
  /// **'粘贴或输入二维码内容'**
  String get securityManualInputHint;

  /// No description provided for @securityPasscodeHint.
  ///
  /// In zh, this message translates to:
  /// **'输入6位通行码'**
  String get securityPasscodeHint;

  /// No description provided for @visitorPasscodeLabel.
  ///
  /// In zh, this message translates to:
  /// **'通行码'**
  String get visitorPasscodeLabel;

  /// No description provided for @securityVerifying.
  ///
  /// In zh, this message translates to:
  /// **'核验中…'**
  String get securityVerifying;

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
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
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
