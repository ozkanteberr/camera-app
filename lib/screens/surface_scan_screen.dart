import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'dart:ui' as ui;

import 'package:ar_flutter_plugin_updated/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_updated/widgets/ar_view.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:hive/hive.dart';
import 'package:panorama_stitcher/panorama_stitcher.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

String _encodedImageExtension(Uint8List bytes) {
  final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
  return isJpeg ? 'jpg' : 'png';
}

class SurfaceScanScreen extends StatefulWidget {
  const SurfaceScanScreen({super.key});

  @override
  State<SurfaceScanScreen> createState() => _SurfaceScanScreenState();
}

class _SurfaceScanScreenState extends State<SurfaceScanScreen> {
  static const String _planeTexturePath = 'assets/ar/gray_plane.png';
  static const List<Offset> _captureProbePoints = [
    Offset(0.18, 0.22),
    Offset(0.82, 0.22),
    Offset(0.82, 0.78),
    Offset(0.18, 0.78),
  ];
  static const List<Rect> _fallbackCaptureRects = [
    Rect.fromLTRB(0.04, 0.06, 0.96, 0.94),
    Rect.fromLTRB(0.06, 0.08, 0.94, 0.92),
    Rect.fromLTRB(0.08, 0.10, 0.92, 0.90),
    Rect.fromLTRB(0.10, 0.13, 0.90, 0.87),
    Rect.fromLTRB(0.14, 0.18, 0.86, 0.84),
    Rect.fromLTRB(0.18, 0.22, 0.82, 0.78),
  ];
  static const int _surfacePreviewIntervalMs = 300;

  ARSessionManager? _arSessionManager;
  Timer? _detectedTimer;
  Timer? _surfacePreviewTimer;
  final List<_CapturedSurfaceFrame> _capturedFrames = [];
  final List<Rect> _coveredSurfaceRects = [];

  vmath.Vector3? _surfaceOrigin;
  vmath.Vector3? _surfaceAxisX;
  vmath.Vector3? _surfaceAxisY;
  _SurfaceScanStage _stage = _SurfaceScanStage.starting;

  bool _isInitialized = false;
  bool _isCapturing = false;
  bool _isCropping = false;
  bool _isMerging = false;
  bool _isRefreshingSurfacePreview = false;
  bool _showFlash = false;
  bool _showSettings = false;
  bool _showPlanes = true;
  bool _showFeaturePoints = false;
  int _planeCount = 0;
  int _captureSequence = 0;
  Rect? _knownSurfaceBounds;
  _SurfaceCaptureGeometry? _latestSurfaceGeometry;
  double _coverageRatio = 0.0;

  bool get _supportsAr {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool get _hasLockedSurface => _surfaceOrigin != null && _surfaceAxisX != null && _surfaceAxisY != null;

  @override
  void dispose() {
    _detectedTimer?.cancel();
    _stopSurfacePreviewTracking();
    try { PanoramaStitcher.clearSurface(); } catch (_) {}
    _arSessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supportsAr) return _buildUnsupportedScreen();
    return WillPopScope(
      onWillPop: () async { _arSessionManager?.dispose(); return true; },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
              permissionPromptDescription: 'surface_scan_camera_permission'.tr(),
              permissionPromptButtonText: 'confirm'.tr(),
            ),
            _buildTopBar(),
            _buildStatusPill(),
            _buildPlaneStateChip(),
            _buildCoverageOverlay(),
            _buildSettingsPanel(),
            if (_capturedFrames.isNotEmpty) _buildFramesRibbon(),
            _buildBottomControls(),
            if (!_isInitialized) _buildLoadingOverlay(),
            if (_showFlash) Positioned.fill(child: Container(color: Colors.white.withOpacity(0.82))),
          ],
        ),
      ),
    );
  }

  Widget _buildUnsupportedScreen() => Scaffold(
        backgroundColor: Colors.grey[900],
        appBar: AppBar(
          title: Text('surface_scan_title'.tr()),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24.r),
            child: Text(
              'surface_scan_unsupported'.tr(),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 16.sp),
            ),
          ),
        ),
      );

  Future<ui.Image> _resolveImageProvider(ImageProvider provider) {
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool syncCall) { completer.complete(info.image); stream.removeListener(listener); },
      onError: (dynamic exception, StackTrace? stackTrace) { completer.completeError(exception, stackTrace); stream.removeListener(listener); },
    );
    stream.addListener(listener);
    return completer.future;
  }

  Future<Uint8List> _imageProviderToPngBytes(ImageProvider provider) async {
    if (provider is MemoryImage) return provider.bytes;
    final image = await _resolveImageProvider(provider);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw StateError('Snapshot image could not be encoded.');
      return byteData.buffer.asUint8List();
    } finally { image.dispose(); }
  }

  Rect _captureSourceRect(Size screenSize, Rect normalizedRect) {
    final clamped = _clampNormalizedRect(normalizedRect);
    return Rect.fromLTRB(
      clamped.left * screenSize.width,
      clamped.top * screenSize.height,
      clamped.right * screenSize.width,
      clamped.bottom * screenSize.height,
    );
  }

  Rect _clampNormalizedRect(Rect rect) => Rect.fromLTRB(
        rect.left.clamp(0.0, 1.0).toDouble(),
        rect.top.clamp(0.0, 1.0).toDouble(),
        rect.right.clamp(0.0, 1.0).toDouble(),
        rect.bottom.clamp(0.0, 1.0).toDouble(),
      );

  List<Offset> _rectCorners(Rect rect) => [
        Offset(rect.left, rect.top),
        Offset(rect.right, rect.top),
        Offset(rect.right, rect.bottom),
        Offset(rect.left, rect.bottom),
      ];

  Future<Uint8List> _cropImage(Uint8List imageBytes, Rect screenCropRect, Size screenSize) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frameInfo = await codec.getNextFrame();
    var image = frameInfo.image;
    if (image.width > image.height && screenSize.height > screenSize.width) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.translate(image.height.toDouble(), 0);
      canvas.rotate(math.pi / 2);
      canvas.drawImage(image, Offset.zero, ui.Paint());
      final rotatedImage = await recorder.endRecording().toImage(image.height, image.width);
      image.dispose();
      image = rotatedImage;
    }
    try {
      final scaleX = image.width / screenSize.width;
      final scaleY = image.height / screenSize.height;
      final srcLeft = (screenCropRect.left * scaleX).clamp(0.0, image.width - 1.0).toDouble();
      final srcTop = (screenCropRect.top * scaleY).clamp(0.0, image.height - 1.0).toDouble();
      final srcWidth = (screenCropRect.width * scaleX).clamp(1.0, image.width - srcLeft).toDouble();
      final srcHeight = (screenCropRect.height * scaleY).clamp(1.0, image.height - srcTop).toDouble();
      const maxCropSide = 1400.0;
      final outputScale = math.min(1.0, maxCropSide / math.max(srcWidth, srcHeight));
      final outputWidth = math.max(1, (srcWidth * outputScale).round());
      final outputHeight = math.max(1, (srcHeight * outputScale).round());
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(srcLeft, srcTop, srcWidth, srcHeight),
        Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final croppedImage = await recorder.endRecording().toImage(outputWidth, outputHeight);
      try {
        final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) throw StateError('Cropped image could not be encoded.');
        return byteData.buffer.asUint8List();
      } finally { croppedImage.dispose(); }
    } finally { image.dispose(); }
  }

  Future<Uint8List?> _stitchFramesSideBySide(List<_CapturedSurfaceFrame> frames) async {
    if (frames.isEmpty) return null;
    if (frames.length == 1) return frames.first.croppedBytes;
    final decodedImages = <ui.Image>[];
    try {
      for (final frame in frames) {
        final codec = await ui.instantiateImageCodec(frame.croppedBytes);
        decodedImages.add((await codec.getNextFrame()).image);
      }
      var targetHeight = decodedImages.first.height.toDouble();
      for (final image in decodedImages.skip(1)) {
        targetHeight = math.max(targetHeight, image.height.toDouble()).toDouble();
      }
      targetHeight = math.min(targetHeight, 1200.0).toDouble();
      final widths = decodedImages.map((i) => (i.width * targetHeight / i.height).round()).toList();
      final totalWidth = widths.reduce((a, b) => a + b);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
      var x = 0.0;
      for (var i = 0; i < decodedImages.length; i++) {
        final image = decodedImages[i];
        final width = widths[i].toDouble();
        canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), Rect.fromLTWH(x, 0, width, targetHeight), paint);
        x += width;
      }
      final stitchedImage = await recorder.endRecording().toImage(totalWidth, targetHeight.round());
      try {
        final byteData = await stitchedImage.toByteData(format: ui.ImageByteFormat.png);
        return byteData?.buffer.asUint8List();
      } finally { stitchedImage.dispose(); }
    } catch (e) {
      debugPrint('Surface fallback merge error: $e');
      return null;
    } finally { for (final image in decodedImages) { image.dispose(); } }
  }

  Future<Uint8List?> _composeSurfaceWithPanoramaEngine(List<_CapturedSurfaceFrame> frames) async {
    if (frames.length < 2) return null;
    try {
      PanoramaStitcher.init();
      PanoramaStitcher.clear();
      await Future<void>.delayed(const Duration(milliseconds: 16));
      var acceptedFrames = 0;
      for (final frame in frames) {
        final frameCount = PanoramaStitcher.addEncodedFrame(frame.croppedBytes);
        if (frameCount > acceptedFrames) acceptedFrames = frameCount;
        if (acceptedFrames.isEven) await Future<void>.delayed(Duration.zero);
      }
      if (acceptedFrames < 2) return null;
      await Future<void>.delayed(const Duration(milliseconds: 16));
      return PanoramaStitcher.process();
    } catch (e) {
      debugPrint('Surface panorama compose error: $e');
      return null;
    } finally { try { PanoramaStitcher.clear(); } catch (_) {} }
  }

  Future<Uint8List?> _composeSurfaceWithOpenCv(List<_CapturedSurfaceFrame> frames) async {
    if (frames.isEmpty) return null;
    try {
      PanoramaStitcher.init();
      PanoramaStitcher.clearSurface();
      await Future<void>.delayed(const Duration(milliseconds: 16));
      var acceptedFrames = 0;
      for (final frame in frames) {
        final frameCount = PanoramaStitcher.addSurfaceFrame(frame.croppedBytes, frame.planePoints);
        if (frameCount > acceptedFrames) acceptedFrames = frameCount;
        if (acceptedFrames.isEven) await Future<void>.delayed(Duration.zero);
      }
      if (acceptedFrames <= 0) return null;
      await Future<void>.delayed(const Duration(milliseconds: 16));
      return PanoramaStitcher.processSurfaceScan();
    } catch (e) {
      debugPrint('Surface OpenCV compose error: $e');
      return null;
    } finally { try { PanoramaStitcher.clearSurface(); } catch (_) {} }
  }

  Widget _buildLoadingOverlay() => Container(
        color: Colors.black.withOpacity(0.34),
        child: const Center(child: CircularProgressIndicator(color: Colors.white)),
      );

  Widget _buildTopBar() => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(14.w, 10.h, 14.w, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildCircleButton(icon: Icons.arrow_back_ios_new, onPressed: () => Navigator.of(context).maybePop()),
              AnimatedOpacity(duration: const Duration(milliseconds: 160), opacity: _capturedFrames.isEmpty ? 0 : 1, child: _buildCaptureCounter()),
            ],
          ),
        ),
      );

  Widget _buildStatusPill() {
    final isActive = _stage == _SurfaceScanStage.detected || _stage == _SurfaceScanStage.locked;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: EdgeInsets.only(top: 12.h),
          constraints: BoxConstraints(maxWidth: 310.w),
          padding: EdgeInsets.symmetric(horizontal: 18.w, vertical: 9.h),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.92),
            borderRadius: BorderRadius.circular(20.r),
            border: Border.all(color: isActive ? Colors.greenAccent.withOpacity(0.95) : Colors.white.withOpacity(0.55), width: 1.2.r),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.22), blurRadius: 14.r, offset: Offset(0, 6.h))],
          ),
          child: Text(
            _stageLabelKey.tr(),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _stage == _SurfaceScanStage.locked ? Colors.green.shade700 : Colors.grey.shade800, fontSize: 14.sp, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaneStateChip() {
    if (!_isInitialized) return const SizedBox.shrink();
    final hasPlane = _planeCount > 0;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: EdgeInsets.only(top: 56.h),
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.48),
            borderRadius: BorderRadius.circular(16.r),
            border: Border.all(color: hasPlane ? Colors.greenAccent.withOpacity(0.55) : Colors.white.withOpacity(0.18)),
          ),
          child: Text('${'surface_scan_planes'.tr()}: $_planeCount', style: TextStyle(color: hasPlane ? Colors.greenAccent : Colors.white70, fontSize: 12.sp, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _buildCoverageOverlay() {
    final geometry = _latestSurfaceGeometry;
    if (_stage != _SurfaceScanStage.locked || geometry == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _SurfaceCoveragePainter(
            visibleGeometry: geometry,
            coveredRects: List<Rect>.unmodifiable(_coveredSurfaceRects),
            coverageRatio: _coverageRatio,
          ),
        ),
      ),
    );
  }
  Widget _buildFramesRibbon() => Positioned(
        bottom: 112.h,
        left: 14.w,
        right: 14.w,
        child: Container(
          height: 72.h,
          padding: EdgeInsets.symmetric(vertical: 6.h, horizontal: 8.w),
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.65), borderRadius: BorderRadius.circular(12.r), border: Border.all(color: Colors.white.withOpacity(0.15), width: 1.r)),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _capturedFrames.length,
            itemBuilder: (context, index) {
              final frame = _capturedFrames[index];
              return Container(
                margin: EdgeInsets.only(right: 8.w),
                width: 90.w,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(6.r), border: Border.all(color: Colors.white.withOpacity(0.35), width: 1.5.r)),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Positioned.fill(child: Image.memory(frame.croppedBytes, fit: BoxFit.cover)),
                    Positioned(
                      top: 2.h,
                      left: 4.w,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: 5.w, vertical: 2.h),
                        decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(4.r)),
                        child: Text('#${frame.index}', style: TextStyle(color: Colors.white, fontSize: 9.sp, fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

  Widget _buildSettingsPanel() {
    if (!_showSettings) return const SizedBox.shrink();
    return Positioned(
      left: 14.w,
      bottom: 96.h,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14.r),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: 286.w,
            padding: EdgeInsets.fromLTRB(14.w, 12.h, 14.w, 12.h),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.64), borderRadius: BorderRadius.circular(14.r), border: Border.all(color: Colors.white.withOpacity(0.22))),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('surface_scan_settings'.tr(), style: TextStyle(color: Colors.white, fontSize: 15.sp, fontWeight: FontWeight.w800)),
                SizedBox(height: 8.h),
                _buildSwitchRow(label: 'surface_scan_show_planes'.tr(), value: _showPlanes, onChanged: (value) { setState(() => _showPlanes = value); _updateSessionSettings(); }),
                _buildSwitchRow(label: 'surface_scan_feature_points'.tr(), value: _showFeaturePoints, onChanged: (value) { setState(() => _showFeaturePoints = value); _updateSessionSettings(); }),
                SizedBox(height: 8.h),
                Text('${'surface_scan_planes'.tr()}: $_planeCount', style: TextStyle(color: Colors.white70, fontSize: 12.sp)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() => Positioned(
        left: 0,
        right: 0,
        bottom: 28.h,
        child: SizedBox(
          height: 74.h,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 16.w,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildSettingsButton(),
                    if (_capturedFrames.isNotEmpty) ...[SizedBox(width: 14.w), _buildCircleButtonMini(icon: Icons.refresh_rounded, onPressed: _resetScan, tooltip: 'surface_scan_reset'.tr())],
                  ],
                ),
              ),
              _buildPrimaryActionButton(),
              if (_capturedFrames.isNotEmpty)
                Positioned(
                  right: 16.w,
                  child: TextButton(
                    onPressed: _isMerging ? null : _mergeAndOpenReport,
                    style: TextButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black, padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18.r))),
                    child: Text(_isMerging ? 'merging'.tr() : 'surface_scan_merge'.tr(), style: TextStyle(fontSize: 11.sp, fontWeight: FontWeight.w900)),
                  ),
                ),
            ],
          ),
        ),
      );

  Widget _buildPrimaryActionButton() {
    final canLock = _stage == _SurfaceScanStage.detected;
    final canCapture = _stage == _SurfaceScanStage.locked && _hasLockedSurface;
    final isEnabled = canLock || canCapture;
    final onTap = canLock ? _lockSurface : canCapture && !_isCapturing ? _takeSnapshot : null;
    return GestureDetector(
      onTap: isEnabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: isEnabled ? 1 : 0.42,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 74.r,
          height: 74.r,
          decoration: BoxDecoration(color: Colors.black.withOpacity(0.26), shape: BoxShape.circle, border: Border.all(color: isEnabled ? Colors.white : Colors.white54, width: 3.r)),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 52.r,
              height: 52.r,
              decoration: BoxDecoration(color: _isCapturing || _isCropping ? Colors.grey : Colors.white, shape: BoxShape.circle),
              child: _isCapturing || _isCropping
                  ? Padding(padding: EdgeInsets.all(13.r), child: CircularProgressIndicator(strokeWidth: 2.5.r, color: Colors.black))
                  : Icon(canLock ? Icons.lock_outline_rounded : Icons.camera_alt_rounded, color: Colors.black, size: 28.r),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsButton() => GestureDetector(
        onTap: () => setState(() => _showSettings = !_showSettings),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 42.r, height: 42.r, decoration: BoxDecoration(color: Colors.black.withOpacity(0.36), shape: BoxShape.circle, border: Border.all(color: Colors.white.withOpacity(0.22))), child: Icon(Icons.settings, color: Colors.white, size: 22.r)),
            SizedBox(height: 4.h),
            Text('surface_scan_settings'.tr(), style: TextStyle(color: Colors.white, fontSize: 12.sp)),
          ],
        ),
      );

  Widget _buildCaptureCounter() => ClipRRect(
        borderRadius: BorderRadius.circular(18.r),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.42), borderRadius: BorderRadius.circular(18.r), border: Border.all(color: Colors.white.withOpacity(0.22))),
            child: Text('${_capturedFrames.length} | ${(_coverageRatio * 100).round()}%', style: TextStyle(color: Colors.white, fontSize: 14.sp, fontWeight: FontWeight.w800)),
          ),
        ),
      );

  Widget _buildCircleButton({required IconData icon, required VoidCallback onPressed}) => ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Material(color: Colors.black.withOpacity(0.42), shape: const CircleBorder(), child: IconButton(icon: Icon(icon, color: Colors.white, size: 21.r), onPressed: onPressed)),
        ),
      );

  Widget _buildCircleButtonMini({required IconData icon, required VoidCallback onPressed, required String tooltip}) => Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(width: 44.r, height: 44.r, decoration: BoxDecoration(color: Colors.black.withOpacity(0.48), shape: BoxShape.circle, border: Border.all(color: Colors.white24, width: 1.r)), child: Icon(icon, color: Colors.white, size: 20.r)),
        ),
      );

  Widget _buildSwitchRow({required String label, required bool value, required ValueChanged<bool> onChanged}) => SizedBox(
        height: 38.h,
        child: Row(children: [Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: 12.sp))), Switch.adaptive(value: value, onChanged: onChanged, activeColor: Colors.greenAccent)]),
      );

  String get _stageLabelKey {
    switch (_stage) {
      case _SurfaceScanStage.starting: return 'surface_scan_start';
      case _SurfaceScanStage.scanning: return 'surface_scan_area';
      case _SurfaceScanStage.detected: return 'surface_scan_lock_surface';
      case _SurfaceScanStage.locked: return 'surface_scan_surface_locked';
    }
  }

  void _onARViewCreated(ARSessionManager arSessionManager, ARObjectManager arObjectManager, ARAnchorManager arAnchorManager, ARLocationManager arLocationManager) {
    _arSessionManager = arSessionManager;
    arSessionManager.onError = _handleArError;
    arSessionManager.onPlaneDetected = _handlePlaneDetected;
    try { PanoramaStitcher.init(); PanoramaStitcher.clearSurface(); } catch (e) { debugPrint('Surface OpenCV init error: $e'); }
    _updateSessionSettings();
    arObjectManager.onInitialize();
    if (!mounted) return;
    setState(() { _isInitialized = true; _stage = _SurfaceScanStage.scanning; });
  }

  void _handleArError(String message) { if (mounted) _showRawSnack(message); }

  void _handlePlaneDetected(int planeCount) {
    if (!mounted || planeCount <= 0 || _stage == _SurfaceScanStage.locked) return;
    final shouldTransition = _stage == _SurfaceScanStage.starting || _stage == _SurfaceScanStage.scanning;
    if (_planeCount != planeCount || shouldTransition) {
      setState(() { _planeCount = planeCount; if (shouldTransition) _stage = _SurfaceScanStage.detected; });
    }
    if (_showPlanes) _arSessionManager?.showPlanes(true);
  }

  Future<void> _lockSurface() async {
    final manager = _arSessionManager;
    if (manager == null || _stage != _SurfaceScanStage.detected) return;
    final hits = await _hitTestPlaneQuad(manager, _captureProbePoints);
    if (!mounted) return;
    if (hits == null || hits.length != 4 || !_setSurfaceBasisFromHits(hits)) { _showSnack('surface_scan_lock_failed'); return; }
    final lockedPlanePoints = _surfacePlanePointsFromHits(hits);
    if (lockedPlanePoints != null) {
      _knownSurfaceBounds = _surfaceBoundsFromPlanePoints(lockedPlanePoints);
      _coverageRatio = _calculateCoverageRatio(_knownSurfaceBounds);
    }
    setState(() { _stage = _SurfaceScanStage.locked; _showPlanes = true; });
    manager.showPlanes(true);
    await _setPlaneDetectionEnabled(manager, false);
    _startSurfacePreviewTracking();
    _showSnack('surface_scan_surface_locked');
  }

  bool _setSurfaceBasisFromHits(List<vmath.Matrix4> hits) {
    final origin = hits[0].getTranslation();
    final xVector = hits[1].getTranslation() - origin;
    final yVector = hits[3].getTranslation() - origin;
    if (xVector.length < 0.02 || yVector.length < 0.02) return false;
    _surfaceOrigin = origin;
    _surfaceAxisX = xVector.normalized();
    _surfaceAxisY = yVector.normalized();
    return true;
  }


  Future<List<vmath.Matrix4>?> _hitTestPlaneQuad(
    ARSessionManager manager,
    List<Offset> normalizedPoints,
  ) async {
    try {
      final dynamic dynamicManager = manager;
      final hits = await dynamicManager.hitTestPlaneQuad(normalizedPoints);
      if (hits is List<vmath.Matrix4>) return hits;
      if (hits is List) return hits.whereType<vmath.Matrix4>().toList(growable: false);
      return null;
    } catch (e) {
      debugPrint('Surface hit test quad error: $e');
      return null;
    }
  }

  Future<void> _setPlaneDetectionEnabled(ARSessionManager manager, bool enabled) async {
    try {
      final dynamic dynamicManager = manager;
      await dynamicManager.setPlaneDetectionEnabled(enabled);
    } catch (e) {
      debugPrint('Plane detection toggle error: $e');
    }
  }

  List<double>? _surfacePlanePointsFromHits(List<vmath.Matrix4> hits) {
    final origin = _surfaceOrigin;
    final axisX = _surfaceAxisX;
    final axisY = _surfaceAxisY;
    if (hits.length != 4 || origin == null || axisX == null || axisY == null) return null;
    final points = <double>[];
    for (final hit in hits) {
      final delta = hit.getTranslation() - origin;
      points.add(delta.dot(axisX));
      points.add(delta.dot(axisY));
    }
    return points;
  }

  Future<_SurfaceCaptureGeometry?> _hitTestPlaneViewport(ARSessionManager manager) async {
    try {
      final dynamic dynamicManager = manager;
      final result = await dynamicManager.hitTestPlaneViewport(
        columns: 9,
        rows: 13,
        horizontalMargin: 0.035,
        verticalMargin: 0.055,
      );
      if (result is! Map) return null;

      final rawRect = result['rect'];
      Rect? rect;
      if (rawRect is Rect) {
        rect = rawRect;
      } else if (rawRect is List && rawRect.length == 4) {
        rect = Rect.fromLTRB(
          (rawRect[0] as num).toDouble(),
          (rawRect[1] as num).toDouble(),
          (rawRect[2] as num).toDouble(),
          (rawRect[3] as num).toDouble(),
        );
      }
      if (rect == null || rect.width < 0.12 || rect.height < 0.12) return null;

      final rawHits = result['hits'];
      final hits = rawHits is List<vmath.Matrix4>
          ? rawHits
          : rawHits is List
              ? rawHits.whereType<vmath.Matrix4>().toList(growable: false)
              : const <vmath.Matrix4>[];
      final planePoints = _surfacePlanePointsFromHits(hits);
      if (planePoints == null) return null;
      return _SurfaceCaptureGeometry(normalizedRect: _clampNormalizedRect(rect), planePoints: planePoints);
    } catch (e) {
      debugPrint('Surface viewport hit test error: $e');
      return null;
    }
  }

  Future<_SurfaceCaptureGeometry?> _currentCaptureGeometry() async {
    final manager = _arSessionManager;
    if (manager == null || !_hasLockedSurface) return null;

    final viewportGeometry = await _hitTestPlaneViewport(manager);
    if (viewportGeometry != null) return viewportGeometry;

    for (final rect in _fallbackCaptureRects) {
      final hits = await _hitTestPlaneQuad(manager, _rectCorners(rect));
      if (hits == null || hits.length != 4) continue;
      final planePoints = _surfacePlanePointsFromHits(hits);
      if (planePoints != null) {
        return _SurfaceCaptureGeometry(normalizedRect: rect, planePoints: planePoints);
      }
    }
    return null;
  }

  void _rememberVisibleGeometry(_SurfaceCaptureGeometry geometry, {bool updateState = true}) {
    final bounds = geometry.surfaceBounds;
    if (bounds.width <= 0 || bounds.height <= 0) return;

    final nextKnownBounds = _mergeSurfaceBounds(_knownSurfaceBounds, bounds);
    if (updateState && mounted) {
      setState(() {
        _latestSurfaceGeometry = geometry;
        _knownSurfaceBounds = nextKnownBounds;
        _coverageRatio = _calculateCoverageRatio(nextKnownBounds);
      });
    } else {
      _latestSurfaceGeometry = geometry;
      _knownSurfaceBounds = nextKnownBounds;
      _coverageRatio = _calculateCoverageRatio(nextKnownBounds);
    }
  }

  Rect _mergeSurfaceBounds(Rect? current, Rect next) {
    if (current == null || current.width <= 0 || current.height <= 0) return next;
    return Rect.fromLTRB(
      math.min(current.left, next.left),
      math.min(current.top, next.top),
      math.max(current.right, next.right),
      math.max(current.bottom, next.bottom),
    );
  }

  Rect _surfaceBoundsFromPlanePoints(List<double> planePoints) {
    if (planePoints.length != 8) return Rect.zero;
    final xs = <double>[planePoints[0], planePoints[2], planePoints[4], planePoints[6]];
    final ys = <double>[planePoints[1], planePoints[3], planePoints[5], planePoints[7]];
    return Rect.fromLTRB(
      xs.reduce(math.min),
      ys.reduce(math.min),
      xs.reduce(math.max),
      ys.reduce(math.max),
    );
  }

  void _registerCapturedSurface(_SurfaceCaptureGeometry geometry) {
    final bounds = geometry.surfaceBounds;
    if (bounds.width <= 0 || bounds.height <= 0) return;
    _coveredSurfaceRects.add(bounds);
    _knownSurfaceBounds = _mergeSurfaceBounds(_knownSurfaceBounds, bounds);
    _coverageRatio = _calculateCoverageRatio(_knownSurfaceBounds);
  }

  bool _isSurfacePointCovered(Offset point) {
    for (final rect in _coveredSurfaceRects) {
      if (rect.contains(point)) return true;
    }
    return false;
  }

  double _calculateCoverageRatio(Rect? targetBounds) {
    final bounds = targetBounds;
    if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return 0;
    if (_coveredSurfaceRects.isEmpty) return 0;

    const samplesX = 18;
    const samplesY = 18;
    var coveredSamples = 0;
    final totalSamples = samplesX * samplesY;
    for (var y = 0; y < samplesY; y++) {
      final py = bounds.top + bounds.height * ((y + 0.5) / samplesY);
      for (var x = 0; x < samplesX; x++) {
        final px = bounds.left + bounds.width * ((x + 0.5) / samplesX);
        if (_isSurfacePointCovered(Offset(px, py))) coveredSamples += 1;
      }
    }
    return coveredSamples / totalSamples;
  }

  void _startSurfacePreviewTracking() {
    _surfacePreviewTimer?.cancel();
    _surfacePreviewTimer = Timer.periodic(
      const Duration(milliseconds: _surfacePreviewIntervalMs),
      (_) => unawaited(_refreshSurfacePreviewGeometry()),
    );
    unawaited(_refreshSurfacePreviewGeometry());
  }

  void _stopSurfacePreviewTracking() {
    _surfacePreviewTimer?.cancel();
    _surfacePreviewTimer = null;
  }

  Future<void> _refreshSurfacePreviewGeometry() async {
    if (!mounted ||
        _stage != _SurfaceScanStage.locked ||
        _isCapturing ||
        _isCropping ||
        _isMerging ||
        _isRefreshingSurfacePreview) {
      return;
    }

    _isRefreshingSurfacePreview = true;
    try {
      final geometry = await _currentCaptureGeometry();
      if (!mounted || _stage != _SurfaceScanStage.locked) return;
      if (geometry == null) {
        if (_latestSurfaceGeometry != null) setState(() => _latestSurfaceGeometry = null);
        return;
      }

      _rememberVisibleGeometry(geometry);
    } finally {
      _isRefreshingSurfacePreview = false;
    }
  }

  Future<bool> _captureGeometrySnapshot(
    _SurfaceCaptureGeometry geometry, {
    bool showFlash = true,
  }) async {
    final manager = _arSessionManager;
    if (manager == null || _stage != _SurfaceScanStage.locked) return false;
    if (_isCapturing || _isCropping || _isMerging) return false;

    setState(() { _isCapturing = true; if (showFlash) _showFlash = true; });
    if (showFlash) {
      Timer(const Duration(milliseconds: 110), () { if (mounted) setState(() => _showFlash = false); });
    }

    final shouldRestorePlanes = _showPlanes;
    try {
      if (shouldRestorePlanes) {
        manager.showPlanes(false);
        await Future<void>.delayed(const Duration(milliseconds: 70));
      }

      final screenSize = MediaQuery.of(context).size;
      final imageProvider = await manager.snapshot();
      if (!mounted) return false;
      setState(() => _isCropping = true);

      final originalBytes = await _imageProviderToPngBytes(imageProvider);
      final croppedBytes = await _cropImage(
        originalBytes,
        _captureSourceRect(screenSize, geometry.normalizedRect),
        screenSize,
      );
      final croppedProvider = MemoryImage(croppedBytes);
      if (!mounted) return false;

      setState(() {
        _captureSequence += 1;
        _capturedFrames.add(_CapturedSurfaceFrame(
          index: _captureSequence,
          croppedBytes: croppedBytes,
          imageProvider: croppedProvider,
          planePoints: geometry.planePoints,
        ));
        _registerCapturedSurface(geometry);
      });
      return true;
    } catch (e) {
      debugPrint('Surface capture error: $e');
      if (mounted) _showSnack('surface_scan_capture_failed');
      return false;
    } finally {
      if (shouldRestorePlanes && mounted && _stage == _SurfaceScanStage.locked) {
        manager.showPlanes(true);
      }
      if (mounted) setState(() { _isCapturing = false; _isCropping = false; _showFlash = false; });
    }
  }

  Future<void> _takeSnapshot() async {
    final manager = _arSessionManager;
    if (manager == null || _stage != _SurfaceScanStage.locked) { _showSnack('surface_scan_detect_first'); return; }
    if (_isCapturing || _isCropping || _isMerging) return;
    final geometry = await _currentCaptureGeometry();
    if (geometry == null) { if (mounted) _showSnack('surface_scan_keep_surface_in_view'); return; }
    _rememberVisibleGeometry(geometry);
    await _captureGeometrySnapshot(geometry);
  }

  void _resetScan() {
    _detectedTimer?.cancel();
    _stopSurfacePreviewTracking();
    try { PanoramaStitcher.clearSurface(); } catch (_) {}
    setState(() {
      _capturedFrames.clear();
      _surfaceOrigin = null;
      _surfaceAxisX = null;
      _surfaceAxisY = null;
      _captureSequence = 0;
      _coveredSurfaceRects.clear();
      _knownSurfaceBounds = null;
      _latestSurfaceGeometry = null;
      _coverageRatio = 0.0;
      _planeCount = 0;
      _showPlanes = true;
      _stage = _isInitialized ? _SurfaceScanStage.scanning : _SurfaceScanStage.starting;
    });
    final manager = _arSessionManager;
    if (manager != null) {
      unawaited(_setPlaneDetectionEnabled(manager, true));
      manager.showPlanes(true);
    }
    _updateSessionSettings();
  }

  Future<void> _mergeAndOpenReport() async {
    if (_capturedFrames.isEmpty || _isMerging) return;
    _stopSurfacePreviewTracking();
    setState(() => _isMerging = true);
    try {
      final frames = List<_CapturedSurfaceFrame>.unmodifiable(_capturedFrames);
      final merged = await _composeSurfaceWithOpenCv(frames) ?? await _composeSurfaceWithPanoramaEngine(frames) ?? await _stitchFramesSideBySide(frames);
      if (!mounted) return;
      if (merged == null || merged.isEmpty) { _showSnack('merge_failed'); return; }
      await _openReport(merged);
    } catch (e) {
      debugPrint('Surface merge/open error: $e');
      if (mounted) _showSnack('merge_failed');
    } finally {
      if (mounted) {
        setState(() => _isMerging = false);
        if (_stage == _SurfaceScanStage.locked) _startSurfacePreviewTracking();
      }
    }
  }

  Future<void> _openReport(Uint8List mergedImageBytes) async {
    if (_capturedFrames.isEmpty) return;
    _stopSurfacePreviewTracking();
    _arSessionManager?.disableCamera();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => _SurfaceScanReportScreen(frames: List.unmodifiable(_capturedFrames), mergedImageBytes: mergedImageBytes)));
    _arSessionManager?.enableCamera();
  }

  void _updateSessionSettings() {
    final manager = _arSessionManager;
    if (manager == null) return;
    final isLocked = _stage == _SurfaceScanStage.locked;
    manager.onInitialize(
      showAnimatedGuide: false,
      showFeaturePoints: _showFeaturePoints,
      showPlanes: _showPlanes && _planeCount > 0,
      customPlaneTexturePath: _planeTexturePath,
      showWorldOrigin: false,
      handleTaps: false,
    );
    if (isLocked) {
      manager.showPlanes(_showPlanes);
      unawaited(_setPlaneDetectionEnabled(manager, false));
    }
  }

  void _showSnack(String key) => _showRawSnack(key.tr());

  void _showRawSnack(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.black87, behavior: SnackBarBehavior.floating));
  }
}

enum _SurfaceScanStage { starting, scanning, detected, locked }

class _SurfaceCaptureGeometry {
  const _SurfaceCaptureGeometry({required this.normalizedRect, required this.planePoints});
  final Rect normalizedRect;
  final List<double> planePoints;

  Rect get surfaceBounds {
    if (planePoints.length != 8) return Rect.zero;
    final xs = <double>[planePoints[0], planePoints[2], planePoints[4], planePoints[6]];
    final ys = <double>[planePoints[1], planePoints[3], planePoints[5], planePoints[7]];
    return Rect.fromLTRB(
      xs.reduce(math.min),
      ys.reduce(math.min),
      xs.reduce(math.max),
      ys.reduce(math.max),
    );
  }
}

class _SurfaceCoveragePainter extends CustomPainter {
  const _SurfaceCoveragePainter({
    required this.visibleGeometry,
    required this.coveredRects,
    required this.coverageRatio,
  });

  final _SurfaceCaptureGeometry visibleGeometry;
  final List<Rect> coveredRects;
  final double coverageRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final visibleSurface = visibleGeometry.surfaceBounds;
    if (visibleSurface.width <= 0 || visibleSurface.height <= 0) return;

    final visibleScreen = Rect.fromLTRB(
      visibleGeometry.normalizedRect.left * size.width,
      visibleGeometry.normalizedRect.top * size.height,
      visibleGeometry.normalizedRect.right * size.width,
      visibleGeometry.normalizedRect.bottom * size.height,
    );
    if (visibleScreen.width <= 1 || visibleScreen.height <= 1) return;

    final fillPaint = Paint()
      ..color = Colors.greenAccent.withOpacity(0.30)
      ..style = PaintingStyle.fill;
    final edgePaint = Paint()
      ..color = Colors.greenAccent.withOpacity(0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final currentEdgePaint = Paint()
      ..color = Colors.white.withOpacity(0.82)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.save();
    canvas.clipRect(visibleScreen.inflate(2));
    for (final covered in coveredRects) {
      final intersection = covered.intersect(visibleSurface);
      if (intersection.width <= 0 || intersection.height <= 0) continue;
      final screenRect = _mapSurfaceRectToScreen(intersection, visibleSurface, visibleScreen);
      canvas.drawRect(screenRect, fillPaint);
      canvas.drawRect(screenRect, edgePaint);
    }
    canvas.restore();

    canvas.drawRect(visibleScreen, currentEdgePaint);

    final progress = coverageRatio.clamp(0.0, 1.0).toDouble();
    if (progress > 0) {
      final barBackground = RRect.fromRectAndRadius(
        Rect.fromLTWH(visibleScreen.left, visibleScreen.bottom + 5, visibleScreen.width, 4),
        const Radius.circular(2),
      );
      final barFill = RRect.fromRectAndRadius(
        Rect.fromLTWH(visibleScreen.left, visibleScreen.bottom + 5, visibleScreen.width * progress, 4),
        const Radius.circular(2),
      );
      canvas.drawRRect(barBackground, Paint()..color = Colors.black.withOpacity(0.35));
      canvas.drawRRect(barFill, Paint()..color = Colors.greenAccent.withOpacity(0.90));
    }
  }

  Rect _mapSurfaceRectToScreen(Rect surfaceRect, Rect visibleSurface, Rect visibleScreen) {
    double mapX(double x) => visibleScreen.left + ((x - visibleSurface.left) / visibleSurface.width) * visibleScreen.width;
    double mapY(double y) => visibleScreen.top + ((y - visibleSurface.top) / visibleSurface.height) * visibleScreen.height;
    return Rect.fromLTRB(
      mapX(surfaceRect.left),
      mapY(surfaceRect.top),
      mapX(surfaceRect.right),
      mapY(surfaceRect.bottom),
    );
  }

  @override
  bool shouldRepaint(covariant _SurfaceCoveragePainter oldDelegate) {
    return oldDelegate.visibleGeometry != visibleGeometry ||
        oldDelegate.coveredRects.length != coveredRects.length ||
        oldDelegate.coverageRatio != coverageRatio;
  }
}

class _CapturedSurfaceFrame {
  const _CapturedSurfaceFrame({required this.index, required this.croppedBytes, required this.imageProvider, required this.planePoints});
  final int index;
  final Uint8List croppedBytes;
  final ImageProvider<Object> imageProvider;
  final List<double> planePoints;
}

class _SurfaceScanReportScreen extends StatefulWidget {
  const _SurfaceScanReportScreen({required this.frames, required this.mergedImageBytes});
  final List<_CapturedSurfaceFrame> frames;
  final Uint8List mergedImageBytes;

  @override
  State<_SurfaceScanReportScreen> createState() => _SurfaceScanReportScreenState();
}

class _SurfaceScanReportScreenState extends State<_SurfaceScanReportScreen> {
  int _selectedIndex = -1;
  bool _isSaving = false;

  Future<void> _saveMergedImage() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final outputDir = await getApplicationDocumentsDirectory();
      final file = File('${outputDir.path}/surface_scan_${DateTime.now().millisecondsSinceEpoch}.${_encodedImageExtension(widget.mergedImageBytes)}');
      await file.writeAsBytes(widget.mergedImageBytes);
      final box = Hive.box<String>('photosBox');
      await box.add(file.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('saved'.tr()), backgroundColor: Colors.green.shade800, behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      debugPrint('Save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('surface_scan_capture_failed'.tr()), backgroundColor: Colors.red.shade800, behavior: SnackBarBehavior.floating));
      }
    } finally { if (mounted) setState(() => _isSaving = false); }
  }

  @override
  Widget build(BuildContext context) {
    final frames = widget.frames;
    return Scaffold(
      backgroundColor: const Color(0xFF171717),
      appBar: AppBar(
        title: Text('surface_scan_preview'.tr()),
        centerTitle: true,
        backgroundColor: const Color(0xFF171717),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_isSaving)
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))))
          else
            IconButton(icon: const Icon(Icons.save_alt_rounded), onPressed: _saveMergedImage, tooltip: 'save'.tr()),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: _selectedIndex == -1
                      ? Image.memory(widget.mergedImageBytes, fit: BoxFit.contain, width: double.infinity)
                      : Image(image: frames[_selectedIndex].imageProvider, fit: BoxFit.contain, width: double.infinity),
                ),
              ),
            ),
            _buildReportStrip(frames),
          ],
        ),
      ),
    );
  }

  Widget _buildReportStrip(List<_CapturedSurfaceFrame> frames) => Container(
        height: 112.h,
        padding: EdgeInsets.fromLTRB(12.w, 10.h, 12.w, 16.h),
        color: Colors.black.withOpacity(0.30),
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: frames.length + 1,
          itemBuilder: (context, index) {
            final isMergedThumbnail = index == 0;
            final selected = isMergedThumbnail ? _selectedIndex == -1 : (index - 1) == _selectedIndex;
            return GestureDetector(
              onTap: () => setState(() => _selectedIndex = isMergedThumbnail ? -1 : index - 1),
              child: Container(
                margin: EdgeInsets.only(right: 10.w),
                width: 68.w,
                decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8.r), border: Border.all(color: selected ? Colors.greenAccent : Colors.white24, width: selected ? 2.r : 1.r)),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isMergedThumbnail) Image.memory(widget.mergedImageBytes, fit: BoxFit.cover) else Image(image: frames[index - 1].imageProvider, fit: BoxFit.cover),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(vertical: 3.h),
                        color: Colors.black.withOpacity(0.62),
                        child: Text(isMergedThumbnail ? 'surface_scan_preview'.tr() : '${frames[index - 1].index}', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: 10.sp, fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
}
