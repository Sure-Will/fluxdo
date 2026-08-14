import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/page_aware_image.dart';

void main() {
  testWidgets('关闭页面 ticker 时卸载图片子树', (tester) async {
    var disposed = 0;

    Widget buildTree(bool enabled) {
      return TickerMode(
        enabled: enabled,
        child: PageAwareImage(
          builder: (_) => _DisposableProbe(onDispose: () => disposed++),
          inactiveBuilder: (_) => const SizedBox(key: ValueKey('inactive')),
        ),
      );
    }

    await tester.pumpWidget(buildTree(true));
    expect(find.byType(_DisposableProbe), findsOneWidget);

    await tester.pumpWidget(buildTree(false));
    expect(find.byType(_DisposableProbe), findsNothing);
    expect(find.byKey(const ValueKey('inactive')), findsOneWidget);
    expect(disposed, 1);

    await tester.pumpWidget(buildTree(true));
    expect(find.byType(_DisposableProbe), findsOneWidget);
  });
}

class _DisposableProbe extends StatefulWidget {
  const _DisposableProbe({required this.onDispose});

  final VoidCallback onDispose;

  @override
  State<_DisposableProbe> createState() => _DisposableProbeState();
}

class _DisposableProbeState extends State<_DisposableProbe> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
