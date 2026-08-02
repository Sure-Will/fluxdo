import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_animated_image/native_animated_image.dart';
import 'package:native_animated_image/src/ffi/native_animated_image_ffi.dart'
    show NativeAnimatedImageFrameSource;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NativeAnimatedImageProvider.resumeAllAnimations();
    NativeAnimatedImageProvider.debugFrameSourceFactory = null;
    ui.Image.onCreate = null;
    ui.Image.onDispose = null;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  test('最后一个 listener 移除后释放 Rust 路径的全部帧句柄', () async {
    final source = _TestFrameSource();
    NativeAnimatedImageProvider.debugFrameSourceFactory = (_) async => source;

    final created = <ui.Image>{};
    final disposed = <ui.Image>{};
    ui.Image.onCreate = (image) {
      if (image.width != 2 || image.height != 2) return;
      created.add(image);
    };
    ui.Image.onDispose = (image) {
      if (image.width == 2 && image.height == 2) disposed.add(image);
    };

    final provider = NativeAnimatedImageProvider.memory(
      Uint8List.fromList([1, 2, 3]),
      tag: 'frame-lifecycle-regression',
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    var emittedFrames = 0;
    final playedAllFrames = Completer<void>();
    final listener = ImageStreamListener((info, _) {
      emittedFrames++;
      info.image.dispose();
      if (emittedFrames >= 3 && !playedAllFrames.isCompleted) {
        playedAllFrames.complete();
      }
    });

    stream.addListener(listener);
    await playedAllFrames.future.timeout(const Duration(seconds: 3));

    stream.removeListener(listener);
    await provider.evict();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(created, isNotEmpty);
    expect(
      created.difference(disposed),
      hasLength(1),
      reason: '只允许 completer 按框架契约保留当前显示帧',
    );
    expect(source.releaseCount, 1, reason: 'native handle 必须幂等释放');
  });

  test('后台暂停释放帧，恢复后重新解码并继续播放', () async {
    var decodeCount = 0;
    final sources = <_TestFrameSource>[];
    NativeAnimatedImageProvider.debugFrameSourceFactory = (_) async {
      decodeCount++;
      final source = _TestFrameSource();
      sources.add(source);
      return source;
    };

    final created = <ui.Image>{};
    final disposed = <ui.Image>{};
    ui.Image.onCreate = (image) {
      if (image.width == 2 && image.height == 2) created.add(image);
    };
    ui.Image.onDispose = (image) {
      if (image.width == 2 && image.height == 2) disposed.add(image);
    };

    final provider = NativeAnimatedImageProvider.memory(
      Uint8List.fromList([4, 5, 6]),
      tag: 'background-lifecycle-regression',
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    var emittedFrames = 0;
    final listener = ImageStreamListener((info, _) {
      emittedFrames++;
      info.image.dispose();
    });

    stream.addListener(listener);
    await _waitUntil(() => emittedFrames >= 3);

    NativeAnimatedImageProvider.pauseAllAnimations();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final framesAtPause = emittedFrames;

    expect(created.difference(disposed), hasLength(1));
    expect(sources.first.releaseCount, 1);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(emittedFrames, framesAtPause);

    NativeAnimatedImageProvider.resumeAllAnimations();
    await _waitUntil(() => decodeCount >= 2 && emittedFrames > framesAtPause);

    stream.removeListener(listener);
    await provider.evict();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('加载期间暂停并恢复不会重复启动解码', () async {
    final decodeGate = Completer<void>();
    var decodeCount = 0;
    final source = _TestFrameSource();
    NativeAnimatedImageProvider.debugFrameSourceFactory = (_) async {
      decodeCount++;
      await decodeGate.future;
      return source;
    };

    final provider = NativeAnimatedImageProvider.memory(
      Uint8List.fromList([10, 11, 12]),
      tag: 'pause-while-loading-regression',
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    final firstFrame = Completer<void>();
    final listener = ImageStreamListener((info, _) {
      info.image.dispose();
      if (!firstFrame.isCompleted) firstFrame.complete();
    });

    stream.addListener(listener);
    await _waitUntil(() => decodeCount == 1);
    NativeAnimatedImageProvider.pauseAllAnimations();
    NativeAnimatedImageProvider.resumeAllAnimations();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(decodeCount, 1);

    decodeGate.complete();
    await firstFrame.future.timeout(const Duration(seconds: 3));
    stream.removeListener(listener);
    await provider.evict();
  });

  test('Rust 帧只在播放时逐帧复制，第一轮结束立即释放 handle', () async {
    final source = _TestFrameSource(
      delay: const Duration(milliseconds: 80),
    );
    NativeAnimatedImageProvider.debugFrameSourceFactory = (_) async => source;

    final provider = NativeAnimatedImageProvider.memory(
      Uint8List.fromList([7, 8, 9]),
      tag: 'lazy-native-frame-copy-regression',
    );
    final stream = provider.resolve(ImageConfiguration.empty);
    var emittedFrames = 0;
    final firstFrame = Completer<void>();
    final listener = ImageStreamListener((info, _) {
      emittedFrames++;
      info.image.dispose();
      if (!firstFrame.isCompleted) firstFrame.complete();
    });

    stream.addListener(listener);
    await firstFrame.future.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      source.copiedFrameIndices,
      hasLength(lessThanOrEqualTo(2)),
      reason: '首帧阶段最多允许当前帧 + 一帧预取，不能复制完整动画',
    );
    expect(source.releaseCount, 0);

    await _waitUntil(() => emittedFrames >= 3 && source.releaseCount == 1);
    expect(source.copiedFrameIndices, [0, 1, 2]);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(source.releaseCount, 1, reason: '循环播放不能重复释放 native handle');

    stream.removeListener(listener);
    await provider.evict();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(source.releaseCount, 1);
  });

  test('Rust 全帧路径只接收不超过 4 MiB RGBA 的小动图', () {
    final atLimit = _syntheticGif(width: 256, height: 256, frames: 16);
    final overLimit = _syntheticGif(width: 256, height: 256, frames: 17);

    expect(
      NativeAnimatedImageProvider.debugShouldUseNativeDecoder(atLimit),
      isTrue,
      reason: '4 MiB 边界内继续保留 Rust disposal 正确性路径',
    );
    expect(
      NativeAnimatedImageProvider.debugShouldUseNativeDecoder(overLimit),
      isFalse,
      reason: '超过 4 MiB 必须走流式 codec，不能全帧复制进 Dart heap',
    );
  });
}

class _TestFrameSource implements NativeAnimatedImageFrameSource {
  _TestFrameSource({
    this.delay = const Duration(milliseconds: 20),
  });

  final Duration delay;
  final List<int> copiedFrameIndices = [];
  int releaseCount = 0;

  @override
  int get width => 2;

  @override
  int get height => 2;

  @override
  int get loopCount => 0;

  @override
  int get frameCount => 3;

  @override
  Duration delayAt(int index) => delay;

  @override
  Uint8List copyFrameRgba(int index) {
    if (releaseCount != 0) {
      throw StateError('frame source has been released');
    }
    copiedFrameIndices.add(index);
    return Uint8List.fromList([
      for (var pixel = 0; pixel < 4; pixel++) ...[
        index == 0 ? 255 : 0,
        index == 1 ? 255 : 0,
        index == 2 ? 255 : 0,
        255,
      ],
    ]);
  }

  @override
  void release() {
    if (releaseCount == 0) releaseCount++;
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('等待动画状态变化超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Uint8List _syntheticGif({
  required int width,
  required int height,
  required int frames,
}) {
  final bytes = <int>[
    ...'GIF89a'.codeUnits,
    width & 0xff,
    width >> 8,
    height & 0xff,
    height >> 8,
    0,
    0,
    0,
  ];
  for (var i = 0; i < frames; i++) {
    bytes.addAll([
      0x2c,
      0,
      0,
      0,
      0,
      width & 0xff,
      width >> 8,
      height & 0xff,
      height >> 8,
      0,
      2,
      0,
    ]);
  }
  bytes.add(0x3b);
  return Uint8List.fromList(bytes);
}
