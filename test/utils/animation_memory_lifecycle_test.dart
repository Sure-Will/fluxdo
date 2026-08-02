import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/animation_memory_lifecycle.dart';

void main() {
  testWidgets('inactive 持续 5 秒后才释放动画，短暂失焦不抖动', (tester) async {
    var pauses = 0;
    var resumes = 0;
    final lifecycle = AnimationMemoryLifecycle(
      onPause: () => pauses++,
      onResume: () => resumes++,
    );
    addTearDown(lifecycle.dispose);

    lifecycle.handle(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 4));
    expect(pauses, 0);

    lifecycle.handle(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    expect(pauses, 0);
    expect(resumes, 0);

    lifecycle.handle(AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 5));
    expect(pauses, 1);

    lifecycle.handle(AppLifecycleState.resumed);
    expect(resumes, 1);
  });

  testWidgets('hidden 立即释放且重复状态不会重复调用', (tester) async {
    var pauses = 0;
    var resumes = 0;
    final lifecycle = AnimationMemoryLifecycle(
      onPause: () => pauses++,
      onResume: () => resumes++,
    );
    addTearDown(lifecycle.dispose);

    lifecycle.handle(AppLifecycleState.hidden);
    lifecycle.handle(AppLifecycleState.hidden);
    expect(pauses, 1);

    lifecycle.handle(AppLifecycleState.resumed);
    lifecycle.handle(AppLifecycleState.resumed);
    expect(resumes, 1);
  });
}
