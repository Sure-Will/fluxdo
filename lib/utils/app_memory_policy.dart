import 'package:flutter/widgets.dart';

/// 应用级内存与渲染策略。
///
/// 将平台差异和生命周期判定集中在这里，避免入口文件散落不可测试的
/// magic number。
class AppMemoryPolicy {
  AppMemoryPolicy._();

  static const int _defaultImageCacheMaximumBytes = 256 * 1024 * 1024;
  static const int _defaultImageCacheMaximumEntries = 30000;
  static const int _macOSImageCacheMaximumBytes = 128 * 1024 * 1024;
  static const int _macOSImageCacheMaximumEntries = 4096;

  static ImageCacheLimits imageCacheLimits({
    required TargetPlatform platform,
    required bool isWeb,
  }) {
    if (!isWeb && platform == TargetPlatform.macOS) {
      return const ImageCacheLimits(
        maximumBytes: _macOSImageCacheMaximumBytes,
        maximumEntries: _macOSImageCacheMaximumEntries,
      );
    }
    return const ImageCacheLimits(
      maximumBytes: _defaultImageCacheMaximumBytes,
      maximumEntries: _defaultImageCacheMaximumEntries,
    );
  }

  /// 只有前台可交互且确为当前页时才允许 ticker 驱动新帧。
  static bool shouldEnablePageTickers({
    required AppLifecycleState lifecycleState,
    required bool isActivePage,
  }) {
    return isActivePage && lifecycleState == AppLifecycleState.resumed;
  }
}

class AppPageTickerGate extends StatelessWidget {
  const AppPageTickerGate({
    required this.lifecycleState,
    required this.isActivePage,
    required this.child,
    super.key,
  });

  final AppLifecycleState lifecycleState;
  final bool isActivePage;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: AppMemoryPolicy.shouldEnablePageTickers(
        lifecycleState: lifecycleState,
        isActivePage: isActivePage,
      ),
      child: child,
    );
  }
}

@immutable
class ImageCacheLimits {
  const ImageCacheLimits({
    required this.maximumBytes,
    required this.maximumEntries,
  });

  final int maximumBytes;
  final int maximumEntries;
}
