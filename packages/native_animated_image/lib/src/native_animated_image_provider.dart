/// [NativeAnimatedImageProvider] — Flutter [ImageProvider] that decodes
/// animated images (GIF / APNG / animated WebP) via the native Rust codec,
/// bypassing Flutter's built-in Skia multi-frame codec.
///
/// 用法:
///
/// ```dart
/// Image(image: NativeAnimatedImageProvider.memory(gifBytes))
/// Image(image: NativeAnimatedImageProvider.network('https://...'))
/// ```
///
/// 实现要点(参考成熟的 AvifImageProvider 模式):
/// - 单帧场景走 [OneFrameImageStreamCompleter] 快速路径
/// - 多帧场景用 `Timer` 调度帧切换,`hasListeners` 自动暂停/恢复
/// - 解码在 [Isolate.run] background isolate 中跑,避免阻塞 UI
/// - Rust 只保留原生帧，播放时才逐帧 copy RGBA → ui.Image；第一轮全部
///   转换完成后立即释放 native handle，见 [_LazyNativeFrameSequence]
/// - 超大动图(单帧 > [_kMaxNativeDecodePixels] 像素、或 RGBA 总量 >
///   [_kMaxNativeDecodeTotalBytes])不走 Rust 全帧 RGBA 路径 —— 那样
///   要么 UI 线程像素拷贝挤占帧预算,要么全帧解码打爆内存;改走
///   Flutter 内置 codec 流式解码(engine IO 线程解码并按体量缩放,
///   UI 线程零像素拷贝),见 [_CodecFrameSequence]。动图始终播放,
///   体量病态的用更小的解码尺寸([_kTightClampDimension])控制成本
/// - 并发解码限制(避免大量动图同屏解码导致内存峰值)
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'ffi/native_animated_image_bindings.dart' show kErrUnsupported;
import 'ffi/native_animated_image_ffi.dart';
import 'utils/semaphore.dart';

/// 限制全局并发解码数,避免多个大动图同时解导致 RAM 峰值
final _decodeSemaphore = AsyncSemaphore(3);

/// 单帧超过这个像素数(1024×1024,一帧 RGBA 4MB)就不走 Rust 全帧解码,
/// 降级到 Flutter 内置 codec 流式路径:
/// - UI 线程的单次同步像素拷贝(`ImmutableBuffer.fromUint8List`)与帧
///   像素量成正比,4MB 约 1~2ms,再大就开始挤占 120Hz 的 8.3ms 帧预算
///   (实测 2048² 阈值下单次拷贝可达 22ms);
/// - Rust 路径是全帧一次性解码,RGBA 会在 Dart heap 常驻到播完一轮,
///   帧多的大图轻松几百 MB,直接触发 GC 风暴。
const int _kMaxNativeDecodePixels = 1024 * 1024;

/// 降级路径的解码尺寸上限(最长边,等比缩放,不放大):内置 codec 流式
/// 播放每轮都要重新解码 + 上传纹理(raster 线程),纹理越大 raster 越痛
/// (实测 2048² 纹理反复上传可把 raster 单帧顶到 76ms)。1280 覆盖任何
/// 实际显示宽度,纹理 ≤6.5MB。
const int _kClampDimension = 1280;

/// Rust 解码的总体量上限(RGBA 字节 = width × height × 4 × 帧数):
/// Rust 路径仍会在 native 侧一次性解出所有帧,总量决定解码期峰值以及
/// 第一轮播放期间 native 帧与已生成 ui.Image 的重叠量。帧数巨大的动图
/// (实测案例:1200×800 × 612 帧 = 2.2GB),超过就走内置 codec 流式。
const int _kMaxNativeDecodeTotalBytes = 4 << 20;

/// 超量动图(RGBA 总量)进一步收紧解码分辨率的门槛:流式播放每轮
/// 循环重解码,CPU 与纹理带宽和总量成正比。产品决策是动图必须能动
/// (不做首帧静态降级),所以对体量病态的样本用更小的解码尺寸
/// ([_kTightClampDimension])换取可持续的解码/上传成本 —— 帖子里
/// 动图的实际显示宽度远小于这个值,视觉无损。
const int _kHugeAnimationTotalBytes = 256 << 20;

/// 超量动图的解码尺寸上限(最长边)
const int _kTightClampDimension = 800;

/// 字节源:bytes / network / file
abstract class _ByteSource {
  Future<Uint8List> load();

  /// 用于 ImageProvider key 相等性
  String get cacheKey;
}

class _MemorySource extends _ByteSource {
  _MemorySource(this.bytes, {required this.tag});

  final Uint8List bytes;
  final String tag;

  @override
  Future<Uint8List> load() async => bytes;

  @override
  String get cacheKey => 'memory:$tag';
}

class _NetworkSource extends _ByteSource {
  _NetworkSource(this.url, {this.headers});

  final String url;
  final Map<String, String>? headers;

  @override
  Future<Uint8List> load() async {
    // 默认实现:用 Flutter 的 NetworkImage 内部机制(HttpClient)
    // 高阶用户(如 fluxdo)应该走自己的 cacheManager,我们在外层提供
    // [NativeAnimatedImageProvider.fromBytesProvider] 让他们包装
    throw UnimplementedError(
      'NativeAnimatedImageProvider.network requires a custom byte loader. '
      'Use NativeAnimatedImageProvider.fromBytesProvider(...) instead, '
      'or wait for built-in HttpClient implementation in v0.2.',
    );
  }

  @override
  String get cacheKey => 'network:$url';
}

class _CustomSource extends _ByteSource {
  _CustomSource(this.loader, {required this.tag});

  final Future<Uint8List> Function() loader;
  final String tag;

  @override
  Future<Uint8List> load() => loader();

  @override
  String get cacheKey => 'custom:$tag';
}

/// Flutter [ImageProvider] implementation backed by the native Rust decoder.
class NativeAnimatedImageProvider
    extends ImageProvider<NativeAnimatedImageProvider> {
  NativeAnimatedImageProvider._(this._source, {this.scale = 1.0});

  /// 从已有的字节数据创建 provider。
  ///
  /// [tag] 用于 ImageProvider 相等性判断 —— 相同 tag 的 provider 会共享 Flutter 全局
  /// ImageCache 项。传一个稳定的标识符(如 url、hash、或资源 id)。
  factory NativeAnimatedImageProvider.memory(
    Uint8List bytes, {
    required String tag,
    double scale = 1.0,
  }) =>
      NativeAnimatedImageProvider._(_MemorySource(bytes, tag: tag),
          scale: scale);

  /// 从自定义 byte loader 创建 provider(适用于已有 cache_manager 的场景)。
  ///
  /// 这是最灵活的入口 —— 调用方决定从哪里(网络/文件/缓存)拉 bytes。
  factory NativeAnimatedImageProvider.fromBytesProvider({
    required Future<Uint8List> Function() loader,
    required String tag,
    double scale = 1.0,
  }) =>
      NativeAnimatedImageProvider._(_CustomSource(loader, tag: tag),
          scale: scale);

  /// (实验)从 URL 创建 provider。当前要求用户自己提供 byte loader,
  /// 见 [fromBytesProvider]。未来版本会内置 HttpClient 实现。
  factory NativeAnimatedImageProvider.network(
    String url, {
    Map<String, String>? headers,
    double scale = 1.0,
  }) =>
      NativeAnimatedImageProvider._(_NetworkSource(url, headers: headers),
          scale: scale);

  final _ByteSource _source;
  final double scale;

  /// 首帧产出的全局闸门 hook(宿主 app 可注入,默认 null = 行为不变)。
  ///
  /// Impeller 把"解码完成"与"纹理上传"绑在同一个任务里,提交进与
  /// raster 共用的 GPU 队列 —— 多张图同时挂载时首帧上传集中到达会顶出
  /// raster 大帧。宿主注入闸门(通常是全局信号量的 run 函数)后,
  /// **Rust 路径的首帧** RGBA→ui.Image 转换(纹理上传点)经由闸门执行,
  /// 与宿主其它图片管线统一错峰;**播放中的后续帧不过闸**,动画节奏
  /// 不受影响。
  ///
  /// 内置 codec 路径不走本 hook —— 它经由
  /// [PaintingBinding.instantiateImageCodecWithSize] 创建 codec,宿主若
  /// 在 binding 层做了闸门会自然覆盖;此处再套一层会造成同一信号量的
  /// 嵌套获取(死锁风险)。
  static Future<T> Function<T>(Future<T> Function() task)? firstFrameGate;

  static final Set<_NativeAnimatedImageStreamCompleter> _completers = {};
  static bool _animationsPaused = false;

  /// 暂停所有动画并释放 completer 内部持有的原始帧。
  ///
  /// 当前画面仍由 [ImageStreamCompleter] 保留最后一帧；调用
  /// [resumeAllAnimations] 后，有 listener 的动画会重新解码并继续播放。
  static void pauseAllAnimations() {
    _animationsPaused = true;
    for (final completer in List.of(_completers)) {
      completer.pauseAndReleaseFrames();
    }
  }

  /// 恢复被 [pauseAllAnimations] 暂停的动画。
  static void resumeAllAnimations() {
    _animationsPaused = false;
    for (final completer in List.of(_completers)) {
      completer.resumeIfListening();
    }
  }

  /// 测试专用帧源入口，避免 widget test 依赖平台动态库。
  @visibleForTesting
  static Future<NativeAnimatedImageFrameSource> Function(Uint8List bytes)?
      debugFrameSourceFactory;

  /// 测试/宿主诊断用：给定容器字节是否仍会进入 Rust 全帧 RGBA 路径。
  ///
  /// 这里只执行头部嗅探，不解码图片。
  @visibleForTesting
  static bool debugShouldUseNativeDecoder(Uint8List bytes) =>
      _shouldUseNativeDecoder(bytes, _sniffFrameBytes(bytes));

  @override
  Future<NativeAnimatedImageProvider> obtainKey(
      ImageConfiguration configuration) {
    return SynchronousFuture<NativeAnimatedImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    NativeAnimatedImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return _NativeAnimatedImageStreamCompleter(
      framesLoader: () => _loadAndDecode(key),
      scale: scale,
      debugLabel: _source.cacheKey,
    );
  }

  /// 从 byte source 加载 → isolate 内创建 Rust handle → 惰性帧序列
  ///
  /// 后台 isolate 只返回 handle + 元数据，不把全帧 RGBA 带回 Dart heap。
  /// 播放时才逐帧 copy 并转成 ui.Image，见 [_LazyNativeFrameSequence]。
  Future<_FrameSequence> _loadAndDecode(NativeAnimatedImageProvider key) async {
    await _decodeSemaphore.acquire();
    try {
      final bytes = await key._source.load();

      // 超大图前置分流:从文件头嗅探尺寸 + 帧数(GIF / PNG / WebP 的
      // 容器结构都能不解码地数出来),按单帧像素量与总解码体量分流。
      // 单帧超标 → UI 线程像素拷贝太贵;总量超标(单帧不大但帧数巨大,
      // 例 1200×800×612 帧 = 2.2GB)→ Rust 全帧解码直接打爆内存。
      // 两者都走内置 codec 流式播放;体量病态的用更小的解码尺寸。
      final frameBytes4 = _sniffFrameBytes(bytes);
      final totalBytes = frameBytes4?.totalBytes;

      // 静态图、单帧过大或全帧 RGBA 超过预算时走 engine 流式 codec。
      // Rust codec 自身把所有帧保存在 Vec<Frame>；把阈值压到 4 MiB，
      // 保证这条 correctness fallback 只服务小动图。Dart 侧现在只会
      // 按播放进度复制当前帧和下一帧，不再一次性灌入全部 RGBA。
      if (!_shouldUseNativeDecoder(bytes, frameBytes4)) {
        return _decodeViaFlutterCodec(
          bytes,
          clampDimension: _clampFor(totalBytes),
        );
      }

      // 主 isolate 先加载 dylib，确保后台 isolate 创建的进程级 registry
      // handle 在它退出后仍可由主 isolate 接管。
      // Rust 端只解动图(GIF / APNG / animated WebP / AVIF)+ animated AVIF
      // fallback;静态 WebP / 静态 PNG / 静态 GIF / JPEG 等会返
      // [kErrUnsupported] —— 这种情况 fallback 走 Flutter 内置 codec
      // (见 [_decodeViaFlutterCodec]),保证调用方拿到的 provider
      // 对任何主流图片格式都能出图,不需要在外层再 router。
      NativeAnimatedImageFrameSource? source;
      try {
        final testFactory = debugFrameSourceFactory;
        if (testFactory != null) {
          source = await testFactory(bytes);
        } else {
          final ffi = NativeAnimatedImageFfi.instance;
          ffi.prepare();
          final descriptor = await Isolate.run(
            () => NativeAnimatedImageFfi.instance.openHandle(bytes),
            debugName: 'NativeAnimatedImage.openHandle',
          );
          source = ffi.attachFrameSource(descriptor);
        }
      } on NativeAnimatedImageException catch (e) {
        if (e.code == kErrUnsupported) {
          // Rust 不识别的多为静态格式
          return _decodeViaFlutterCodec(
            bytes,
            clampDimension: _clampFor(totalBytes),
          );
        }
        rethrow;
      }

      // 双保险:嗅探失手(罕见容器变体)但实际解出了超标内容,同样降级,
      // 宁可浪费这次后台解码也不能把几十 MB/帧的拷贝压到 UI 线程、或把
      // GB 级的全帧 ui.Image 常驻进内存。
      final decodedPixels = source.width * source.height;
      final decodedTotal = decodedPixels * 4 * source.frameCount;
      if (decodedPixels > _kMaxNativeDecodePixels ||
          decodedTotal > _kMaxNativeDecodeTotalBytes) {
        source.release();
        return _decodeViaFlutterCodec(
          bytes,
          clampDimension: _clampFor(decodedTotal),
        );
      }

      try {
        return _LazyNativeFrameSequence(source);
      } catch (_) {
        source.release();
        rethrow;
      }
    } finally {
      _decodeSemaphore.release();
    }
  }

  /// 按总体量选择解码尺寸上限:体量未知或常规超标用 [_kClampDimension],
  /// 病态体量(几百 MB+)收紧到 [_kTightClampDimension]。
  static int _clampFor(int? totalBytes) {
    return totalBytes != null && totalBytes > _kHugeAnimationTotalBytes
        ? _kTightClampDimension
        : _kClampDimension;
  }

  /// 内置 codec 路径:Rust 不识别的格式(静态 webp/png/jpeg 等)的兜底,
  /// 以及超大动图的降级通道。
  ///
  /// 解码(含缩放)在 engine IO 线程按帧进行,UI 线程只有一次压缩字节的
  /// 拷贝(几百 KB 级,~1ms)。帧不预取不缓存,由 [_CodecFrameSequence]
  /// 播放时流式拉取 —— 一次性 getNextFrame 全帧常驻对大动图是内存炸弹。
  ///
  /// 静态格式在这条路上不会踩 multi_frame_codec 的 #85831 bug(那个 bug
  /// 只发生在多帧 disposal 路径);超大动图为了不卡 UI 接受这个权衡。
  static Future<_FrameSequence> _decodeViaFlutterCodec(
    Uint8List bytes, {
    required int clampDimension,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    // 经由 PaintingBinding 而非裸 ui.instantiateImageCodecWithSize:
    // 默认 binding 下二者完全等价;宿主 app 若覆写了 binding 的解码
    // 入口(如全局解码并发闸门),这条 fallback 路径(静态 webp/png/
    // jpeg + 超大动图降级)就能被统一纳管,而不是绕开宿主的调度。
    final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (int intrinsicWidth, int intrinsicHeight) {
        final longest = math.max(intrinsicWidth, intrinsicHeight);
        if (longest <= clampDimension) {
          return ui.TargetImageSize(
            width: intrinsicWidth,
            height: intrinsicHeight,
          );
        }
        final ratio = clampDimension / longest;
        return ui.TargetImageSize(
          width: (intrinsicWidth * ratio).round(),
          height: (intrinsicHeight * ratio).round(),
        );
      },
    );
    return _CodecFrameSequence(codec);
  }

  /// 把 RGBA Uint8List 转为 ui.Image(用 Flutter 的 decodeImageFromPixels,
  /// 它接受 raw pixel buffer,**不经过 Skia codec**,所以不会踩 multi_frame_codec bug)
  static Future<ui.Image> _rgbaToUiImage(
    Uint8List rgba,
    int width,
    int height,
  ) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    return completer.future;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NativeAnimatedImageProvider &&
        other._source.cacheKey == _source.cacheKey &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(_source.cacheKey, scale);

  @override
  String toString() =>
      'NativeAnimatedImageProvider(${_source.cacheKey}, scale: $scale)';
}

/// 单帧封装:ui.Image + 该帧 delay
class _RenderableFrame {
  _RenderableFrame({required this.image, required this.delay});

  final ui.Image image;
  final Duration delay;
}

/// 帧序列抽象:completer 按播放顺序取帧的统一入口
///
/// 顺序语义(而不是随机访问)是刻意的:内置 codec 只能顺序解码
/// ([_CodecFrameSequence]),而动画播放恰好是顺序 + 循环,两者天然匹配。
///
/// 两个实现:
/// - [_LazyNativeFrameSequence]:Rust handle,逐帧 copy RGBA → ui.Image
/// - [_CodecFrameSequence]:内置 codec 流式解码(fallback / 超大图降级)
abstract class _FrameSequence {
  int get frameCount;

  /// 取下一帧(播放推进,循环回绕由实现负责)。
  ///
  /// 返回的 frame 只保证在下一次 [nextFrame] 调用前有效;需要长期持有
  /// 必须 clone([_NativeAnimatedImageStreamCompleter] 的 setImage 就是
  /// clone 语义,天然满足)。
  Future<_RenderableFrame> nextFrame();

  /// 提示实现:提前准备下一帧(在当前帧的 delay 窗口里后台完成,
  /// 到点的 [nextFrame] 就能立即命中)。失败静默 —— [nextFrame] 会重试
  /// 并由调用方上报。
  void prefetchNext() {}

  /// 释放序列持有的原始帧、RGBA 数据和 codec。
  void dispose();
}

/// Rust 解码路径的惰性帧序列:播放到哪帧才从 native copy 哪帧
///
/// 收益(相对一次性全帧转换):
/// - 挂载时只需转第 1 帧(+预转 1 帧),后续转换摊到播放过程的帧间隙里;
///   快速滚过的动图只花 1-2 帧的转换成本
/// - Dart heap 不再在挂载时承接全帧 RGBA，只短暂持有正在转换的一帧
/// - 第一轮所有帧转换完成后立即释放 Rust handle
/// - 每帧只转换一次(永久缓存),循环播放第二轮起零成本,与旧行为一致
class _LazyNativeFrameSequence implements _FrameSequence {
  _LazyNativeFrameSequence(NativeAnimatedImageFrameSource source)
      : _source = source,
        _width = source.width,
        _height = source.height,
        frameCount = source.frameCount,
        _delays = [
          for (var index = 0; index < source.frameCount; index++)
            source.delayAt(index),
        ],
        _converted = List<_RenderableFrame?>.filled(source.frameCount, null);

  NativeAnimatedImageFrameSource? _source;

  final int _width;
  final int _height;

  @override
  final int frameCount;

  final List<Duration> _delays;

  /// 已转换的帧(永久缓存)
  final List<_RenderableFrame?> _converted;

  /// 转换中的帧,避免 [nextFrame] 与 [prefetchNext] 对同一帧重复转换
  final Map<int, Future<_RenderableFrame>> _pending = {};

  /// 下一次 [nextFrame] 要交付的帧号
  int _cursor = 0;
  int _convertedCount = 0;
  bool _disposed = false;

  @override
  Future<_RenderableFrame> nextFrame() {
    if (_disposed) {
      return Future.error(StateError('Frame sequence has been disposed'));
    }
    final index = _cursor;
    _cursor = (_cursor + 1) % frameCount;
    return _frameAt(index);
  }

  @override
  void prefetchNext() {
    if (_disposed) return;
    unawaited(_frameAt(_cursor)
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
  }

  Future<_RenderableFrame> _frameAt(int index) {
    if (_disposed) {
      return Future.error(StateError('Frame sequence has been disposed'));
    }
    final cached = _converted[index];
    if (cached != null) {
      return SynchronousFuture<_RenderableFrame>(cached);
    }
    return _pending.putIfAbsent(index, () => _convert(index));
  }

  Future<_RenderableFrame> _convert(int index) async {
    try {
      // 让出一个完整 event loop turn(microtask 让步不够):像素拷贝是
      // 同步 FFI,不让步的话同屏多个动图的转换会在同一个 turn 里连续
      // 执行,重新把 UI 线程占满;隔开后 vsync / 触摸事件能插进来。
      await Future<void>.delayed(Duration.zero);
      if (_disposed) {
        throw StateError('Frame sequence has been disposed');
      }
      final source = _source;
      if (source == null) {
        throw StateError('Frame source has already been released');
      }
      final rgba = source.copyFrameRgba(index);
      Future<ui.Image> produce() => NativeAnimatedImageProvider._rgbaToUiImage(
            rgba,
            _width,
            _height,
          );
      // 首帧(挂载瞬态,多图同屏时上传集中到达)过宿主注入的全局
      // 闸门错峰;后续帧在播放节奏里逐帧到来,天然稀疏,不过闸。
      final gate = NativeAnimatedImageProvider.firstFrameGate;
      final image =
          (index == 0 && gate != null) ? await gate(produce) : await produce();
      if (_disposed) {
        image.dispose();
        throw StateError('Frame sequence has been disposed');
      }
      final frame = _RenderableFrame(image: image, delay: _delays[index]);
      _converted[index] = frame;
      _convertedCount++;
      if (_convertedCount == frameCount) {
        _releaseSource();
      }
      return frame;
    } finally {
      // 成功后 _frameAt 走 _converted 缓存;失败后允许下次重试
      _pending.remove(index);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (var index = 0; index < _converted.length; index++) {
      _converted[index]?.image.dispose();
      _converted[index] = null;
    }
    _releaseSource();
  }

  void _releaseSource() {
    final source = _source;
    if (source == null) return;
    _source = null;
    source.release();
  }
}

/// 内置 codec 的流式帧序列:帧不缓存,播放到哪解到哪
///
/// 解码(含降采样)发生在 engine IO 线程,UI 线程零像素拷贝 —— 超大
/// 动图的唯一可行姿势。代价是循环播放每一轮都重新解码(CPU 换内存,
/// 与 Flutter 自带 [MultiFrameImageStreamCompleter] 的行为一致)。
///
/// [ui.Codec.getNextFrame] 播放到末帧后自动回绕,与 [_FrameSequence]
/// 的顺序语义直接对齐。
class _CodecFrameSequence implements _FrameSequence {
  _CodecFrameSequence(this._codec) : frameCount = _codec.frameCount;

  final ui.Codec _codec;

  @override
  final int frameCount;

  /// 预取中/已预取还未被消费的帧
  Future<_RenderableFrame>? _prefetched;

  /// 上一次交付出去的帧:下一次推进时 dispose(那时它的 clone 早已上屏)
  ui.Image? _lastDelivered;

  /// 单帧图在首次取帧后就再也用不到 codec 了
  bool _disposed = false;
  bool _codecDisposed = false;
  int _inFlight = 0;

  @override
  Future<_RenderableFrame> nextFrame() {
    if (_disposed) {
      return Future.error(StateError('Frame sequence has been disposed'));
    }
    final pending = _prefetched ?? _advance();
    _prefetched = null;
    return pending;
  }

  @override
  void prefetchNext() {
    if (_disposed) return;
    _prefetched ??= _advance();
    unawaited(_prefetched!
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
  }

  Future<_RenderableFrame> _advance() async {
    if (_disposed) {
      throw StateError('Frame sequence has been disposed');
    }
    _inFlight++;
    try {
      final info = await _codec.getNextFrame();
      if (_disposed) {
        info.image.dispose();
        throw StateError('Frame sequence has been disposed');
      }
      _lastDelivered?.dispose();
      _lastDelivered = info.image;
      if (frameCount <= 1) {
        // 静态图:一帧定格,codec 可以立刻释放；原始 image 仍由序列持有，
        // 等 listener 归零时统一释放。
        _disposeCodec();
      }
      return _RenderableFrame(image: info.image, delay: info.duration);
    } finally {
      _inFlight--;
      if (_disposed && _inFlight == 0) {
        _disposeCodec();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _prefetched = null;
    _lastDelivered?.dispose();
    _lastDelivered = null;
    if (_inFlight == 0) {
      _disposeCodec();
    }
  }

  void _disposeCodec() {
    if (_codecDisposed) return;
    _codecDisposed = true;
    _codec.dispose();
  }
}

bool _shouldUseNativeDecoder(
  Uint8List bytes,
  ({({int width, int height, int? frames}) info, int? totalBytes})? frameBytes4,
) {
  final sniffed = frameBytes4?.info;
  if (_isDefinitelyStaticImage(bytes, sniffed?.frames)) return false;
  if (sniffed == null) return true;
  final pixels = sniffed.width * sniffed.height;
  final totalBytes = frameBytes4?.totalBytes;
  return pixels <= _kMaxNativeDecodePixels &&
      (totalBytes == null || totalBytes <= _kMaxNativeDecodeTotalBytes);
}

/// 嗅探尺寸与帧数并折算 RGBA 总体量。
///
/// 帧计数上限取"足以判定 [_kHugeAnimationTotalBytes]"的帧数 —— 病态
/// 样本(几百帧)只需扫到上限即停,嗅探成本与阈值成正比而不是与
/// 文件帧数成正比。frames 未知(非动图容器 / 结构异常)时
/// totalBytes 为 null,交由 Rust 解码后的双保险兜底。
({({int width, int height, int? frames}) info, int? totalBytes})?
    _sniffFrameBytes(Uint8List bytes) {
  // 先只读尺寸(帧数上限依赖单帧体量)
  final probe = _sniffImageSize(bytes, frameCountLimit: 1);
  if (probe == null) return null;
  final frameBytes = probe.width * probe.height * 4;
  if (frameBytes <= 0) return (info: probe, totalBytes: null);
  final limit = _kHugeAnimationTotalBytes ~/ frameBytes + 2;
  final info = _sniffImageSize(bytes, frameCountLimit: limit)!;
  final frames = info.frames;
  return (
    info: info,
    totalBytes: frames == null ? null : frameBytes * frames,
  );
}

/// 从文件头嗅探图片像素尺寸与帧数,拿不准就返回 null(交给正常解码路径)。
///
/// 只覆盖会走 Rust 解码的三种容器 —— GIF / PNG(含 APNG)/ WebP。
/// 尺寸躺在头部固定偏移上;帧数通过遍历容器块结构获得(不解码像素),
/// 并以 [frameCountLimit] 为上限提前终止 —— 判断体量阈值只需要知道
/// "至少有多少帧",病态样本(600+ 帧)也只扫到上限即停。
({int width, int height, int? frames})? _sniffImageSize(
  Uint8List b, {
  int frameCountLimit = 1 << 30,
}) {
  if (b.length < 10) return null;
  // GIF87a / GIF89a
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
    final w = b[6] | (b[7] << 8);
    final h = b[8] | (b[9] << 8);
    return (width: w, height: h, frames: _countGifFrames(b, frameCountLimit));
  }
  // PNG / APNG:\x89PNG\r\n\x1a\n + IHDR
  if (b.length >= 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    return (width: w, height: h, frames: _countApngFrames(b));
  }
  // RIFF....WEBP + VP8X
  if (b.length >= 30 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50 &&
      b[12] == 0x56 &&
      b[13] == 0x50 &&
      b[14] == 0x38 &&
      b[15] == 0x58) {
    final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
    final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
    return (
      width: w,
      height: h,
      frames: _countWebpFrames(b, frameCountLimit),
    );
  }
  return null;
}

/// 从容器头判定"**确定**是静态图"(拿不准一律返回 false,交给 Rust
/// 正常路径,决不误伤动图):
/// - 简单 webp(chunk 直接是 `VP8 `/`VP8L`,无 VP8X 扩展):规格上
///   不可能携带动画
/// - VP8X webp:flags 的 ANIM 位(0x02)为 0
/// - PNG:acTL 缺失([_countApngFrames] 返回 1)
///
/// GIF 不在此判定(静态 GIF 罕见,Rust 端本来就能解,不值得引入
/// 误判风险)。
bool _isDefinitelyStaticImage(Uint8List b, int? sniffedFrames) {
  // RIFF....WEBP
  if (b.length >= 21 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50 &&
      b[12] == 0x56 &&
      b[13] == 0x50 &&
      b[14] == 0x38) {
    // 'VP8 ' (lossy) / 'VP8L' (lossless):无 VP8X = 必静态
    if (b[15] == 0x20 || b[15] == 0x4C) return true;
    // 'VP8X':byte 20 是 flags,ANIM 位 0x02
    if (b[15] == 0x58 && (b[20] & 0x02) == 0) return true;
    return false;
  }
  // PNG:嗅探已遍历 chunk,acTL 缺失时帧数为 1
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && sniffedFrames == 1) {
    return true;
  }
  return false;
}

/// 遍历 GIF block 结构数 image descriptor(0x2C),最多数到 [limit]。
/// 结构异常时返回已数到的帧数(>0)或 null。
int? _countGifFrames(Uint8List b, int limit) {
  if (b.length < 14) return null;
  var i = 13;
  final packed = b[10];
  if (packed & 0x80 != 0) i += 3 * (2 << (packed & 7)); // 全局色表
  var frames = 0;
  while (i < b.length && frames < limit) {
    final c = b[i];
    if (c == 0x3B) break; // trailer
    if (c == 0x21) {
      // extension: 跳过标签 + 子块链
      i += 2;
      while (i < b.length && b[i] != 0) {
        i += b[i] + 1;
      }
      i += 1;
    } else if (c == 0x2C) {
      // image descriptor
      frames++;
      i += 9;
      if (i >= b.length) break;
      final p = b[i];
      i += 1;
      if (p & 0x80 != 0) i += 3 * (2 << (p & 7)); // 局部色表
      i += 1; // LZW min code size
      while (i < b.length && b[i] != 0) {
        i += b[i] + 1;
      }
      i += 1;
    } else {
      return frames > 0 ? frames : null;
    }
  }
  return frames > 0 ? frames : null;
}

/// PNG chunk 遍历找 acTL(APNG 动画控制块,位于 IDAT 之前),
/// 返回其 num_frames;没有 acTL 的静态 PNG 返回 1。
int? _countApngFrames(Uint8List b) {
  var i = 8;
  while (i + 8 <= b.length) {
    final len = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
    final t0 = b[i + 4], t1 = b[i + 5], t2 = b[i + 6], t3 = b[i + 7];
    if (t0 == 0x61 && t1 == 0x63 && t2 == 0x54 && t3 == 0x4C) {
      // acTL
      if (i + 12 > b.length) return null;
      return (b[i + 8] << 24) | (b[i + 9] << 16) | (b[i + 10] << 8) | b[i + 11];
    }
    // IDAT / IEND:acTL 必在其前,到这还没有就是静态 PNG
    if ((t0 == 0x49 && t1 == 0x44 && t2 == 0x41 && t3 == 0x54) ||
        (t0 == 0x49 && t1 == 0x45 && t2 == 0x4E && t3 == 0x44)) {
      return 1;
    }
    i += 12 + len;
  }
  return null;
}

/// RIFF chunk 遍历数 ANMF(动画帧),最多数到 [limit]。
int? _countWebpFrames(Uint8List b, int limit) {
  var i = 12;
  var frames = 0;
  while (i + 8 <= b.length && frames < limit) {
    final isAnmf = b[i] == 0x41 &&
        b[i + 1] == 0x4E &&
        b[i + 2] == 0x4D &&
        b[i + 3] == 0x46;
    final len =
        b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24);
    if (isAnmf) frames++;
    i += 8 + len + (len & 1);
  }
  return frames > 0 ? frames : null;
}

/// 多帧动画的 [ImageStreamCompleter] —— Timer 调度 + hasListeners 暂停
///
/// 100% 参考 fluxdo 的 _AvifAnimatedImageStreamCompleter 模式,经过项目实战验证。
///
/// 帧的取用走 [_FrameSequence.nextFrame](顺序惰性):显示当前帧时通过
/// [_FrameSequence.prefetchNext] 预备下一帧,Timer 到点后基本都能立即
/// 命中,动画节奏不受转换/解码影响。
class _NativeAnimatedImageStreamCompleter extends ImageStreamCompleter {
  _NativeAnimatedImageStreamCompleter({
    required Future<_FrameSequence> Function() framesLoader,
    required this.scale,
    String? debugLabel,
  }) : _framesLoader = framesLoader {
    this.debugLabel = debugLabel;
    NativeAnimatedImageProvider._completers.add(this);
  }

  final Future<_FrameSequence> Function() _framesLoader;
  final double scale;
  Future<_FrameSequence>? _loading;
  _FrameSequence? _sequence;
  Timer? _timer;

  /// [_emit] 里取帧可能真异步:挡住 await 期间 addListener 恢复动画
  /// 造成的重入(双 Timer / 跳帧)
  bool _emitting = false;

  void _ensureSequence() {
    if (!hasListeners ||
        NativeAnimatedImageProvider._animationsPaused ||
        _sequence != null ||
        _loading != null) {
      return;
    }
    final loading = _framesLoader();
    _loading = loading;
    loading.then(
      (sequence) {
        if (!identical(_loading, loading)) {
          sequence.dispose();
          return;
        }
        _loading = null;
        if (!hasListeners || NativeAnimatedImageProvider._animationsPaused) {
          sequence.dispose();
          return;
        }
        _handleSequenceLoaded(sequence);
      },
      onError: (Object error, StackTrace stack) {
        if (!identical(_loading, loading)) return;
        _loading = null;
        if (!hasListeners) return;
        reportError(
          context: ErrorDescription(
            'Failed to decode animated image (label: $debugLabel)',
          ),
          exception: error,
          stack: stack,
          silent: false,
        );
      },
    );
  }

  void _handleSequenceLoaded(_FrameSequence sequence) {
    if (sequence.frameCount == 0) {
      sequence.dispose();
      reportError(
        context: ErrorDescription('Decoded animated image has zero frames'),
        exception: Exception('Empty frames'),
        stack: StackTrace.current,
      );
      return;
    }
    _sequence = sequence;
    unawaited(_emit());
  }

  /// 输出下一帧;多帧时预转并调度后续帧
  Future<void> _emit() async {
    final sequence = _sequence;
    if (sequence == null || _emitting) return;

    // 没有 listener 时暂停(节省 CPU,也停掉后续帧的转换/解码)
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
      return;
    }

    _emitting = true;
    try {
      final _RenderableFrame frame;
      try {
        frame = await sequence.nextFrame();
      } catch (error, stack) {
        if (!identical(sequence, _sequence) || !hasListeners) {
          return;
        }
        reportError(
          context: ErrorDescription(
            'Failed to obtain animated image frame (label: $debugLabel)',
          ),
          exception: error,
          stack: stack,
          silent: false,
        );
        return;
      }

      // nextFrame 真异步时,await 期间 listener 可能已全部移除
      if (!hasListeners || !identical(sequence, _sequence)) {
        _timer?.cancel();
        _timer = null;
        return;
      }

      // ui.Image 是引用计数的,emit 时 clone 一份给 listener(避免被 cache 清掉时影响显示)
      setImage(ImageInfo(image: frame.image.clone(), scale: scale));

      if (sequence.frameCount > 1) {
        final delay = frame.delay.inMilliseconds > 0
            ? frame.delay
            : const Duration(milliseconds: 100);
        // 预备下一帧,在 delay 窗口里后台完成,到点即取即显
        sequence.prefetchNext();
        _timer?.cancel();
        _timer = Timer(delay, () => unawaited(_emit()));
      }
    } finally {
      _emitting = false;
      if (hasListeners &&
          _timer == null &&
          _sequence != null &&
          !identical(sequence, _sequence)) {
        unawaited(_emit());
      }
    }
  }

  @override
  void addListener(ImageStreamListener listener) {
    final hadListeners = hasListeners;
    super.addListener(listener);
    if (!hadListeners) {
      if (_sequence == null) {
        _ensureSequence();
      } else if (_sequence!.frameCount > 1 && _timer == null) {
        unawaited(_emit());
      }
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _releaseFrames();
    }
  }

  void pauseAndReleaseFrames() {
    _releaseFrames();
  }

  void resumeIfListening() {
    _ensureSequence();
  }

  void _releaseFrames() {
    _timer?.cancel();
    _timer = null;
    // Future 无法取消；保留正在进行的 loader，避免 pause/resume 时重复启动
    // 同一解码。完成回调会按当时的监听/暂停状态接管或释放结果。
    _sequence?.dispose();
    _sequence = null;
  }

  @override
  void onDisposed() {
    _releaseFrames();
    NativeAnimatedImageProvider._completers.remove(this);
    super.onDisposed();
  }
}
