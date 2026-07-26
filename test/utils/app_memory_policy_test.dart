import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/app_memory_policy.dart';

void main() {
  test('macOS 原生使用收紧的图片缓存预算', () {
    final limits = AppMemoryPolicy.imageCacheLimits(
      platform: TargetPlatform.macOS,
      isWeb: false,
    );

    expect(limits.maximumBytes, 128 * 1024 * 1024);
    expect(limits.maximumEntries, 4096);
  });

  test('其它平台保持既有图片缓存预算', () {
    final limits = AppMemoryPolicy.imageCacheLimits(
      platform: TargetPlatform.android,
      isWeb: false,
    );

    expect(limits.maximumBytes, 256 * 1024 * 1024);
    expect(limits.maximumEntries, 30000);
  });

  test('只有 resumed 的当前页启用 ticker', () {
    expect(
      AppMemoryPolicy.shouldEnablePageTickers(
        lifecycleState: AppLifecycleState.resumed,
        isActivePage: true,
      ),
      isTrue,
    );
    expect(
      AppMemoryPolicy.shouldEnablePageTickers(
        lifecycleState: AppLifecycleState.resumed,
        isActivePage: false,
      ),
      isFalse,
    );
    expect(
      AppMemoryPolicy.shouldEnablePageTickers(
        lifecycleState: AppLifecycleState.inactive,
        isActivePage: true,
      ),
      isFalse,
    );
    expect(
      AppMemoryPolicy.shouldEnablePageTickers(
        lifecycleState: AppLifecycleState.hidden,
        isActivePage: true,
      ),
      isFalse,
    );
  });

  testWidgets('页面门控向子树暴露计算后的 ticker 状态', (tester) async {
    bool? enabled;

    Widget buildGate(AppLifecycleState state) {
      return AppPageTickerGate(
        lifecycleState: state,
        isActivePage: true,
        child: Builder(
          builder: (context) {
            enabled = TickerMode.valuesOf(context).enabled;
            return const SizedBox();
          },
        ),
      );
    }

    await tester.pumpWidget(buildGate(AppLifecycleState.inactive));
    expect(enabled, isFalse);

    await tester.pumpWidget(buildGate(AppLifecycleState.resumed));
    expect(enabled, isTrue);
  });
}
