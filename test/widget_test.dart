import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/auth_mode.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/store/gen_settings.dart';
import 'package:plana_app/features/gallery/gallery_page.dart';
import 'package:plana_app/main.dart';

/// 测试环境无 Keystore,固定「已选直连」跳过引导页,直接冒烟创作页。
class _TokenMode extends AuthModeNotifier {
  @override
  Future<AuthMode?> build() async => AuthMode.token;
}

/// 同理跳过首启的通知说明页(notifyPrimed 已过)。
class _PrimedSettings extends GenSettingsNotifier {
  @override
  Future<GenSettings> build() async => const GenSettings(notifyPrimed: true);
}

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStoresProvider.overrideWithValue(AppStores.ephemeral()),
        authModeProvider.overrideWith(_TokenMode.new),
        genSettingsProvider.overrideWith(_PrimedSettings.new),
      ],
      child: const PlanaApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('创作页冒烟:核心区块可见', (WidgetTester tester) async {
    await _pumpApp(tester);

    expect(find.text('提示词'), findsOneWidget);
    expect(find.text('角色'), findsOneWidget);
    expect(find.text('生成'), findsWidgets);
    expect(find.text('创作'), findsOneWidget);

    // 放行工作台持久化的 800ms 防抖 Timer,避免拆树时报 pending timer
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('桌面宽度使用侧边导航', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpApp(tester);

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('创作'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('桌面跨导航断点缩放时保留当前页面且导航仍可用', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpApp(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('图库'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      1,
    );
    expect(find.text('还没有作品'), findsOneWidget);
    final galleryState = tester.state(find.byType(GalleryPage));

    for (final width in [1100.0, 950.0, 901.0, 899.0, 820.0, 800.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    expect(find.text('还没有作品'), findsOneWidget);
    expect(tester.state(find.byType(GalleryPage)), same(galleryState));

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('我的'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    expect(find.text('账号与接入'), findsOneWidget);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      3,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('创作'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      0,
    );
    expect(find.text('提示词'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 900));
  });
}
