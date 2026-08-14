import 'package:flutter/widgets.dart';

/// Builds an image child only while its containing app page is active.
///
/// [TickerMode] is inherited by every page in the persistent navigation
/// [IndexedStack]. A regular [Image] does not react to it, and native animated
/// images use their own [Timer] rather than a Flutter ticker. Removing the
/// image child when the mode is disabled removes its [ImageStream] listener,
/// allowing the provider to release decoded animation frames.
class PageAwareImage extends StatelessWidget {
  const PageAwareImage({
    required this.builder,
    required this.inactiveBuilder,
    super.key,
  });

  final WidgetBuilder builder;
  final WidgetBuilder inactiveBuilder;

  @override
  Widget build(BuildContext context) {
    if (!TickerMode.valuesOf(context).enabled) {
      return inactiveBuilder(context);
    }
    return builder(context);
  }
}
