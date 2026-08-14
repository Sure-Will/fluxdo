import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/ai_chat_message_item.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_renderer.dart';
import 'package:fluxdo/widgets/topic/topic_summary_widget.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('MarkdownBody 开启选区后可拖选局部文本并用 Cmd+C 复制', (tester) async {
    const data = '这是一段可以局部选择并复制的 AI 回答文本，用来验证拖选不会退化成复制全文。';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 560,
            child: MarkdownBody(data: data, selectionEnabled: true),
          ),
        ),
      ),
    );
    await tester.pump();

    final scopeFinder = find.byType(SelectionScope);
    expect(scopeFinder, findsOneWidget);
    final controller = tester.widget<SelectionScope>(scopeFinder).controller;
    expect(controller.registry.length, greaterThan(0));

    final paragraphRect = tester.getRect(find.byType(InlineSpanText).first);
    final start = paragraphRect.topLeft + const Offset(12, 12);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.moveTo(start + const Offset(40, 0));
    await tester.pump();
    await gesture.moveTo(start + const Offset(180, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(controller.selection, isNotNull);
    expect(controller.selection!.isCollapsed, isFalse);

    final modifier = defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();

    expect(copied, isNotNull);
    final selectedText = copied!.trim();
    expect(selectedText, isNotEmpty);
    expect(data.contains(selectedText), isTrue);
    expect(selectedText.length, lessThan(data.length));
  });

  testWidgets('MarkdownBody 默认保持只读预览，不扩大其他调用点的选区范围', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MarkdownBody(data: '编辑器预览仍默认不可拖选')),
      ),
    );
    await tester.pump();

    expect(find.byType(SelectionScope), findsNothing);
  });

  testWidgets('AI 回答仅在完成且非消息多选模式时开启局部选区', (tester) async {
    Future<void> pumpMessage(
      MessageStatus status, {
      bool selectionMode = false,
    }) async {
      await tester.pumpWidget(
        _localizedApp(
          AiChatMessageItem(
            message: AiChatMessage(
              id: 'assistant-message',
              role: ChatRole.assistant,
              content: '可以拖选的 **Markdown** 回答',
              createdAt: DateTime(2026, 8, 13),
              status: status,
            ),
            selectionMode: selectionMode,
          ),
        ),
      );
      await tester.pump();
    }

    await pumpMessage(MessageStatus.completed);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectionEnabled,
      isTrue,
    );

    await pumpMessage(MessageStatus.streaming);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectionEnabled,
      isFalse,
    );

    await pumpMessage(MessageStatus.completed, selectionMode: true);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectionEnabled,
      isFalse,
    );
  });

  testWidgets('话题摘要仅在流式输出结束后开启局部选区', (tester) async {
    Future<void> pumpSummary({required bool isStreaming}) async {
      final summary = TopicSummary(
        summarizedText: '摘要中的 **Markdown** 内容',
        outdated: false,
        canRegenerate: false,
        newPostsSinceSummary: 0,
        isStreaming: isStreaming,
      );
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(isStreaming),
          overrides: [
            topicSummaryProvider.overrideWith(
              (ref, topicId) => Stream.value(summary),
            ),
          ],
          child: _localizedApp(const TopicSummaryWidget(topicId: 42)),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await pumpSummary(isStreaming: false);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectionEnabled,
      isTrue,
    );

    await pumpSummary(isStreaming: true);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectionEnabled,
      isFalse,
    );
  });
}

Widget _localizedApp(Widget home) {
  return TranslationProvider(
    child: MaterialApp(
      navigatorKey: navigatorKey,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: Scaffold(body: home),
    ),
  );
}
