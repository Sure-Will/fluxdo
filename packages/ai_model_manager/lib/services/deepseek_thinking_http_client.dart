import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_provider.dart';

/// DeepSeek V4 Flash 的 thinking 请求体适配。
///
/// openai_dart 目前没有 DeepSeek 专属的 `thinking` 字段，也没有精确的
/// `reasoning_effort: "max"` 枚举值。因此只在 V4 Flash 路径上修改已经由 SDK
/// 生成好的 Chat Completions JSON，其余字段、请求头和流式响应全部原样透传。
class DeepSeekThinkingRequest {
  DeepSeekThinkingRequest._();

  /// 把统一思考配置映射为 DeepSeek V4 Flash 的请求字段。
  ///
  /// V4 Flash 的「自动」表示开启 thinking，但不指定 effort，让服务端使用
  /// 官方默认值；旧配置里的 medium/custom 在 V4 Flash 上兼容到 high。
  static Map<String, dynamic> apply(
    Map<String, dynamic> body,
    ThinkingConfig config,
  ) {
    final patched = Map<String, dynamic>.from(body);
    if (config.level == ThinkingLevel.off) {
      patched['thinking'] = {'type': 'disabled'};
      patched.remove('reasoning_effort');
      return patched;
    }

    patched['thinking'] = {'type': 'enabled'};
    final effort = switch (config.level) {
      ThinkingLevel.auto => null,
      ThinkingLevel.low => 'low',
      ThinkingLevel.medium => 'high',
      ThinkingLevel.high => 'high',
      ThinkingLevel.custom => 'high',
      ThinkingLevel.max => 'max',
      ThinkingLevel.off => null,
    };
    if (effort == null) {
      patched.remove('reasoning_effort');
    } else {
      patched['reasoning_effort'] = effort;
    }
    return patched;
  }
}

/// 仅给 DeepSeek V4 Flash 使用的请求体装饰器。
///
/// [delegate] 可以是应用的 Dio 桥接 client 或可取消的流式 client；装饰器
/// 不接管它的生命周期，只有显式设置 [ownsDelegate] 时才会在 close 时关闭。
class DeepSeekThinkingHttpClient extends http.BaseClient {
  DeepSeekThinkingHttpClient({
    required http.Client delegate,
    required this.thinkingConfig,
    this.ownsDelegate = false,
  }) : _delegate = delegate;

  final http.Client _delegate;
  final ThinkingConfig thinkingConfig;
  final bool ownsDelegate;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_closed) {
      throw http.ClientException(
        'DeepSeekThinkingHttpClient has been closed.',
        request.url,
      );
    }
    if (request is http.Request && _isChatCompletions(request.url)) {
      _patchRequestBody(request);
    }
    return _delegate.send(request);
  }

  static bool _isChatCompletions(Uri url) {
    return url.path.toLowerCase().endsWith('/chat/completions');
  }

  void _patchRequestBody(http.Request request) {
    try {
      final decoded = jsonDecode(request.body);
      if (decoded is! Map) return;
      final body = Map<String, dynamic>.from(decoded);
      request.body = jsonEncode(
        DeepSeekThinkingRequest.apply(body, thinkingConfig),
      );
    } on FormatException {
      // SDK 正常会生成 JSON；如果兼容代理传入了非 JSON 请求，则保持原样。
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (ownsDelegate) _delegate.close();
  }
}
