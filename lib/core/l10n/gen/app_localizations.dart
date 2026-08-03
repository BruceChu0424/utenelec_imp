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
  AppLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = _AppLocalizationsDelegate();

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
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh'),
    Locale('en')
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

  /// No description provided for @navHrGroup.
  ///
  /// In zh, this message translates to:
  /// **'人事管理'**
  String get navHrGroup;

  /// No description provided for @navHrEmployees.
  ///
  /// In zh, this message translates to:
  /// **'员工档案'**
  String get navHrEmployees;

  /// No description provided for @navHrDepartments.
  ///
  /// In zh, this message translates to:
  /// **'部门管理'**
  String get navHrDepartments;

  /// No description provided for @navHrOnboarding.
  ///
  /// In zh, this message translates to:
  /// **'入职办理'**
  String get navHrOnboarding;

  /// No description provided for @navHrPayrollGenerate.
  ///
  /// In zh, this message translates to:
  /// **'工资条生成'**
  String get navHrPayrollGenerate;

  /// No description provided for @navHrNoticePublish.
  ///
  /// In zh, this message translates to:
  /// **'通知发布'**
  String get navHrNoticePublish;

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
  /// **'搜索工号 / 姓名'**
  String get employeeSearchHint;

  /// No description provided for @employeeEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无员工'**
  String get employeeEmpty;

  /// No description provided for @employeeEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'点右下角「入职」添加新员工'**
  String get employeeEmptyHint;

  /// No description provided for @employeeLoadMore.
  ///
  /// In zh, this message translates to:
  /// **'加载更多'**
  String get employeeLoadMore;

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

  /// No description provided for @employeeDetailContact.
  ///
  /// In zh, this message translates to:
  /// **'联系与地址'**
  String get employeeDetailContact;

  /// No description provided for @employeeDetailOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织与用工'**
  String get employeeDetailOrg;

  /// No description provided for @employeeDetailContract.
  ///
  /// In zh, this message translates to:
  /// **'合同 / 薪资（按权限可见）'**
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
  /// **'{months} 个月（至 {end}）'**
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
  /// **'试用期将于 {date} 到期（剩 {days} 天），请及时办理转正'**
  String employeeProbationExpiring(Object date, Object days);

  /// No description provided for @employeeProbationExpired.
  ///
  /// In zh, this message translates to:
  /// **'试用期已于 {date} 到期，请尽快办理转正或离职'**
  String employeeProbationExpired(Object date);

  /// No description provided for @employeeContractExpiring.
  ///
  /// In zh, this message translates to:
  /// **'劳动合同将于 {date} 到期（剩 {days} 天），请及时续签'**
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

  /// No description provided for @employeeEditFieldPhone.
  ///
  /// In zh, this message translates to:
  /// **'手机'**
  String get employeeEditFieldPhone;

  /// No description provided for @employeeEditFieldDepartment.
  ///
  /// In zh, this message translates to:
  /// **'部门'**
  String get employeeEditFieldDepartment;

  /// No description provided for @employeeEditFieldPosition.
  ///
  /// In zh, this message translates to:
  /// **'岗位'**
  String get employeeEditFieldPosition;

  /// No description provided for @employeeEditFieldEmploymentType.
  ///
  /// In zh, this message translates to:
  /// **'用工性质'**
  String get employeeEditFieldEmploymentType;

  /// No description provided for @employeeEditFieldStatus.
  ///
  /// In zh, this message translates to:
  /// **'员工状态'**
  String get employeeEditFieldStatus;

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

  /// No description provided for @employeeEditNotFound.
  ///
  /// In zh, this message translates to:
  /// **'员工不存在'**
  String get employeeEditNotFound;

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
  /// **'薪资 / 银行（可选，仅 HR/管理员可见）'**
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
  /// **'提交后将自动生成工号（UT 前缀）、以手机号作为登录账号，并生成一次性临时密码（身份证后 6 位）；首次登录必须修改密码。'**
  String get employeeOnboardNote;

  /// No description provided for @employeeOnboardCodeAutoNote.
  ///
  /// In zh, this message translates to:
  /// **'工号提交后自动生成（UT 前缀，唯一递增）'**
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

  /// No description provided for @employeeOffboardTitle.
  ///
  /// In zh, this message translates to:
  /// **'离职办理'**
  String get employeeOffboardTitle;

  /// No description provided for @employeeOffboardStepStart.
  ///
  /// In zh, this message translates to:
  /// **'发起离职'**
  String get employeeOffboardStepStart;

  /// No description provided for @employeeOffboardStepHandover.
  ///
  /// In zh, this message translates to:
  /// **'工作交接'**
  String get employeeOffboardStepHandover;

  /// No description provided for @employeeOffboardStepCheck.
  ///
  /// In zh, this message translates to:
  /// **'回收确认'**
  String get employeeOffboardStepCheck;

  /// No description provided for @employeeOffboardFieldType.
  ///
  /// In zh, this message translates to:
  /// **'离职类型'**
  String get employeeOffboardFieldType;

  /// No description provided for @employeeOffboardFieldDate.
  ///
  /// In zh, this message translates to:
  /// **'离职日期'**
  String get employeeOffboardFieldDate;

  /// No description provided for @employeeOffboardPickDate.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get employeeOffboardPickDate;

  /// No description provided for @employeeOffboardFieldReason.
  ///
  /// In zh, this message translates to:
  /// **'离职原因'**
  String get employeeOffboardFieldReason;

  /// No description provided for @employeeOffboardFieldHandover.
  ///
  /// In zh, this message translates to:
  /// **'交接说明（文档/项目/权限）'**
  String get employeeOffboardFieldHandover;

  /// No description provided for @employeeOffboardPickDateRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择离职日期'**
  String get employeeOffboardPickDateRequired;

  /// No description provided for @employeeOffboardChecksRequired.
  ///
  /// In zh, this message translates to:
  /// **'请确认所有回收项'**
  String get employeeOffboardChecksRequired;

  /// No description provided for @employeeOffboardConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认办理离职？'**
  String get employeeOffboardConfirmTitle;

  /// No description provided for @employeeOffboardConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'该员工账号将被停用。'**
  String get employeeOffboardConfirmBody;

  /// No description provided for @employeeOffboardConfirmAction.
  ///
  /// In zh, this message translates to:
  /// **'确认办理离职'**
  String get employeeOffboardConfirmAction;

  /// No description provided for @employeeOffboardNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get employeeOffboardNext;

  /// No description provided for @employeeOffboardBack.
  ///
  /// In zh, this message translates to:
  /// **'上一步'**
  String get employeeOffboardBack;

  /// No description provided for @employeeOffboardCompleted.
  ///
  /// In zh, this message translates to:
  /// **'离职办理完成'**
  String get employeeOffboardCompleted;

  /// No description provided for @employeeOffboardLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get employeeOffboardLoadFailed;

  /// No description provided for @employeeActions.
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get employeeActions;

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

  /// No description provided for @employeeActionDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除档案'**
  String get employeeActionDelete;

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

  /// No description provided for @employeeTransferPickDate.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get employeeTransferPickDate;

  /// No description provided for @employeeTransferFieldRemark.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get employeeTransferFieldRemark;

  /// No description provided for @employeeTransferDateRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择生效日期'**
  String get employeeTransferDateRequired;

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
  /// **'转正后员工状态将变为「在职」。'**
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
  /// **'复职后员工状态将恢复为「在职」，其登录账号将重新启用（需重新登录）。'**
  String get employeeRehireBody;

  /// No description provided for @employeeRehireSuccess.
  ///
  /// In zh, this message translates to:
  /// **'复职完成'**
  String get employeeRehireSuccess;

  /// No description provided for @employeeDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认删除该员工档案？'**
  String get employeeDeleteTitle;

  /// No description provided for @employeeDeleteBody.
  ///
  /// In zh, this message translates to:
  /// **'删除后其登录账号将被停用，此操作不可恢复。'**
  String get employeeDeleteBody;

  /// No description provided for @employeeDeleteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'员工档案已删除'**
  String get employeeDeleteSuccess;

  /// No description provided for @resignTypeVoluntary.
  ///
  /// In zh, this message translates to:
  /// **'主动辞职'**
  String get resignTypeVoluntary;

  /// No description provided for @resignTypeDismissed.
  ///
  /// In zh, this message translates to:
  /// **'公司辞退'**
  String get resignTypeDismissed;

  /// No description provided for @resignTypeContractEnd.
  ///
  /// In zh, this message translates to:
  /// **'合同到期'**
  String get resignTypeContractEnd;

  /// No description provided for @resignTypeRetire.
  ///
  /// In zh, this message translates to:
  /// **'退休'**
  String get resignTypeRetire;

  /// No description provided for @resignCheckAccess.
  ///
  /// In zh, this message translates to:
  /// **'收回门禁卡'**
  String get resignCheckAccess;

  /// No description provided for @resignCheckAssets.
  ///
  /// In zh, this message translates to:
  /// **'回收公司资产'**
  String get resignCheckAssets;

  /// No description provided for @resignCheckAccount.
  ///
  /// In zh, this message translates to:
  /// **'停用系统账号'**
  String get resignCheckAccount;

  /// No description provided for @resignCheckSocial.
  ///
  /// In zh, this message translates to:
  /// **'停缴社保公积金'**
  String get resignCheckSocial;

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

  /// No description provided for @departmentTreeTitle.
  ///
  /// In zh, this message translates to:
  /// **'组织架构'**
  String get departmentTreeTitle;

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

  /// No description provided for @departmentTooltipAdd.
  ///
  /// In zh, this message translates to:
  /// **'新增部门'**
  String get departmentTooltipAdd;

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

  /// No description provided for @departmentDialogAddTitle.
  ///
  /// In zh, this message translates to:
  /// **'新增部门'**
  String get departmentDialogAddTitle;

  /// No description provided for @departmentDialogDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除部门'**
  String get departmentDialogDeleteTitle;

  /// No description provided for @departmentFieldCode.
  ///
  /// In zh, this message translates to:
  /// **'部门编码'**
  String get departmentFieldCode;

  /// No description provided for @departmentFieldCodeHint.
  ///
  /// In zh, this message translates to:
  /// **'如 DEPT-XX'**
  String get departmentFieldCodeHint;

  /// No description provided for @departmentFieldName.
  ///
  /// In zh, this message translates to:
  /// **'部门名称'**
  String get departmentFieldName;

  /// No description provided for @departmentFieldLevel.
  ///
  /// In zh, this message translates to:
  /// **'层级'**
  String get departmentFieldLevel;

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

  /// No description provided for @departmentRequireCodeAndName.
  ///
  /// In zh, this message translates to:
  /// **'编码与名称必填'**
  String get departmentRequireCodeAndName;

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

  /// No description provided for @departmentStatEmployees.
  ///
  /// In zh, this message translates to:
  /// **'员工'**
  String get departmentStatEmployees;

  /// No description provided for @departmentStatChildren.
  ///
  /// In zh, this message translates to:
  /// **'子部门'**
  String get departmentStatChildren;

  /// No description provided for @departmentStatManager.
  ///
  /// In zh, this message translates to:
  /// **'负责人'**
  String get departmentStatManager;

  /// No description provided for @departmentStatParent.
  ///
  /// In zh, this message translates to:
  /// **'上级'**
  String get departmentStatParent;

  /// No description provided for @departmentEmployeesHeader.
  ///
  /// In zh, this message translates to:
  /// **'员工（{count}）'**
  String departmentEmployeesHeader(Object count);

  /// No description provided for @departmentEmployeesEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该部门（含子部门）暂无员工'**
  String get departmentEmployeesEmpty;

  /// No description provided for @departmentStatValue.
  ///
  /// In zh, this message translates to:
  /// **'{label}：{value}'**
  String departmentStatValue(Object label, Object value);

  /// No description provided for @departmentLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get departmentLoadFailed;

  /// No description provided for @departmentLevelCompany.
  ///
  /// In zh, this message translates to:
  /// **'公司'**
  String get departmentLevelCompany;

  /// No description provided for @departmentLevelDecision.
  ///
  /// In zh, this message translates to:
  /// **'决策层'**
  String get departmentLevelDecision;

  /// No description provided for @departmentLevelManagement.
  ///
  /// In zh, this message translates to:
  /// **'管理中心'**
  String get departmentLevelManagement;

  /// No description provided for @departmentLevelPrimary.
  ///
  /// In zh, this message translates to:
  /// **'一级部门'**
  String get departmentLevelPrimary;

  /// No description provided for @departmentLevelSecondary.
  ///
  /// In zh, this message translates to:
  /// **'二级班组'**
  String get departmentLevelSecondary;

  /// No description provided for @departmentLevelTertiary.
  ///
  /// In zh, this message translates to:
  /// **'三级科室'**
  String get departmentLevelTertiary;

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

  /// No description provided for @payrollSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'已提交审核，等待财务审核'**
  String get payrollSubmitted;

  /// No description provided for @payrollLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败：{error}'**
  String payrollLoadFailed(Object error);

  /// No description provided for @payrollEmptyPreview.
  ///
  /// In zh, this message translates to:
  /// **'该范围无可计算员工'**
  String get payrollEmptyPreview;

  /// No description provided for @payrollTableTotalLabel.
  ///
  /// In zh, this message translates to:
  /// **'合计'**
  String get payrollTableTotalLabel;

  /// No description provided for @payrollTableTotalValue.
  ///
  /// In zh, this message translates to:
  /// **'¥ {total} · {count} 人'**
  String payrollTableTotalValue(Object total, Object count);

  /// No description provided for @payrollTableHeaderName.
  ///
  /// In zh, this message translates to:
  /// **'工号/姓名'**
  String get payrollTableHeaderName;

  /// No description provided for @payrollTableHeaderNet.
  ///
  /// In zh, this message translates to:
  /// **'实发'**
  String get payrollTableHeaderNet;

  /// No description provided for @payrollTableRowName.
  ///
  /// In zh, this message translates to:
  /// **'{name}（{code}）'**
  String payrollTableRowName(Object name, Object code);

  /// No description provided for @payrollTableRowNet.
  ///
  /// In zh, this message translates to:
  /// **'¥ {net}'**
  String payrollTableRowNet(Object net);

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

  /// No description provided for @payrollDeptProduction.
  ///
  /// In zh, this message translates to:
  /// **'生产部'**
  String get payrollDeptProduction;

  /// No description provided for @payrollDeptQuality.
  ///
  /// In zh, this message translates to:
  /// **'质量部'**
  String get payrollDeptQuality;

  /// No description provided for @payrollDeptHr.
  ///
  /// In zh, this message translates to:
  /// **'人事部'**
  String get payrollDeptHr;

  /// No description provided for @payrollDeptFinance.
  ///
  /// In zh, this message translates to:
  /// **'财务部'**
  String get payrollDeptFinance;

  /// No description provided for @noticePublishTitle.
  ///
  /// In zh, this message translates to:
  /// **'发布通知'**
  String get noticePublishTitle;

  /// No description provided for @noticePublishSaveDraft.
  ///
  /// In zh, this message translates to:
  /// **'存草稿'**
  String get noticePublishSaveDraft;

  /// No description provided for @noticePublishDraftSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存草稿'**
  String get noticePublishDraftSaved;

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
  /// **'通知标题（必填）'**
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

  /// No description provided for @noticePublishScopeDept.
  ///
  /// In zh, this message translates to:
  /// **'按部门'**
  String get noticePublishScopeDept;

  /// No description provided for @noticePublishFieldDept.
  ///
  /// In zh, this message translates to:
  /// **'部门'**
  String get noticePublishFieldDept;

  /// No description provided for @noticePublishScopeAllHint.
  ///
  /// In zh, this message translates to:
  /// **'将通知到全公司所有员工'**
  String get noticePublishScopeAllHint;

  /// No description provided for @noticePublishScopeDeptHint.
  ///
  /// In zh, this message translates to:
  /// **'将通知到「{dept}」全体员工'**
  String noticePublishScopeDeptHint(Object dept);

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

  /// No description provided for @noticePublishConfirmBodyDept.
  ///
  /// In zh, this message translates to:
  /// **'将通知到「{dept}」'**
  String noticePublishConfirmBodyDept(Object dept);

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
  /// **'接收部门（可多选）'**
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
  /// **'选择指定人员（可多选）'**
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
  String noticePublishAudienceSummary(Object departmentCount, Object employeeCount);

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

  /// No description provided for @profileChangeEditHrOnlyHint.
  ///
  /// In zh, this message translates to:
  /// **'以下字段请联系人事修改'**
  String get profileChangeEditHrOnlyHint;

  /// No description provided for @profileChangeSectionBasic.
  ///
  /// In zh, this message translates to:
  /// **'基本信息（直改生效）'**
  String get profileChangeSectionBasic;

  /// No description provided for @profileChangeSectionReview.
  ///
  /// In zh, this message translates to:
  /// **'联系方式与重要字段（需 HR 审核）'**
  String get profileChangeSectionReview;

  /// No description provided for @profileChangeSectionIdentity.
  ///
  /// In zh, this message translates to:
  /// **'姓名与紧急联系人（需 HR 审核）'**
  String get profileChangeSectionIdentity;

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

  /// No description provided for @profileChangeListCta.
  ///
  /// In zh, this message translates to:
  /// **'查看申请记录'**
  String get profileChangeListCta;

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

  /// No description provided for @profileChangeFilterApproved.
  ///
  /// In zh, this message translates to:
  /// **'已通过'**
  String get profileChangeFilterApproved;

  /// No description provided for @profileChangeFilterRejected.
  ///
  /// In zh, this message translates to:
  /// **'已驳回'**
  String get profileChangeFilterRejected;

  /// No description provided for @profileChangeFilterCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已撤销'**
  String get profileChangeFilterCancelled;

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

  /// No description provided for @profileChangeFieldLabel.
  ///
  /// In zh, this message translates to:
  /// **'字段'**
  String get profileChangeFieldLabel;

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

  /// No description provided for @profileChangeFieldHujiAddress.
  ///
  /// In zh, this message translates to:
  /// **'户籍地址'**
  String get profileChangeFieldHujiAddress;

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

  /// No description provided for @profilePendingSectionEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该员工暂无待审申请'**
  String get profilePendingSectionEmpty;

  /// No description provided for @profilePendingSectionViewAll.
  ///
  /// In zh, this message translates to:
  /// **'全部 →'**
  String get profilePendingSectionViewAll;

  /// No description provided for @profileFieldPhoneMask.
  ///
  /// In zh, this message translates to:
  /// **'138****1234'**
  String get profileFieldPhoneMask;

  /// No description provided for @profileFieldIdCardMask.
  ///
  /// In zh, this message translates to:
  /// **'****'**
  String get profileFieldIdCardMask;

  /// No description provided for @profileFieldBankAccountMask.
  ///
  /// In zh, this message translates to:
  /// **'****1234'**
  String get profileFieldBankAccountMask;

  /// No description provided for @profileFieldGroupIdentity.
  ///
  /// In zh, this message translates to:
  /// **'身份信息'**
  String get profileFieldGroupIdentity;

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

  /// No description provided for @profileFieldGroupOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织与入职'**
  String get profileFieldGroupOrg;

  /// No description provided for @profileFieldGroupCompensation.
  ///
  /// In zh, this message translates to:
  /// **'薪资与银行'**
  String get profileFieldGroupCompensation;

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

  /// No description provided for @profileFieldMobile.
  ///
  /// In zh, this message translates to:
  /// **'手机号'**
  String get profileFieldMobile;

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

  /// No description provided for @profileFieldIdType.
  ///
  /// In zh, this message translates to:
  /// **'证件类型'**
  String get profileFieldIdType;

  /// No description provided for @profileFieldIdNumber.
  ///
  /// In zh, this message translates to:
  /// **'身份证号'**
  String get profileFieldIdNumber;

  /// No description provided for @profileFieldSupervisor.
  ///
  /// In zh, this message translates to:
  /// **'直属主管'**
  String get profileFieldSupervisor;

  /// No description provided for @profileFieldHireDate.
  ///
  /// In zh, this message translates to:
  /// **'入职日期'**
  String get profileFieldHireDate;

  /// No description provided for @profileFieldConfirmedAt.
  ///
  /// In zh, this message translates to:
  /// **'转正日期'**
  String get profileFieldConfirmedAt;

  /// No description provided for @profileFieldEmploymentType.
  ///
  /// In zh, this message translates to:
  /// **'用工性质'**
  String get profileFieldEmploymentType;

  /// No description provided for @profileFieldAttendanceGroup.
  ///
  /// In zh, this message translates to:
  /// **'考勤组'**
  String get profileFieldAttendanceGroup;

  /// No description provided for @profileFieldPaperArchiveNo.
  ///
  /// In zh, this message translates to:
  /// **'纸质档案号'**
  String get profileFieldPaperArchiveNo;

  /// No description provided for @profileFieldBaseSalary.
  ///
  /// In zh, this message translates to:
  /// **'基本工资'**
  String get profileFieldBaseSalary;

  /// No description provided for @profileFieldPerfSalary.
  ///
  /// In zh, this message translates to:
  /// **'绩效工资'**
  String get profileFieldPerfSalary;

  /// No description provided for @profileFieldSocialInsuranceBase.
  ///
  /// In zh, this message translates to:
  /// **'社保基数'**
  String get profileFieldSocialInsuranceBase;

  /// No description provided for @profileFieldSocialInsuranceLocation.
  ///
  /// In zh, this message translates to:
  /// **'社保缴纳地'**
  String get profileFieldSocialInsuranceLocation;

  /// No description provided for @profileFieldHousingFundBase.
  ///
  /// In zh, this message translates to:
  /// **'公积金基数'**
  String get profileFieldHousingFundBase;

  /// No description provided for @profileFieldAllowanceStandard.
  ///
  /// In zh, this message translates to:
  /// **'补贴标准'**
  String get profileFieldAllowanceStandard;

  /// No description provided for @profileFieldBankBranch.
  ///
  /// In zh, this message translates to:
  /// **'开户行'**
  String get profileFieldBankBranch;

  /// No description provided for @profileFieldBankAccount.
  ///
  /// In zh, this message translates to:
  /// **'银行账号'**
  String get profileFieldBankAccount;

  /// No description provided for @profileFieldContractType.
  ///
  /// In zh, this message translates to:
  /// **'合同类型'**
  String get profileFieldContractType;

  /// No description provided for @profileFieldContractStart.
  ///
  /// In zh, this message translates to:
  /// **'合同起始'**
  String get profileFieldContractStart;

  /// No description provided for @profileFieldContractEnd.
  ///
  /// In zh, this message translates to:
  /// **'合同截止'**
  String get profileFieldContractEnd;

  /// No description provided for @profileFieldProbationMonths.
  ///
  /// In zh, this message translates to:
  /// **'试用期（月）'**
  String get profileFieldProbationMonths;

  /// No description provided for @profileFieldRenewCount.
  ///
  /// In zh, this message translates to:
  /// **'续签次数'**
  String get profileFieldRenewCount;
}

class _AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en': return AppLocalizationsEn();
    case 'zh': return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
