import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:hive/hive.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:io';

class CameraProvider extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  String _guidanceKey = 'duz_bak';

  int _selectedCameraIndex = 0;
  ResolutionPreset _selectedResolution = ResolutionPreset.high;
  XFile? _capturedImage;
  bool _isTakingPicture = false;

  late FaceDetector _faceDetector;
  bool _isProcessing = false;
  bool _isStreamRunning = false;

  List<String> _savedPhotos = [];

  //(getter) sadece okuma
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
            performanceMode: FaceDetectorMode.accurate));
  }

  Future<void> initializeCameras() async {
    if (_controller != null) return;

    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        _selectedCameraIndex = _cameras.indexWhere(
            (camera) => camera.lensDirection == CameraLensDirection.front);

        if (_selectedCameraIndex == -1) _selectedCameraIndex = 0;

        await _setupCameraController();
      } else {
        debugPrint("Cihazda kamera bulunamadı.");
      }
    } catch (e) {
      debugPrint("Kamera başlatılırken hata oluştu: $e");
    }
  }

  Future<void> _setupCameraController() async {
    if (_cameras.isEmpty) return;

    _isInitialized = false;
    _isStreamRunning = false;
    _isProcessing = false;
    notifyListeners();

    if (_controller != null) {
      try {
        await _controller!.dispose();
      } catch (e) {
        debugPrint("Önceki kamera temizlenirken hata oluştu: $e");
      }
      _controller = null;
    }

    _controller = CameraController(
      _cameras[_selectedCameraIndex],
      _selectedResolution,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      _isInitialized = true;
      _capturedImage = null;
      notifyListeners();

      startLiveStream();
    } catch (e) {
      debugPrint("Kamera başlatılırken hata oluştu: $e");
    }
  }

  void startLiveStream() {
    if (_controller == null || !_isInitialized) return;
    if (_isStreamRunning) return;

    try {
      _isStreamRunning = true;
      _isProcessing = false;
      _controller!.startImageStream((CameraImage image) async {
        if (_isProcessing) return;

        _isProcessing = true;

        try {
          await _processFrame(image);
        } catch (e) {
          debugPrint("Kare işlenirken hata oluştu: $e");
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

    if (inputImage == null) {
      _updateGuidanceState('yuz_bulunamadi');
      return;
    }

    try {
      List<Face> faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        _updateGuidanceState('yuz_bulunamadi');
        return;
      }

      final Face face = faces.first;

      final double? eulerY = face.headEulerAngleY;

      if (eulerY == null) {
        _updateGuidanceState('yuz_bulunamadi');
        return;
      }

      if (eulerY > 20) {
        _updateGuidanceState('sola_cevir');
      } else if (eulerY < -20) {
        _updateGuidanceState('saga_cevir');
      } else {
        _updateGuidanceState('duz_bak');
      }
    } catch (e) {
      debugPrint("Yapay zeka yüz analizi yaparken hata oluştu: $e");
    }
  }

  void _updateGuidanceState(String newKey) {
    if (_guidanceKey != newKey) {
      _guidanceKey = newKey;
      notifyListeners();
      debugPrint("Durum Değişti: $newKey");
    }
  }

  Future<void> stopLiveStream() async {
    if (_controller == null || !isStreamRunning) {
      _isStreamRunning = false;
      _isProcessing = false;
      return;
    }

    try {
      if (_controller!.value.isStreamingImages) {
        await controller!.stopImageStream();
        debugPrint("Canlı akış donanımsal olarak durduruldu.");
      }
    } catch (e) {
      debugPrint(
          "Donanımsal akış durdurulurken istisna oluştu (Güvenli geçiş): $e");
    } finally {
      _isStreamRunning = false;
      _isProcessing = false;
      notifyListeners();
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
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_controller!.value.isTakingPicture || _isTakingPicture) return;

    try {
      _isTakingPicture = true;
      notifyListeners();

      await stopLiveStream();

      final XFile image = await _controller!.takePicture();
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

  Future<void> closeCamera() async {
    if (_controller != null) {
      await _controller!.dispose();
      _controller = null;
      _isInitialized = false;
      notifyListeners();
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
      debugPrint("Fotoğraf yolu Hive'a kaydedildi: ${_capturedImage!.path}");
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

      int actualIndex = box.length - 1 - index;

      await box.deleteAt(actualIndex);
      debugPrint("Fotoğraf Hive'dan silindi.");
      loadSavedPhotos();
    } catch (e) {
      debugPrint("Fotoğraf silinirken hata oluştu: $e");
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null) return null;

    final camera = _cameras[_selectedCameraIndex];
    final sensorOrientation = camera.sensorOrientation;

    InputImageRotation? rotation;
    final orientation = _controller!.value.deviceOrientation;

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
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: plane.bytesPerRow,
    );

    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
