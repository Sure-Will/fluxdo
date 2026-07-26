import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/ai_chat_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _topicId = 42;
const _messageListKey = ValueKey('ai_chat_message_list');
const _scrollToLatestKey = ValueKey('ai_chat_scroll_to_latest');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TestTopicAiChatNotifier notifier;

  Future<void> pumpChat(WidgetTester tester) async {
    final provider = AiProvider(
      id: 'test-provider',
      name: 'Test Provider',
      type: AiProviderType.openai,
      baseUrl: 'https://example.com',
      models: const [
        AiModel(
          id: 'test-model',
          name: 'Test Model',
          input: [Modality.text],
          output: [Modality.text],
        ),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode([provider.toJson()]),
    });
    final prefs = await SharedPreferences.getInstance();
    notifier = _TestTopicAiChatNotifier(prefs, _initialState());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSharedPreferencesProvider.overrideWithValue(prefs),
          topicAiChatProvider.overrideWith((ref, topicId) {
            expect(topicId, _topicId);
            return notifier;
          }),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const AiChatPage(topicId: _topicId, embedded: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  ScrollController messageController(WidgetTester tester) {
    return tester.widget<ListView>(find.byKey(_messageListKey)).controller!;
  }

  testWidgets('停留底部时流式增长会继续跟随最新内容', (tester) async {
    await pumpChat(tester);
    final controller = messageController(tester);

    expect(controller.position.extentAfter, lessThanOrEqualTo(1));

    notifier.growStreamingMessage();
    await tester.pump();
    await tester.pump();

    expect(controller.position.extentAfter, lessThanOrEqualTo(1));
    expect(find.byKey(_scrollToLatestKey), findsNothing);
  });

  testWidgets('用户向旧消息滚动后流式增长不再抢控制权', (tester) async {
    await pumpChat(tester);
    final controller = messageController(tester);

    await tester.drag(find.byKey(_messageListKey), const Offset(0, 260));
    await tester.pump();
    final userPosition = controller.position.pixels;

    expect(userPosition, lessThan(controller.position.maxScrollExtent));
    expect(find.byKey(_scrollToLatestKey), findsOneWidget);

    notifier.growStreamingMessage();
    await tester.pump();
    await tester.pump();

    expect(controller.position.pixels, closeTo(userPosition, 0.5));
    expect(controller.position.extentAfter, greaterThan(0));
  });

  testWidgets('点击回到最新后恢复流式跟随', (tester) async {
    await pumpChat(tester);
    final controller = messageController(tester);

    await tester.drag(find.byKey(_messageListKey), const Offset(0, 260));
    await tester.pump();
    await tester.tap(find.byKey(_scrollToLatestKey));
    await tester.pumpAndSettle();

    expect(controller.position.extentAfter, lessThanOrEqualTo(1));
    expect(find.byKey(_scrollToLatestKey), findsNothing);

    notifier.growStreamingMessage();
    await tester.pump();
    await tester.pump();
    expect(controller.position.extentAfter, lessThanOrEqualTo(1));
  });
}

TopicAiChatState _initialState() {
  final now = DateTime(2026, 7, 26);
  final messages = <AiChatMessage>[
    for (var index = 0; index < 14; index++)
      AiChatMessage(
        id: 'user-$index',
        role: ChatRole.user,
        content: '历史消息 $index：${List.filled(4, '这是一段用于撑高消息列表的内容。').join()}',
        createdAt: now.add(Duration(minutes: index)),
      ),
    AiChatMessage(
      id: 'streaming',
      role: ChatRole.assistant,
      content: '',
      thinkingContent: '正在思考。',
      createdAt: now.add(const Duration(minutes: 15)),
      status: MessageStatus.streaming,
    ),
  ];
  return TopicAiChatState(
    messages: messages,
    isGenerating: true,
    currentSessionId: 'session-1',
    sessions: [AiChatSession(id: 'session-1', createdAt: now, updatedAt: now)],
  );
}

class _TestTopicAiChatNotifier extends TopicAiChatNotifier {
  _TestTopicAiChatNotifier(
    SharedPreferences prefs,
    TopicAiChatState initialState,
  ) : super(
        chatService: AiChatService(),
        storageService: AiChatStorageService(prefs),
        topicId: _topicId,
      ) {
    state = initialState;
  }

  void growStreamingMessage() {
    final messages = [...state.messages];
    final last = messages.last;
    messages[messages.length - 1] = last.copyWith(
      thinkingContent:
          '${last.thinkingContent}\n${List.filled(40, '新增的流式思考会持续扩展消息高度。').join()}',
    );
    state = state.copyWith(messages: messages);
  }
}
