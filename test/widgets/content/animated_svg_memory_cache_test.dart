import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/content/animated_svg_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AnimatedSvgView.clearMemoryCache();
  });

  test('SVG 首帧缓存按解码字节预算淘汰旧图', () async {
    AnimatedSvgView.debugSetMemoryCacheByteCap(1024);

    AnimatedSvgView.debugPutMemoryCacheImage(1, await _makeImage(16, 16));
    expect(AnimatedSvgView.debugMemoryCacheLength, 1);
    expect(AnimatedSvgView.debugMemoryCacheBytes, 1024);

    AnimatedSvgView.debugPutMemoryCacheImage(2, await _makeImage(16, 16));
    expect(AnimatedSvgView.debugMemoryCacheLength, 1);
    expect(AnimatedSvgView.debugMemoryCacheBytes, 1024);
  });

  test('清理 SVG 首帧缓存会释放全部预算', () async {
    AnimatedSvgView.debugPutMemoryCacheImage(1, await _makeImage(16, 16));

    AnimatedSvgView.clearMemoryCache();

    expect(AnimatedSvgView.debugMemoryCacheLength, 0);
    expect(AnimatedSvgView.debugMemoryCacheBytes, 0);
  });
}

Future<ui.Image> _makeImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}
