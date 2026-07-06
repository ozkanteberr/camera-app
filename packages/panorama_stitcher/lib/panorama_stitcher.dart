import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final DynamicLibrary _lib = Platform.isAndroid
    ? DynamicLibrary.open('libpanorama_stitcher.so')
    : DynamicLibrary.process();

typedef InitEngineC = Int32 Function();
typedef InitEngineDart = int Function();
final InitEngineDart initPanoramaEngine = _lib
    .lookup<NativeFunction<InitEngineC>>('init_panorama_engine')
    .asFunction();

typedef ClearFramesC = Void Function();
typedef ClearFramesDart = void Function();
final ClearFramesDart clearFrames = _lib
    .lookup<NativeFunction<ClearFramesC>>('clear_frames')
    .asFunction();

typedef AddFrameC = Int32 Function(
  Pointer<Uint8> imageBytes,
  Int32 width,
  Int32 height,
);
typedef AddFrameDart = int Function(
  Pointer<Uint8> imageBytes,
  int width,
  int height,
);
final AddFrameDart _addFrameC =
    _lib.lookup<NativeFunction<AddFrameC>>('add_frame').asFunction();

typedef AddEncodedFrameC = Int32 Function(
  Pointer<Uint8> imageBytes,
  Int32 length,
);
typedef AddEncodedFrameDart = int Function(
  Pointer<Uint8> imageBytes,
  int length,
);
final AddEncodedFrameDart _addEncodedFrameC = _lib
    .lookup<NativeFunction<AddEncodedFrameC>>('add_encoded_frame')
    .asFunction();

typedef ProcessPanoramaC = Int32 Function(
  Pointer<Pointer<Uint8>> outputImageBytes,
  Pointer<Int32> outWidth,
  Pointer<Int32> outHeight,
);
typedef ProcessPanoramaDart = int Function(
  Pointer<Pointer<Uint8>> outputImageBytes,
  Pointer<Int32> outWidth,
  Pointer<Int32> outHeight,
);
final ProcessPanoramaDart _processPanoramaC = _lib
    .lookup<NativeFunction<ProcessPanoramaC>>('process_panorama')
    .asFunction();

typedef FreePanoramaBufferC = Void Function(Pointer<Uint8> buffer);
typedef FreePanoramaBufferDart = void Function(Pointer<Uint8> buffer);
final FreePanoramaBufferDart _freePanoramaBufferC = _lib
    .lookup<NativeFunction<FreePanoramaBufferC>>('free_panorama_buffer')
    .asFunction();

class PanoramaStitcher {
  static int init() => initPanoramaEngine();

  static void clear() => clearFrames();

  static int addFrame(Uint8List bytes, int width, int height) {
    if (bytes.isEmpty || width <= 0 || height <= 0) return -1;

    final Pointer<Uint8> pointer = malloc<Uint8>(bytes.length);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      return _addFrameC(pointer, width, height);
    } finally {
      malloc.free(pointer);
    }
  }

  static int addEncodedFrame(Uint8List bytes) {
    if (bytes.isEmpty) return -1;

    final Pointer<Uint8> pointer = malloc<Uint8>(bytes.length);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      return _addEncodedFrameC(pointer, bytes.length);
    } finally {
      malloc.free(pointer);
    }
  }

  static Uint8List? process() {
    final Pointer<Pointer<Uint8>> outBytesPtr = calloc<Pointer<Uint8>>();
    final Pointer<Int32> outWidthPtr = calloc<Int32>();
    final Pointer<Int32> outHeightPtr = calloc<Int32>();

    final int size = _processPanoramaC(outBytesPtr, outWidthPtr, outHeightPtr);
    if (size <= 0) {
      calloc.free(outBytesPtr);
      calloc.free(outWidthPtr);
      calloc.free(outHeightPtr);
      return null;
    }

    final Pointer<Uint8> imgPointer = outBytesPtr.value;
    if (imgPointer == nullptr) {
      calloc.free(outBytesPtr);
      calloc.free(outWidthPtr);
      calloc.free(outHeightPtr);
      return null;
    }

    try {
      return Uint8List.fromList(imgPointer.asTypedList(size));
    } finally {
      _freePanoramaBufferC(imgPointer);
      calloc.free(outBytesPtr);
      calloc.free(outWidthPtr);
      calloc.free(outHeightPtr);
    }
  }
}