import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';

void main() {
  group('TopicListIncomingState', () {
    test('刷新积压时只返回指定分类最新的 50 条', () {
      final state = TopicListIncomingState(
        incomingTopics: {
          for (var id = 1; id <= 120; id++) id: id.isEven ? 1 : 2,
          for (var id = 121; id <= 260; id++) id: 1,
        },
      );

      final ids = state.incomingTopicIdsForCategory(
        1,
        limit: TopicListIncomingState.maxRefreshCount,
      );

      expect(TopicListIncomingState.maxRefreshCount, 50);
      expect(ids, List<int>.generate(50, (index) => 211 + index));
    });

    test('不足上限时保留原有顺序', () {
      const state = TopicListIncomingState(
        incomingTopics: {10: 1, 11: 2, 12: 1},
      );

      expect(
        state.incomingTopicIdsForCategory(
          1,
          limit: TopicListIncomingState.maxRefreshCount,
        ),
        [10, 12],
      );
      expect(
        state.incomingTopicIdsForCategory(
          null,
          limit: TopicListIncomingState.maxRefreshCount,
        ),
        [10, 11, 12],
      );
    });

    test('重复更新会移到末尾并进入最新 50 条', () {
      var state = const TopicListIncomingState();
      for (var id = 1; id <= 60; id++) {
        state = state.recordIncoming(id, 1);
      }

      state = state.recordIncoming(1, 1);

      final ids = state.incomingTopicIdsForCategory(
        1,
        limit: TopicListIncomingState.maxRefreshCount,
      );
      expect(ids, [...List<int>.generate(49, (index) => index + 12), 1]);
    });

    test('重复更新缺少分类时保留旧分类并移到末尾', () {
      final state = const TopicListIncomingState()
          .recordIncoming(1, 7)
          .recordIncoming(2, 7)
          .recordIncoming(1, null);

      expect(state.incomingTopics, {2: 7, 1: 7});
      expect(state.incomingTopicIdsForCategory(7), [2, 1]);
    });

    test('快照版本能区分请求途中再次更新的同一 topic', () {
      var state = const TopicListIncomingState()
          .recordIncoming(10, 1)
          .recordIncoming(11, 1);
      final snapshot = state.incomingRevisionSnapshotForCategory(1);

      state = state.recordIncoming(10, 1).recordIncoming(12, 1);
      final cleared = state.clearSnapshot(snapshot);

      expect(snapshot.keys, [10, 11]);
      expect(state.incomingRevisions[10], isNot(snapshot[10]));
      expect(state.incomingRevisions[11], snapshot[11]);
      expect(state.incomingTopics.keys, [11, 10, 12]);
      expect(cleared.incomingTopics.keys, [10, 12]);
    });
  });
}
