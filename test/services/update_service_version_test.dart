import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/update_service.dart';

void main() {
  group('compareUpstreamVersions', () {
    test('同一上游版本忽略 Sure 修订号和内部构建号', () {
      expect(compareUpstreamVersions('v0.2.26', '0.2.26-sure.1+2026081416'), 0);
      expect(
        compareUpstreamVersions(
          '0.2.26-sure.2+2026081510',
          '0.2.26-sure.1+2026081416',
        ),
        0,
      );
    });

    test('上游核心版本升级时仍会提示更新', () {
      expect(
        compareUpstreamVersions('0.2.27', '0.2.26-sure.9+2026083010'),
        greaterThan(0),
      );
      expect(
        compareUpstreamVersions('0.2.25', '0.2.26-sure.1+2026081416'),
        lessThan(0),
      );
    });

    test('拒绝无法安全比较的版本号', () {
      expect(
        () => compareUpstreamVersions('latest', '0.2.26-sure.1'),
        throwsFormatException,
      );
      expect(
        () => compareUpstreamVersions('0.2.26.1', '0.2.26'),
        throwsFormatException,
      );
    });
  });

  group('Sure Release 更新通道', () {
    test('解析独立 tag 并比较同一上游基线的修订号', () {
      expect(parseSureReleaseVersion('sure-v0.2.26-r2'), '0.2.26-sure.2');
      expect(
        compareSureVersions('0.2.26-sure.2', '0.2.26-sure.1+2026081416'),
        greaterThan(0),
      );
    });

    test('上游基线优先于 Sure 修订号', () {
      expect(
        compareSureVersions('0.2.27-sure.1', '0.2.26-sure.99'),
        greaterThan(0),
      );
      expect(() => parseSureReleaseVersion('v0.2.26'), throwsFormatException);
    });
  });
}
