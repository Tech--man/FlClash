import 'dart:async';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'clash/core.dart';
import 'models/models.dart';
import 'common/common.dart';

class AppController {
  final BuildContext context;
  late AppState appState;
  late Config config;
  late ClashConfig clashConfig;
  late Measure measure;
  late Function updateClashConfigDebounce;

  AppController(this.context) {
    appState = context.read<AppState>();
    config = context.read<Config>();
    clashConfig = context.read<ClashConfig>();
    updateClashConfigDebounce = debounce<Function()>(() async {
      await updateClashConfig();
    });
    measure = Measure.of(context);
  }

  Future<void> updateSystemProxy(bool isStart) async {
    if (isStart) {
      await globalState.startSystemProxy(
        config: config,
        clashConfig: clashConfig,
      );
      updateRunTime();
      updateTraffic();
      globalState.updateFunctionLists = [
        updateRunTime,
        updateTraffic,
      ];
    } else {
      await globalState.stopSystemProxy();
      appState.traffics = [];
      appState.runTime = null;
    }
  }

  updateCoreVersionInfo() {
    globalState.updateCoreVersionInfo(appState);
  }

  updateRunTime() {
    if (proxyManager.startTime != null) {
      final startTimeStamp = proxyManager.startTime!.millisecondsSinceEpoch;
      final nowTimeStamp = DateTime.now().millisecondsSinceEpoch;
      appState.runTime = nowTimeStamp - startTimeStamp;
    } else {
      appState.runTime = null;
    }
  }

  updateTraffic() {
    globalState.updateTraffic(
      config: config,
      appState: appState,
    );
  }

  changeProxy() {
    globalState.changeProxy(
      appState: appState,
      config: config,
      clashConfig: clashConfig,
    );
  }

  addProfile(Profile profile) async {
    config.setProfile(profile);
    if (config.currentProfileId != null) return;
    await changeProfile(profile.id);
  }

  deleteProfile(String id) async {
    config.deleteProfileById(id);
    final profilePath = await appPath.getProfilePath(id);
    if (profilePath == null) return;
    clashCore.clearEffect(profilePath);
    if (config.currentProfileId == id) {
      if (config.profiles.isNotEmpty) {
        final updateId = config.profiles.first.id;
        changeProfile(updateId);
      } else {
        changeProfile(null);
      }
    }
  }

  Future<void> updateProfile(String id) async {
    final profile = config.getCurrentProfileForId(id);
    if (profile != null) {
      final tempProfile = profile.copyWith();
      await tempProfile.update();
      config.setProfile(tempProfile);
    }
  }

  Future<void> updateClashConfig({bool isPatch = true}) async {
    await globalState.updateClashConfig(
      clashConfig: clashConfig,
      config: config,
      isPatch: isPatch,
    );
  }

  Future applyProfile() async {
    final commonScaffoldState = globalState.homeScaffoldKey.currentState;
    if (commonScaffoldState?.mounted != true) return;
    commonScaffoldState?.loadingRun(() async {
      await globalState.applyProfile(
        appState: appState,
        config: config,
        clashConfig: clashConfig,
      );
    });
  }

  changeProfile(String? value) async {
    if (value == config.currentProfileId) return;
    config.currentProfileId = value;
    await applyProfile();
    appState.delayMap = {};
    saveConfigPreferences();
  }

  autoUpdateProfiles() async {
    for (final profile in config.profiles) {
      if (!profile.autoUpdate) continue;
      final isNotNeedUpdate = profile.lastUpdateDate
          ?.add(
            profile.autoUpdateDuration,
          )
          .isBeforeNow;
      if (isNotNeedUpdate == false || profile.type == ProfileType.file) {
        continue;
      }
      try {
        await updateProfile(profile.id);
      } catch (e) {
        appState.addLog(
          Log(
            logLevel: LogLevel.info,
            payload: e.toString(),
          ),
        );
      }
    }
  }

  updateProfiles() async {
    for (final profile in config.profiles) {
      if (profile.type == ProfileType.file) {
        continue;
      }
      await updateProfile(profile.id);
    }
  }

  Future<void> updateGroups() async {
    await globalState.updateGroups(appState);
  }

  updateSystemColorSchemes(SystemColorSchemes systemColorSchemes) {
    appState.systemColorSchemes = systemColorSchemes;
  }

  savePreferences() async {
    await saveConfigPreferences();
    await saveClashConfigPreferences();
  }

  saveConfigPreferences() async {
    debugPrint("saveConfigPreferences");
    await preferences.saveConfig(config);
  }

  saveClashConfigPreferences() async {
    debugPrint("saveClashConfigPreferences");
    await preferences.saveClashConfig(clashConfig);
  }

  handleBackOrExit() async {
    if (config.isMinimizeOnExit) {
      if (system.isDesktop) {
        await savePreferences();
      }
      await system.back();
    } else {
      await handleExit();
    }
  }

  handleExit() async {
    await updateSystemProxy(false);
    await savePreferences();
    clashCore.shutdown();
    system.exit();
  }

  updateLogStatus() {
    if (config.openLogs) {
      clashCore.startLog();
    } else {
      clashCore.stopLog();
      appState.logs = [];
    }
  }

  autoCheckUpdate() async {
    if (!config.autoCheckUpdate) return;
    final res = await request.checkForUpdate();
    checkUpdateResultHandle(data: res);
  }

  checkUpdateResultHandle({
    Map<String, dynamic>? data,
    bool handleError = false,
  }) async {
    if (data != null) {
      final tagName = data['tag_name'];
      final body = data['body'];
      final submits = other.parseReleaseBody(body);
      final textTheme = context.textTheme;
      globalState.showMessage(
        title: appLocalizations.discoverNewVersion,
        message: TextSpan(
          text: "$tagName \n",
          style: textTheme.headlineSmall,
          children: [
            TextSpan(
              text: "\n",
              style: textTheme.bodyMedium,
            ),
            for (final submit in submits)
              TextSpan(
                text: "- $submit \n",
                style: textTheme.bodyMedium,
              ),
          ],
        ),
        onTab: () {
          launchUrl(
            Uri.parse("https://github.com/$repository/releases/latest"),
          );
        },
        confirmText: appLocalizations.goDownload,
      );
    } else if (handleError) {
      globalState.showMessage(
        title: appLocalizations.checkUpdate,
        message: TextSpan(
          text: appLocalizations.checkUpdateError,
        ),
      );
    }
  }

  init() async {
    if (!config.silentLaunch) {
      window?.show();
    }
    final commonScaffoldState = globalState.homeScaffoldKey.currentState;
    if (commonScaffoldState?.mounted == true) {
      await commonScaffoldState?.loadingRun(() async {
        await globalState.applyProfile(
          appState: appState,
          config: config,
          clashConfig: clashConfig,
        );
      },title: appLocalizations.init);
    } else {
      await globalState.applyProfile(
        appState: appState,
        config: config,
        clashConfig: clashConfig,
      );
    }
    await afterInit();
  }

  afterInit() async {
    if (config.autoRun) {
      await updateSystemProxy(true);
    } else {
      await proxyManager.updateStartTime();
      await updateSystemProxy(proxyManager.isStart);
    }
    autoUpdateProfiles();
    updateLogStatus();
    autoCheckUpdate();
  }

  setDelay(Delay delay) {
    appState.setDelay(delay);
  }

  toPage(int index, {bool hasAnimate = false}) {
    if (index > appState.currentNavigationItems.length - 1) {
      return;
    }
    appState.currentLabel = appState.currentNavigationItems[index].label;
    if ((config.isAnimateToPage || hasAnimate)) {
      globalState.pageController?.animateToPage(
        index,
        duration: kTabScrollDuration,
        curve: Curves.easeOut,
      );
    } else {
      globalState.pageController?.jumpToPage(index);
    }
  }

  toProfiles() {
    final index = appState.currentNavigationItems.indexWhere(
      (element) => element.label == "profiles",
    );
    if (index != -1) {
      toPage(index);
    }
  }

  initLink() {
    linkManager.initAppLinksListen(
      (url) {
        globalState.showMessage(
          title: "${appLocalizations.add}${appLocalizations.profile}",
          message: TextSpan(
            children: [
              TextSpan(text: appLocalizations.doYouWantToPass),
              TextSpan(
                text: " $url ",
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: Theme.of(context).colorScheme.primary,
                ),
              ),
              TextSpan(
                  text:
                      "${appLocalizations.create}${appLocalizations.profile}"),
            ],
          ),
          onTab: () {
            addProfileFormURL(url);
          },
        );
      },
    );
  }

  addProfileFormURL(String url) async {
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    toProfiles();
    final commonScaffoldState = globalState.homeScaffoldKey.currentState;
    if (commonScaffoldState?.mounted != true) return;
    final profile = await commonScaffoldState?.loadingRun<Profile>(
      () async {
        final profile = Profile(
          url: url,
        );
        await profile.update();
        return profile;
      },
      title: "${appLocalizations.add}${appLocalizations.profile}",
    );
    if (profile != null) {
      await addProfile(profile);
    }
  }

  addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerConfigFile);
    if (!context.mounted) return;
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    toProfiles();
    final commonScaffoldState = globalState.homeScaffoldKey.currentState;
    if (commonScaffoldState?.mounted != true) return;
    final profile = await commonScaffoldState?.loadingRun<Profile?>(
      () async {
        await Future.delayed(const Duration(milliseconds: 300));
        final bytes = platformFile?.bytes;
        if (bytes == null) {
          return null;
        }
        final profile = Profile(label: platformFile?.name);
        await profile.saveFile(bytes);
        return profile;
      },
      title: "${appLocalizations.add}${appLocalizations.profile}",
    );
    if (profile != null) {
      await addProfile(profile);
    }
  }

  addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    addProfileFormURL(url);
  }

  updateViewWidth(double width) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      appState.viewWidth = width;
    });
  }
}
