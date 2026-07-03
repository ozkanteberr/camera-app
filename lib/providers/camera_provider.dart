import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:hive/hive.dart';

class CameraProvider extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isViewActive = false;
  String _guidanceKey = 'duz_bak';

  int _selectedCameraIndex = 0;
  ResolutionPreset _selectedResolution = ResolutionPreset.high;
  XFile? _capturedImage;
  bool _isTakingPicture = false;

  late final FaceDetector _faceDetector;
  bool _isProcessing = false;
  bool _isStreamRunning = false;
  DateTime? _lastProcessedTime;

  List<String> _savedPhotos = [];

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  String get guidanceKey => _guidanceKey;
  ResolutionPreset get selectedResolution => _selectedResolution;
  XFile? get capturedImage => _capturedImage;
  bool get isTakingPicture => _isTakingPicture;
  bool get isStreamRunning => _isStreamRunning;
  List<String> get savedPhotos => _savedPhotos;

  CameraProvider() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: false,
        enableTracking: true,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );
  }

  void setViewActive(bool active) {
    _isViewActive = active;
  }

  Future<void> initializeCameras() async {
    if (_controller != null) return;

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        debugPrint("Cihazda kamera bulunamadı.");
        return;
      }

      _selectedCameraIndex = _cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
      );
      if (_selectedCameraIndex == -1) _selectedCameraIndex = 0;

      await _setupCameraController();
    } catch (e) {
      debugPrint("Kamera başlatılırken hata oluştu: $e");
    }
  }

  Future<void> _setupCameraController() async {
    if (_cameras.isEmpty) return;

    final oldController = _controller;
    _controller = null;
    _isInitialized = false;
    _isStreamRunning = false;
    _isProcessing = false;
    notifyListeners();

    if (oldController != null) {
      try {
        if (oldController.value.isStreamingImages) {
          await oldController.stopImageStream();
        }
        await oldController.dispose();
      } catch (e) {
        debugPrint("Önceki kamera temizlenirken hata oluştu: $e");
      }
    }

    final controller = CameraController(
      _cameras[_selectedCameraIndex],
      _selectedResolution,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    _controller = controller;

    try {
      await controller.initialize();
      if (_controller != controller) return;

      _isInitialized = true;
      _capturedImage = null;
      notifyListeners();
      startLiveStream();
    } catch (e) {
      debugPrint("Kamera başlatılırken hata oluştu: $e");
    }
  }

  void startLiveStream() {
    final controller = _controller;
    if (!_isViewActive || controller == null || !_isInitialized) return;
    if (_isStreamRunning) return;

    try {
      _isStreamRunning = true;
      _isProcessing = false;
      controller.startImageStream((CameraImage image) async {
        if (!_isViewActive || _isProcessing) return;
        if (_controller != controller || !controller.value.isInitialized) return;

        final now = DateTime.now();
        if (_lastProcessedTime != null &&
            now.difference(_lastProcessedTime!).inMilliseconds < 250) {
          return;
        }

        _isProcessing = true;
        _lastProcessedTime = now;

        try {
          await _processFrame(image);
        } catch (e) {
          if (_isViewActive) debugPrint("Kare işlenirken hata oluştu: $e");
        } finally {
          _isProcessing = false;
        }
      });
    } catch (e) {
      debugPrint("Canlı akış başlatılırken hata: $e");
      _isStreamRunning = false;
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    final inputImage = _inputImageFromCameraImage(image);
    if (!_isViewActive) return;

    if (inputImage == null) {
      _updateGuidanceState('yuz_bulunamadi');
      return;
    }

    try {
      final faces = await _faceDetector.processImage(inputImage);
      if (!_isViewActive) return;

      if (faces.isEmpty) {
        _updateGuidanceState('yuz_bulunamadi');
        return;
      }

      final eulerY = faces.first.headEulerAngleY;
      if (eulerY == null) {
        _updateGuidanceState('yuz_bulunamadi');
        return;
      }

      if (eulerY > 20) {
        _updateGuidanceState('saga_cevir');
      } else if (eulerY < -20) {
        _updateGuidanceState('sola_cevir');
      } else {
        _updateGuidanceState('duz_bak');
      }
    } catch (e) {
      if (_isViewActive) {
        debugPrint("Yapay zeka yüz analizi yaparken hata oluştu: $e");
      }
    }
  }

  void _updateGuidanceState(String newKey) {
    if (!_isViewActive) return;

    if (_guidanceKey != newKey) {
      _guidanceKey = newKey;
      notifyListeners();
    }
  }

  Future<void> stopLiveStream({bool notify = true}) async {
    final controller = _controller;
    if (controller == null) {
      _isStreamRunning = false;
      _isProcessing = false;
      return;
    }

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (e) {
      debugPrint("Canlı akış durdurulurken hata: $e");
    } finally {
      _isStreamRunning = false;
      _isProcessing = false;
      if (notify) notifyListeners();
    }
  }

  Future<void> toggleCamera() async {
    if (_cameras.length < 2) return;

    await stopLiveStream();
    _isInitialized = false;
    notifyListeners();

    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _setupCameraController();
  }

  Future<void> changeResolution(ResolutionPreset newResolution) async {
    if (_selectedResolution == newResolution) return;

    _isInitialized = false;
    _selectedResolution = newResolution;
    notifyListeners();

    await _setupCameraController();
  }

  Future<void> takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isTakingPicture || _isTakingPicture) return;

    try {
      _isTakingPicture = true;
      notifyListeners();

      await stopLiveStream();

      final image = await controller.takePicture();
      _capturedImage = image;
    } catch (e) {
      debugPrint("Fotoğraf çekilirken hata: $e");
    } finally {
      _isTakingPicture = false;
      notifyListeners();
    }
  }

  void clearCapturedImage() {
    _capturedImage = null;
    notifyListeners();
    startLiveStream();
  }

  void updateGuidance(String newKey) {
    if (_guidanceKey != newKey) {
      _guidanceKey = newKey;
      notifyListeners();
    }
  }

  Future<void> closeCamera({bool notify = true}) async {
    _isViewActive = false;

    final controller = _controller;
    _controller = null;
    _isInitialized = false;
    _isStreamRunning = false;
    _isProcessing = false;
    if (notify) notifyListeners();

    if (controller == null) return;

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (e) {
      debugPrint("Yüz tespiti kamera akışı kapatılırken hata: $e");
    }

    try {
      await controller.dispose();
    } catch (e) {
      debugPrint("Yüz tespiti kamera dispose hatası: $e");
    }
  }

  void loadSavedPhotos() {
    final box = Hive.box<String>('photosBox');
    _savedPhotos = box.values.toList().reversed.toList();
    notifyListeners();
  }

  Future<void> saveCapturedImage() async {
    if (_capturedImage == null) return;

    try {
      final box = Hive.box<String>('photosBox');
      await box.add(_capturedImage!.path);
      loadSavedPhotos();

      _capturedImage = null;
      notifyListeners();
      startLiveStream();
    } catch (e) {
      debugPrint("Hive kaydı yapılırken hata oluştu: $e");
    }
  }

  Future<void> deletePhoto(int index) async {
    try {
      final box = Hive.box<String>('photosBox');
      final actualIndex = box.length - 1 - index;

      await box.deleteAt(actualIndex);
      loadSavedPhotos();
    } catch (e) {
      debugPrint("Fotoğraf silinirken hata oluştu: $e");
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final controller = _controller;
    if (controller == null) return null;

    final camera = _cameras[_selectedCameraIndex];
    final orientation = controller.value.deviceOrientation;
    InputImageRotation rotation;

    if (camera.lensDirection == CameraLensDirection.front) {
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          rotation = InputImageRotation.rotation270deg;
          break;
        case DeviceOrientation.landscapeLeft:
          rotation = InputImageRotation.rotation180deg;
          break;
        case DeviceOrientation.portraitDown:
          rotation = InputImageRotation.rotation90deg;
          break;
        case DeviceOrientation.landscapeRight:
          rotation = InputImageRotation.rotation0deg;
          break;
      }
    } else {
      switch (orientation) {
        case DeviceOrientation.portraitUp:
          rotation = InputImageRotation.rotation90deg;
          break;
        case DeviceOrientation.landscapeLeft:
          rotation = InputImageRotation.rotation90deg;
          break;
        case DeviceOrientation.portraitDown:
          rotation = InputImageRotation.rotation270deg;
          break;
        case DeviceOrientation.landscapeRight:
          rotation = InputImageRotation.rotation180deg;
          break;
      }
    }

    final format =
        Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888;
    final plane = image.planes.first;
    final allBytes = WriteBuffer();
    for (final plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: plane.bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: allBytes.done().buffer.asUint8List(),
      metadata: metadata,
    );
  }

  @override
  void dispose() {
    _faceDetector.close();
    _controller?.dispose();
    super.dispose();
  }
}
