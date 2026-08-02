/// High-level FFI wrapper around `native_animated_image_codec`.
///
/// 提供两层 API:
/// - [openHandle] 只返回 Rust handle + 元数据,帧在播放时逐帧 copy;
/// - [decode] 保留旧的全帧 copy 兼容接口,不再供 provider 热路径使用。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_animated_image_bindings.dart';

/// 解码后的动图(全帧 RGBA + 元数据)
class DecodedAnimatedImage {
  DecodedAnimatedImage({
    required this.width,
    required this.height,
    required this.loopCount,
    required this.frames,
  });

  /// 画布宽度(像素)
  final int width;

  /// 画布高度(像素)
  final int height;

  /// 循环次数:0 = 无限循环, N = 播放 N+1 次
  final int loopCount;

  /// 所有帧(已按 disposal/transparency 合成全尺寸 RGBA)
  final List<AnimatedFrame> frames;
}

class AnimatedFrame {
  AnimatedFrame({required this.rgba, required this.delay});

  /// 全尺寸 RGBA 数据(已 copy 出来,长度 = width * height * 4)
  final Uint8List rgba;

  /// 该帧的展示时长
  final Duration delay;
}

/// provider 播放 Rust 动画所需的最小帧源接口。
///
/// 一次只把指定帧 copy 到 Dart heap；[release] 必须幂等。
abstract interface class NativeAnimatedImageFrameSource {
  int get width;
  int get height;
  int get loopCount;
  int get frameCount;

  Duration delayAt(int index);
  Uint8List copyFrameRgba(int index);
  void release();
}

/// 可跨 isolate 传递的 Rust handle 描述。
///
/// 这里只包含整数和 `List<int>`。创建 handle 的后台 isolate 返回后，主 isolate
/// 通过 [NativeAnimatedImageFfi.attachFrameSource] 接管其生命周期。
class NativeAnimatedImageHandleDescriptor {
  NativeAnimatedImageHandleDescriptor({
    required this.handle,
    required this.width,
    required this.height,
    required this.loopCount,
    required List<int> frameDelaysMs,
  }) : frameDelaysMs = List<int>.unmodifiable(frameDelaysMs);

  final int handle;
  final int width;
  final int height;
  final int loopCount;
  final List<int> frameDelaysMs;
}

class NativeAnimatedImageHandle implements NativeAnimatedImageFrameSource {
  NativeAnimatedImageHandle._(
    this._owner,
    this._descriptor,
  ) {
    _finalizer.attach(
      this,
      _HandleFinalizerToken(_owner, _descriptor.handle),
      detach: this,
    );
  }

  static final Finalizer<_HandleFinalizerToken> _finalizer =
      Finalizer<_HandleFinalizerToken>((token) {
    token.owner._releaseHandle(token.handle);
  });

  final NativeAnimatedImageFfi _owner;
  final NativeAnimatedImageHandleDescriptor _descriptor;
  bool _released = false;

  @override
  int get width => _descriptor.width;

  @override
  int get height => _descriptor.height;

  @override
  int get loopCount => _descriptor.loopCount;

  @override
  int get frameCount => _descriptor.frameDelaysMs.length;

  @override
  Duration delayAt(int index) =>
      Duration(milliseconds: _descriptor.frameDelaysMs[index]);

  @override
  Uint8List copyFrameRgba(int index) {
    if (_released) {
      throw StateError('Native animated image handle has been released');
    }
    return _owner._readFrameRgba(_descriptor.handle, index);
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    _finalizer.detach(this);
    _owner._releaseHandle(_descriptor.handle);
  }
}

class _HandleFinalizerToken {
  _HandleFinalizerToken(this.owner, this.handle);

  final NativeAnimatedImageFfi owner;
  final int handle;
}

/// FFI 异常
class NativeAnimatedImageException implements Exception {
  NativeAnimatedImageException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() =>
      'NativeAnimatedImageException(code=$code, message=$message)';
}

/// FFI singleton — 懒加载 binary 并 cache 函数指针
class NativeAnimatedImageFfi {
  NativeAnimatedImageFfi._();
  static final NativeAnimatedImageFfi instance = NativeAnimatedImageFfi._();

  DynamicLibrary? _lib;
  NativeDecode? _decode;
  NativeGetMetadataJson? _getMetadataJson;
  NativeGetFrameRgba? _getFrameRgba;
  NativeRelease? _release;
  NativeFreeString? _freeString;
  NativeVersion? _version;

  void _ensureLoaded() {
    if (_lib != null) return;
    final lib = loadNativeAnimatedImageCodec();
    _decode = lookupDecode(lib);
    _getMetadataJson = lookupGetMetadataJson(lib);
    _getFrameRgba = lookupGetFrameRgba(lib);
    _release = lookupRelease(lib);
    _freeString = lookupFreeString(lib);
    _version = lookupVersion(lib);
    _lib = lib; // 最后赋值 _lib,确保上述 lookup 全部成功后才认为 loaded
  }

  /// 在主 isolate 预加载动态库。
  ///
  /// Rust handle 可由后台 isolate 创建，但主 isolate 必须保持同一 dylib
  /// 映射存活，随后才能逐帧读取该进程级 registry 中的 handle。
  void prepare() => _ensureLoaded();

  /// 返回 native binary 的版本字符串(如 "0.1.0")
  String version() {
    _ensureLoaded();
    final ptr = _version!();
    if (ptr == nullptr) return 'unknown';
    return ptr.toDartString();
  }

  /// 解码动图字节流,返回完整解码结果。
  ///
  /// 该方法把 Rust handle 的整个生命周期封装在内部:
  ///   1. 调 `native_animated_image_decode` 拿 handle
  ///   2. 调 `get_metadata_json` 拿元数据
  ///   3. 对每一帧调 `get_frame_rgba` 拿 RGBA 指针 → copy 到 dart 端 Uint8List
  ///   4. 调 `native_animated_image_release` 释放 handle
  ///
  /// 即使中间抛异常也会保证 release(try/finally)。
  ///
  /// Throws [NativeAnimatedImageException] on decode failure.
  DecodedAnimatedImage decode(Uint8List bytes) {
    final descriptor = openHandle(bytes);
    final source = attachFrameSource(descriptor);
    try {
      final frames = <AnimatedFrame>[];
      for (var i = 0; i < source.frameCount; i++) {
        frames.add(
          AnimatedFrame(
            rgba: source.copyFrameRgba(i),
            delay: source.delayAt(i),
          ),
        );
      }
      return DecodedAnimatedImage(
        width: source.width,
        height: source.height,
        loopCount: source.loopCount,
        frames: frames,
      );
    } finally {
      source.release();
    }
  }

  /// 解码压缩字节，但不把任何 RGBA 帧 copy 到 Dart heap。
  ///
  /// 成功返回的 descriptor 拥有一个 Rust registry handle。调用方必须在
  /// 主 isolate 用 [attachFrameSource] 接管；本方法在任何失败路径都会
  /// 自动 release 已创建的 handle。
  NativeAnimatedImageHandleDescriptor openHandle(Uint8List bytes) {
    _ensureLoaded();

    if (bytes.isEmpty) {
      throw NativeAnimatedImageException(kErrInvalid, 'empty input bytes');
    }

    // 1. 把 dart bytes 拷到 native 堆,调 decode
    final inputPtr = malloc<Uint8>(bytes.length);
    final inputBytes = inputPtr.asTypedList(bytes.length);
    inputBytes.setAll(0, bytes);

    final outHandlePtr = malloc<Uint64>();
    int handle = 0;

    try {
      final rc = _decode!(inputPtr, bytes.length, outHandlePtr);
      if (rc != kErrOk) {
        throw NativeAnimatedImageException(rc, _errorMessageFor(rc));
      }
      handle = outHandlePtr.value;
      if (handle == 0) {
        throw NativeAnimatedImageException(
          kErrDecode,
          'decode returned 0 handle',
        );
      }

      // 2. 只拿元数据；帧在 provider 播放时按需 copy。
      final metadata = _readMetadata(handle);
      if (metadata.frameCount <= 0 ||
          metadata.frames.length != metadata.frameCount) {
        throw NativeAnimatedImageException(
          kErrDecode,
          'invalid frame metadata',
        );
      }
      final descriptor = NativeAnimatedImageHandleDescriptor(
        handle: handle,
        width: metadata.width,
        height: metadata.height,
        loopCount: metadata.loopCount,
        frameDelaysMs: [
          for (final frame in metadata.frames) frame.delayMs,
        ],
      );
      handle = 0; // descriptor 接管所有权
      return descriptor;
    } finally {
      // descriptor 创建前的任何异常都必须释放 handle。
      if (handle != 0) {
        _release!(handle);
      }
      malloc.free(outHandlePtr);
      malloc.free(inputPtr);
    }
  }

  /// 在当前 isolate 接管 [openHandle] 返回的 handle。
  NativeAnimatedImageHandle attachFrameSource(
    NativeAnimatedImageHandleDescriptor descriptor,
  ) {
    _ensureLoaded();
    if (descriptor.handle == 0 ||
        descriptor.width <= 0 ||
        descriptor.height <= 0 ||
        descriptor.frameDelaysMs.isEmpty) {
      if (descriptor.handle != 0) {
        _releaseHandle(descriptor.handle);
      }
      throw NativeAnimatedImageException(
        kErrDecode,
        'invalid native handle descriptor',
      );
    }
    return NativeAnimatedImageHandle._(this, descriptor);
  }

  void _releaseHandle(int handle) {
    _ensureLoaded();
    _release!(handle);
  }

  /// 读 metadata JSON 并解析
  _Metadata _readMetadata(int handle) {
    final ptr = _getMetadataJson!(handle);
    if (ptr == nullptr) {
      throw NativeAnimatedImageException(
        kErrDecode,
        'get_metadata_json returned null',
      );
    }
    try {
      final jsonStr = ptr.toDartString();
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      return _Metadata.fromJson(parsed);
    } finally {
      _freeString!(ptr);
    }
  }

  /// 读某帧 RGBA 数据(从 native 指针 copy 到 dart Uint8List)
  Uint8List _readFrameRgba(int handle, int frameIdx) {
    final outPtr = malloc<Pointer<Uint8>>();
    final outLen = malloc<IntPtr>();
    try {
      final rc = _getFrameRgba!(handle, frameIdx, outPtr, outLen);
      if (rc != kErrOk) {
        throw NativeAnimatedImageException(rc, _errorMessageFor(rc));
      }
      final ptr = outPtr.value;
      final len = outLen.value;
      if (ptr == nullptr || len == 0) {
        throw NativeAnimatedImageException(
          kErrDecode,
          'get_frame_rgba returned null/empty pointer',
        );
      }
      // 这里必须 copy(Uint8List.fromList 或 .asTypedList(...).sublist 都行)
      // 因为 ptr 指向的 native 内存归 handle 所有,我们 release handle 后就失效
      return Uint8List.fromList(ptr.asTypedList(len));
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }

  static String _errorMessageFor(int code) {
    switch (code) {
      case kErrInvalid:
        return 'invalid input';
      case kErrUnsupported:
        return 'unsupported format';
      case kErrDecode:
        return 'decode error';
      case kErrHandleNotFound:
        return 'handle not found';
      case kErrFrameOor:
        return 'frame index out of range';
      case kErrPanic:
        return 'decoder panicked (malformed input)';
      default:
        return 'unknown error';
    }
  }
}

class _Metadata {
  _Metadata({
    required this.width,
    required this.height,
    required this.loopCount,
    required this.frameCount,
    required this.frames,
  });

  factory _Metadata.fromJson(Map<String, dynamic> json) {
    final frames = (json['frames'] as List<dynamic>)
        .map((e) => _FrameMeta.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return _Metadata(
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      loopCount: (json['loop_count'] as num).toInt(),
      frameCount: (json['frame_count'] as num).toInt(),
      frames: frames,
    );
  }

  final int width;
  final int height;
  final int loopCount;
  final int frameCount;
  final List<_FrameMeta> frames;
}

class _FrameMeta {
  _FrameMeta({required this.delayMs});

  factory _FrameMeta.fromJson(Map<String, dynamic> json) {
    return _FrameMeta(delayMs: (json['delay_ms'] as num).toInt());
  }

  final int delayMs;
}
