import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/ai_chat_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<String>> pumpInput(
    WidgetTester tester, {
    bool isGenerating = false,
    bool isContextLoading = false,
    bool acceptSend = true,
  }) async {
    final sent = <String>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: AiChatInput(
              isGenerating: isGenerating,
              isContextLoading: isContextLoading,
              onSend: (text, List<AiChatAttachment> attachments) async {
                sent.add(text);
                return acceptSend;
              },
              onStop: () {},
            ),
          ),
        ),
      ),
    );
    // 加载态包含无限循环的进度指示器，不能用 pumpAndSettle。
    await tester.pump();
    return sent;
  }

  testWidgets('Enter 发送消息并保留输入焦点', (tester) async {
    final sent = await pumpInput(tester);
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.enterText(field, 'hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(sent, ['hello']);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
  });

  testWidgets('Shift+Enter 不发送并保留换行输入能力', (tester) async {
    final sent = await pumpInput(tester);
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.enterText(field, '第一行');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(sent, isEmpty);

    // Widget 测试没有真实平台输入法，这里模拟 TextField 收到换行后的编辑值。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '第一行\n',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '第一行\n');
  });

  testWidgets('输入法组合期间 Enter 只确认候选，不发送', (tester) async {
    final sent = await pumpInput(tester);
    final field = find.byType(TextField);

    await tester.tap(field);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(sent, isEmpty);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sent, ['你']);
  });

  testWidgets('生成期间 Enter 不会重复发送', (tester) async {
    final sent = await pumpInput(tester, isGenerating: true);
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.enterText(field, '下一条');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(tester.widget<TextField>(field).controller!.text, '下一条');
  });

  testWidgets('上下文加载期间不发送，且保留输入草稿', (tester) async {
    final sent = await pumpInput(tester, isContextLoading: true);
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.enterText(field, '等全部帖子加载完再发');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sent, isEmpty);
    expect(tester.widget<TextField>(field).controller!.text, '等全部帖子加载完再发');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('上层未接收消息时保留输入草稿', (tester) async {
    final sent = await pumpInput(tester, acceptSend: false);
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.enterText(field, '加载失败后仍可重试');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(sent, ['加载失败后仍可重试']);
    expect(tester.widget<TextField>(field).controller!.text, '加载失败后仍可重试');
  });
}
