import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/topic_list/topic_list_provider.dart';

void main() {
  Topic topic(int id, int activityMinute, {bool pinned = false}) => Topic(
    id: id,
    title: 'Topic $id',
    slug: 'topic-$id',
    postsCount: 1,
    replyCount: 0,
    views: 0,
    likeCount: 0,
    categoryId: '1',
    pinned: pinned,
    lastPostedAt: DateTime.utc(2026, 8, 14, 0, activityMinute),
  );

  test('连续加载较旧积压时仍按最近活跃顺序排列', () {
    final firstBatch = [topic(120, 40), topic(90, 30), topic(71, 20)];
    final secondBatch = [topic(70, 19), topic(40, 10), topic(21, 1)];

    final afterFirst = mergeLatestTopicRefresh(firstBatch, const []);
    final afterSecond = mergeLatestTopicRefresh(secondBatch, afterFirst);

    expect(afterSecond.map((item) => item.id), [120, 90, 71, 70, 40, 21]);
  });

  test('置顶话题保持在普通话题之前', () {
    final merged = mergeLatestTopicRefresh(
      [topic(2, 50)],
      [topic(1, 1, pinned: true)],
    );

    expect(merged.map((item) => item.id), [1, 2]);
  });
}
