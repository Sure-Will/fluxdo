import 'dart:async';

import 'package:flutter/widgets.dart';

/// 把应用生命周期翻译成动图全局暂停/恢复。
///
/// 桌面端切到别的应用只会进入 [AppLifecycleState.inactive]，不会进入
/// hidden。延迟释放既覆盖长期后台占用，又避免菜单、系统弹窗等短暂失焦
/// 触发全量重解码。
class AnimationMemoryLifecycle {
  AnimationMemoryLifecycle({
    required this.onPause,
    required this.onResume,
    this.inactiveDelay = const Duration(seconds: 5),
  });

  final void Function() onPause;
  final void Function() onResume;
  final Duration inactiveDelay;

  Timer? _inactiveTimer;
  bool _paused = false;

  void handle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _inactiveTimer?.cancel();
        _inactiveTimer = null;
        if (_paused) {
          _paused = false;
          onResume();
        }
        return;
      case AppLifecycleState.inactive:
        if (_paused || _inactiveTimer != null) return;
        _inactiveTimer = Timer(inactiveDelay, () {
          _inactiveTimer = null;
          _pause();
        });
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _inactiveTimer?.cancel();
        _inactiveTimer = null;
        _pause();
        return;
    }
  }

  void _pause() {
    if (_paused) return;
    _paused = true;
    onPause();
  }

  void dispose() {
    _inactiveTimer?.cancel();
    _inactiveTimer = null;
  }
}
