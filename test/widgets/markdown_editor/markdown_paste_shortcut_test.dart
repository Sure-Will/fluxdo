import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_toolbar.dart';
import 'package:super_clipboard/super_clipboard.dart';

void main() {
  testWidgets('Cmd+V 由统一粘贴回调消费且只触发一次', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = TextEditingController();
    final focusNode = FocusNode();
    var pasteCount = 0;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      controller.dispose();
      focusNode.dispose();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: Column(
              children: [
                TextField(controller: controller, focusNode: focusNode),
                SizedBox(
                  height: 56,
                  child: MarkdownToolbar(
                    controller: controller,
                    focusNode: focusNode,
                    visibleToolIds: const [],
                    onPaste: () async {
                      pasteCount += 1;
                      controller.text = 'pasted';
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(pasteCount, 1);
    expect(controller.text, 'pasted');
    debugDefaultTargetPlatformOverride = null;
  });

  test('图片格式误报且 getFile 返回 null 时立即降级', () async {
    final result = await MarkdownToolbarState.readImageFromReader(
      _UnavailableImageReader(),
    ).timeout(const Duration(seconds: 1));

    expect(result, isNull);
  });
}

class _UnavailableImageReader extends Fake implements DataReader {
  @override
  bool canProvide(DataFormat format) => true;

  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) => null;
}
