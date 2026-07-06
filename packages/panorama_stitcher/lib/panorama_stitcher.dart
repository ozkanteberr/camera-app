import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// 1. KÜTÜPHANEYİ YÜKLEME
// Android'de derlenmiş C++ kodlarımız '.so' uzantılı bir kütüphane dosyası olur.
// İşletim sistemine göre bu dosyayı belleğe yüklüyoruz.
final DynamicLibrary _lib = Platform.isAndroid
    ? DynamicLibrary.open('libpanorama_stitcher.so')
    : DynamicLibrary.process();

// 2. FONKSİYON TANIMLAMALARI (C++ Tipleri -> Dart Tipleri)

// init_panorama_engine()
typedef InitEngineC = Int32 Function();
typedef InitEngineDart = int Function();
final InitEngineDart initPanoramaEngine = _lib
    .lookup<NativeFunction<InitEngineC>>('init_panorama_engine')
    .asFunction();

// clear_frames()
typedef ClearFramesC = Void Function();
typedef ClearFramesDart = void Function();
final ClearFramesDart clearFrames = _lib
    .lookup<NativeFunction<ClearFramesC>>('clear_frames')
    .asFunction();

// add_frame()
typedef AddFrameC =
    Int32 Function(Pointer<Uint8> image_bytes, Int32 width, Int32 height);
typedef AddFrameDart =
    int Function(Pointer<Uint8> image_bytes, int width, int height);
final AddFrameDart _addFrameC = _lib
    .lookup<NativeFunction<AddFrameC>>('add_frame')
    .asFunction();

typedef AddEncodedFrameC = Int32 Function(Pointer<Uint8> imageBytes, Int32 length);
typedef AddEncodedFrameDart = int Function(Pointer<Uint8> imageBytes, int length);
final AddEncodedFrameDart _addEncodedFrameC = _lib
    .lookup<NativeFunction<AddEncodedFrameC>>('add_encoded_frame')
    .asFunction();

// process_panorama()
typedef ProcessPanoramaC =
    Int32 Function(
      Pointer<Pointer<Uint8>> output_image_bytes,
      Pointer<Int32> out_width,
      Pointer<Int32> out_height,
    );
typedef ProcessPanoramaDart =
    int Function(
      Pointer<Pointer<Uint8>> output_image_bytes,
      Pointer<Int32> out_width,
      Pointer<Int32> out_height,
    );
final ProcessPanoramaDart _processPanoramaC = _lib
    .lookup<NativeFunction<ProcessPanoramaC>>('process_panorama')
    .asFunction();

// free_panorama_buffer()
typedef FreePanoramaBufferC = Void Function(Pointer<Uint8> buffer);
typedef FreePanoramaBufferDart = void Function(Pointer<Uint8> buffer);
final FreePanoramaBufferDart _freePanoramaBufferC = _lib
    .lookup<NativeFunction<FreePanoramaBufferC>>('free_panorama_buffer')
    .asFunction();

// 3. DART WRAPPER (KULLANICI DOSTU) FONKSİYONLAR
// Yukarıdaki ham FFI fonksiyonlarını, senin diğer dosyalarında (örneğin provider'larda)
// çok kolayca çağırabileceğin normal Dart fonksiyonlarına çeviriyoruz.

class PanoramaStitcher {
  /// Sistemi başlatır
  static int init() {
    return initPanoramaEngine();
  }

  /// Hafızadaki önceki kareleri temizler
  static void clear() {
    clearFrames();
  }

  /// Kameradan gelen kareyi (Uint8List) C++ motoruna kopyalar
  static int addFrame(Uint8List bytes, int width, int height) {
    // 1. C++ belleğinde (Native Heap) resim boyutu kadar yer ayırıyoruz.
    final Pointer<Uint8> pointer = calloc<Uint8>(bytes.length);

    // 2. Dart belleğindeki resmi, C++ belleğine kopyalıyoruz.
    final pointerList = pointer.asTypedList(bytes.length);
    pointerList.setAll(0, bytes);

    // 3. C++ fonksiyonunu çağırıyoruz.
    final int frameCount = _addFrameC(pointer, width, height);

    // 4. İşimiz bitince C++ belleğindeki geçici yeri serbest bırakıyoruz (Hafıza sızıntısını önleriz).
    calloc.free(pointer);

    return frameCount; // Şu an C++ listesinde kaç kare olduğunu döndürür.
  }


  static int addEncodedFrame(Uint8List bytes) {
    final Pointer<Uint8> pointer = calloc<Uint8>(bytes.length);
    pointer.asTypedList(bytes.length).setAll(0, bytes);

    try {
      return _addEncodedFrameC(pointer, bytes.length);
    } finally {
      calloc.free(pointer);
    }
  }
  /// Toplanan kareleri birleştirir ve bitmiş panorama fotoğrafını JPG byte'ları olarak geri döndürür.
  static Uint8List? process() {
    // C++'ın bize verileri geri yazabilmesi için boş pointer'lar (işaretçiler) hazırlıyoruz.
    final Pointer<Pointer<Uint8>> outBytesPtr = calloc<Pointer<Uint8>>();
    final Pointer<Int32> outWidthPtr = calloc<Int32>();
    final Pointer<Int32> outHeightPtr = calloc<Int32>();

    // C++ motorunu çalıştır
    final int size = _processPanoramaC(outBytesPtr, outWidthPtr, outHeightPtr);

    // Eğer size <= 0 ise birleştirme başarısız olmuştur (örneğin yeterli ortak nokta bulunamamıştır).
    if (size <= 0) {
      calloc.free(outBytesPtr);
      calloc.free(outWidthPtr);
      calloc.free(outHeightPtr);
      return null;
    }

    // Başarılıysa, C++'ın oluşturduğu fotoğrafı Dart tarafına okuyoruz.
    final Pointer<Uint8> imgPointer = outBytesPtr.value;
    if (imgPointer == nullptr) {
      calloc.free(outBytesPtr);
      calloc.free(outWidthPtr);
      calloc.free(outHeightPtr);
      return null;
    }

    try {
      final Uint8List imgBytes = imgPointer.asTypedList(size);
      return Uint8List.fromList(imgBytes);
    } finally {
      _freePanoramaBufferC(imgPointer);
      calloc.free(outBytesPtr);
      calloc.free(outWidthPtr);
      calloc.free(outHeightPtr);
    }
  }
}
