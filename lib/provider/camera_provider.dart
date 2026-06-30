import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class CameraProvider extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  String _guidanceKey = 'duz_bak';

  int _selectedCameraIndex = 0;
  ResolutionPreset _selectedResolution = ResolutionPreset.high;
  XFile? _capturedImage;
  bool _isTakingPicture = false;

  //(getter) sadece okuma
  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  String get guidanceKey => _guidanceKey;

  ResolutionPreset get selectedResolution => _selectedResolution;
  XFile? get capturedImage => _capturedImage;
  bool get isTakingPicture => _isTakingPicture;

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

    if (_controller != null) {
      await _controller!.dispose();
    }

    final selectedCamera = _cameras[_selectedCameraIndex];

    _controller = CameraController(selectedCamera, _selectedResolution,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);

    try {
      await _controller!.initialize();
      _isInitialized = true;
      _capturedImage = null;
      notifyListeners();
    } catch (e) {
      debugPrint("Kamera başlatılırken hata oluştu: $e");
    }
  }

  Future<void> toggleCamera() async {
    if (_cameras.length < 2) return;

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
    if (_controller == null && _controller!.value.isInitialized) return;
    if (_controller!.value.isTakingPicture) return;
    if (_isTakingPicture) return;

    try {
      final XFile image = await _controller!.takePicture();
      _capturedImage = image;
      notifyListeners();
    } catch (e) {
      debugPrint("Fotoğraf çekilirken hata: $e");
    }
  }

  void clearCapturedImage() {
    _capturedImage = null;
    notifyListeners();
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
