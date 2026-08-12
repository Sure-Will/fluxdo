import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/ai_chat_page.dart';

void main() {
  test('V4 Flash thinking menu uses direct English API labels', () {
    expect(
      [
        ThinkingLevel.off,
        ThinkingLevel.auto,
        ThinkingLevel.low,
        ThinkingLevel.high,
        ThinkingLevel.max,
      ].map(deepSeekV4FlashThinkingLabel),
      ['Off', 'Auto', 'Low', 'High', 'Max'],
    );
  });
}
