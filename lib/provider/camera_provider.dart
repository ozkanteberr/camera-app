import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class CameraProvider extends ChangeNotifier {
  CameraController? _controller;
  bool _isInitialized = false;
  String _guidanceKey = 'duz_bak';

  //(getter) sadece okuma
  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  String get guidanceKey => _guidanceKey;

  Future<void> initializeCamera() async {
    if (_controller != null) return;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint("Cihazda kamera bulunamadı.");
        return;
      }

      final frontCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
          orElse: () => cameras.first);

      //çözünürlük
      _controller = CameraController(frontCamera, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);

      await _controller!.initialize();
      _isInitialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint("Kamera başlatılırken hata oluştu: $e");
    }
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

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
