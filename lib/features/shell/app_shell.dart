import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/nai_credential_login.dart';
import '../../core/auth/token_store.dart';
import '../../core/net/backend_config.dart';
import '../../core/store/app_stores.dart';
import '../../core/store/prefs_store.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_settings.dart';
import '../assistant/assistant_page.dart';
import '../assistant/assistant_state.dart';
import '../gallery/gallery_page.dart';
import '../generate/generate_page.dart';
import '../generate/generation_controller.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../inspiration/inspiration_page.dart';
import '../profile/profile_page.dart';
import '../update/update_service.dart';
import '../update/update_sheet.dart' show showUpdateSheet;
import 'shell_state.dart';

/// 全局骨架:5 tab 导航(AI 那格可藏)+ PageView 切页。
///
/// **横滑翻 tab 已关掉**(physics 恒为 NeverScrollable),切页只认导航点按与
/// 程序跳转(生成完跳图库、缺 token 跳我的)。PageView 留着只为那段横向推移动画。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final PageController _pc = PageController(
    initialPage: ref.read(shellIndexProvider),
  );

  static const _pages = [
    GeneratePage(),
    GalleryPage(),
    AssistantPage(),
    InspirationPage(),
    ProfilePage(),
  ];

  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    ref.read(tokenProvider);
    ref.read(botSessionProvider);
    ref.read(backendBaseProvider);
    ref.read(naiTokenAutoRefreshProvider);
    _scheduleAutoCheck();
  }

  /// 冷启动静默查一次更新(24h 节流)。定制包没有同签名更新源时完全关闭。
  void _scheduleAutoCheck() {
    if (!isUpdateCheckSupported || kUpdateGithubRepo.isEmpty) return;
    final prefs = ref.read(prefsStoreProvider);
    if (!shouldAutoCheck(prefs)) return;
    _updateTimer = Timer(
      const Duration(seconds: 3),
      () => _autoCheckUpdate(prefs),
    );
  }

  /// **只在真有新版时弹**,查不到/网络不通一律无声吞掉。
  Future<void> _autoCheckUpdate(PrefsStore prefs) async {
    if (!mounted) return;
    try {
      final installed = await installedInfo();
      if (!installed.isKnown) return;
      final release = await fetchLatestRelease(installed.versionName);
      await markUpdateChecked(prefs);
      if (release == null || !mounted) return;
      await showUpdateSheet(
        context,
        UpdateCheck(installed: installed, release: release),
      );
    } catch (_) {
      // 后台检查失败不打扰用户。
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _pc.dispose();
    super.dispose();
  }

  void _onEnterCreate() => ref.read(assistantProvider.notifier).markSeen();

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(shellIndexProvider);
    final showAi = ref.watch(
      themeSettingsProvider.select((t) => t.showAssistant),
    );
    final tabs = [
      kTabCreate,
      kTabGallery,
      if (showAi) kTabAssistant,
      kTabInspiration,
      kTabProfile,
    ];
    if (!showAi && index == kTabAssistant) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(shellIndexProvider.notifier).select(kTabCreate);
      });
    }

    ref.listen<int>(shellIndexProvider, (prev, next) {
      if (!_pc.hasClients) return;
      final current = _pc.page ?? _pc.initialPage.toDouble();
      if (current != next.toDouble()) {
        FocusManager.instance.primaryFocus?.unfocus();
        _pc.animateToPage(
          next,
          duration: Motion.medium,
          curve: Motion.emphasized,
        );
      }
    });

    ref.listen<GenStatus>(genStatusProvider, (prev, next) {
      final err = next.error;
      if (err == null) return;
      if (next.noToken) {
        hintSnack(
          context,
          '请先在「我的」页设置 NovelAI API Token',
          icon: Icons.key_off_outlined,
          actionLabel: '去设置',
          onAction: () =>
              ref.read(shellIndexProvider.notifier).select(kTabProfile),
        );
      } else {
        hintSnack(context, err, icon: Icons.error_outline);
      }
      ref.read(generationProvider.notifier).clearError();
    });

    ref.listen<String?>(genNoticeProvider, (prev, next) {
      if (next == null || next.isEmpty) return;
      hintSnack(context, next, icon: Icons.info_outline);
      ref.read(genNoticeProvider.notifier).clear();
    });

    final selectedTab = tabs.indexOf(index).clamp(0, tabs.length - 1);
    final createRailIcon = Badge(
      isLabelVisible: ref.watch(
        assistantProvider.select((s) => s.changedUnseen),
      ),
      smallSize: 8,
      child: const Icon(Icons.draw_outlined),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final useRail = constraints.maxWidth >= 900;
        final pages = SafeArea(
          bottom: useRail,
          child: PageView(
            controller: _pc,
            physics: const NeverScrollableScrollPhysics(),
            // 页面只跟随索引,不能在动画经过中写回中间 tab。
            children: _pages,
          ),
        );

        return Scaffold(
          // 页面始终保留在同一 element 位置。窗口跨过断点时不能重建 PageView,
          // 否则导航会保留旧索引而页面回到创作页。
          body: Row(
            children: [
              if (useRail)
                SafeArea(
                  child: NavigationRail(
                    selectedIndex: selectedTab,
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -0.82,
                    onDestinationSelected: (i) {
                      final tab = tabs[i];
                      ref.read(shellIndexProvider.notifier).select(tab);
                      if (tab == kTabCreate) _onEnterCreate();
                    },
                    destinations: [
                      NavigationRailDestination(
                        icon: createRailIcon,
                        selectedIcon: const Icon(Icons.draw),
                        label: const Text('创作'),
                      ),
                      const NavigationRailDestination(
                        icon: Icon(Icons.photo_library_outlined),
                        selectedIcon: Icon(Icons.photo_library),
                        label: Text('图库'),
                      ),
                      if (showAi)
                        const NavigationRailDestination(
                          icon: Icon(Icons.auto_awesome_outlined),
                          selectedIcon: Icon(Icons.auto_awesome),
                          label: Text('AI'),
                        ),
                      const NavigationRailDestination(
                        icon: Icon(Icons.lightbulb_outline),
                        selectedIcon: Icon(Icons.lightbulb),
                        label: Text('灵感'),
                      ),
                      const NavigationRailDestination(
                        icon: Icon(Icons.person_outline),
                        selectedIcon: Icon(Icons.person),
                        label: Text('我的'),
                      ),
                    ],
                  ),
                ),
              if (useRail) const VerticalDivider(width: 1),
              Expanded(key: const ValueKey('shell-pages'), child: pages),
            ],
          ),
          bottomNavigationBar: useRail
              ? null
              : NavigationBar(
                  selectedIndex: selectedTab,
                  onDestinationSelected: (i) {
                    final tab = tabs[i];
                    ref.read(shellIndexProvider.notifier).select(tab);
                    if (tab == kTabCreate) _onEnterCreate();
                  },
                  destinations: [
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: ref.watch(
                          assistantProvider.select((s) => s.changedUnseen),
                        ),
                        smallSize: 8,
                        child: const Icon(Icons.draw_outlined),
                      ),
                      selectedIcon: const Icon(Icons.draw),
                      label: '创作',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.photo_library_outlined),
                      selectedIcon: Icon(Icons.photo_library),
                      label: '图库',
                    ),
                    if (showAi)
                      const NavigationDestination(
                        icon: Icon(Icons.auto_awesome_outlined),
                        selectedIcon: Icon(Icons.auto_awesome),
                        label: 'AI',
                      ),
                    const NavigationDestination(
                      icon: Icon(Icons.lightbulb_outline),
                      selectedIcon: Icon(Icons.lightbulb),
                      label: '灵感',
                    ),
                    const NavigationDestination(
                      icon: Icon(Icons.person_outline),
                      selectedIcon: Icon(Icons.person),
                      label: '我的',
                    ),
                  ],
                ),
        );
      },
    );
  }
}
