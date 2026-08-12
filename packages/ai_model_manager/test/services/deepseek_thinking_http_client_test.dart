import 'dart:convert';

import 'package:ai_model_manager/models/ai_provider.dart';
import 'package:ai_model_manager/services/deepseek_thinking_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _RecordingClient extends http.BaseClient {
  String? body;
  Uri? url;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final typed = request as http.Request;
    body = typed.body;
    url = request.url;
    return http.StreamedResponse(
      Stream.value(utf8.encode('data: [DONE]\n\n')),
      200,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test('max 追加在旧等级末尾，不改变已持久化等级索引', () {
    expect(ThinkingLevel.off.index, 0);
    expect(ThinkingLevel.auto.index, 1);
    expect(ThinkingLevel.low.index, 2);
    expect(ThinkingLevel.medium.index, 3);
    expect(ThinkingLevel.high.index, 4);
    expect(ThinkingLevel.custom.index, 5);
    expect(ThinkingLevel.max.index, 6);
  });

  group('DeepSeekThinkingRequest', () {
    test('关闭思考发送 disabled，并清除旧 effort', () {
      final body = DeepSeekThinkingRequest.apply(
        {'model': 'deepseek-v4-flash', 'reasoning_effort': 'high'},
        const ThinkingConfig(level: ThinkingLevel.off),
      );

      expect(body['thinking'], {'type': 'disabled'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('自动开启 thinking，但不发送 effort 让服务端使用默认值', () {
      final body = DeepSeekThinkingRequest.apply(
        {'model': 'deepseek-v4-flash', 'reasoning_effort': 'low'},
        const ThinkingConfig(level: ThinkingLevel.auto),
      );

      expect(body['thinking'], {'type': 'enabled'});
      expect(body.containsKey('reasoning_effort'), isFalse);
    });

    test('low/high/max 映射为 DeepSeek 官方 effort 字符串', () {
      for (final entry in {
        ThinkingLevel.low: 'low',
        ThinkingLevel.high: 'high',
        ThinkingLevel.max: 'max',
      }.entries) {
        final body = DeepSeekThinkingRequest.apply(
          {'model': 'deepseek-v4-flash'},
          ThinkingConfig(level: entry.key),
        );
        expect(body['thinking'], {'type': 'enabled'});
        expect(body['reasoning_effort'], entry.value);
      }
    });

    test('旧 medium/custom 配置在 V4 Flash 上兼容到 high', () {
      for (final level in [ThinkingLevel.medium, ThinkingLevel.custom]) {
        final body = DeepSeekThinkingRequest.apply(
          {'model': 'deepseek-v4-flash'},
          ThinkingConfig(level: level, customBudget: 64000),
        );
        expect(body['reasoning_effort'], 'high');
      }
    });
  });

  test('HTTP 装饰器只改 chat completions body，并透传到 delegate', () async {
    final delegate = _RecordingClient();
    final client = DeepSeekThinkingHttpClient(
      delegate: delegate,
      thinkingConfig: const ThinkingConfig(level: ThinkingLevel.max),
    );
    final request = http.Request(
      'POST',
      Uri.parse('https://api.example.com/v1/chat/completions'),
    )
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'model': 'deepseek-v4-flash',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
      });

    final response = await client.send(request);
    await response.stream.drain<void>();

    expect(delegate.url!.path, '/v1/chat/completions');
    final body = jsonDecode(delegate.body!) as Map<String, dynamic>;
    expect(body['thinking'], {'type': 'enabled'});
    expect(body['reasoning_effort'], 'max');
    expect(body['messages'], isNotEmpty);
  });

  test('装饰器不关闭外部传入的网络 client', () {
    final delegate = _RecordingClient();
    final client = DeepSeekThinkingHttpClient(
      delegate: delegate,
      thinkingConfig: const ThinkingConfig(level: ThinkingLevel.high),
    );

    client.close();

    expect(delegate.closed, isFalse);
  });
}
