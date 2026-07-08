import 'dart:async';
import 'dart:ui' show ImageFilter;

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

class SurfaceScanScreen extends StatefulWidget {
  const SurfaceScanScreen({super.key});

  @override
  State<SurfaceScanScreen> createState() => _SurfaceScanScreenState();
}

class _SurfaceScanScreenState extends State<SurfaceScanScreen> {
  static const String _planeTexturePath = 'assets/ar/gray_plane.png';

  ARSessionManager? _arSessionManager;
  Timer? _detectedTimer;

  final List<_SurfaceCapture> _captures = [];
  _SurfaceScanStage _stage = _SurfaceScanStage.starting;

  bool _isInitialized = false;
  bool _isCapturing = false;
  bool _showSettings = false;
  bool _showPlanes = true;
  bool _showFeaturePoints = false;
  int _planeCount = 0;
  int _captureSequence = 0;

  bool get _supportsAr {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void dispose() {
    _detectedTimer?.cancel();
    _arSessionManager?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supportsAr) return _buildUnsupportedScreen();

    return WillPopScope(
      onWillPop: () async {
        _arSessionManager?.dispose();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.horizontalAndVertical,
              permissionPromptDescription:
                  'surface_scan_camera_permission'.tr(),
              permissionPromptButtonText: 'confirm'.tr(),
            ),
            _buildTopBar(),
            _buildStatusPill(),
            _buildPlaneStateChip(),
            _buildThumbnailStrip(),
            _buildSideActions(),
            _buildSettingsPanel(),
            _buildBottomControls(),
            if (!_isInitialized) _buildLoadingOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildUnsupportedScreen() {
    return Scaffold(
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
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.34),
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(14.w, 10.h, 14.w, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildCircleButton(
              icon: Icons.arrow_back_ios_new,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: _captures.isEmpty ? 0 : 1,
              child: _buildCaptureCounter(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPill() {
    final isReady = _stage == _SurfaceScanStage.ready;
    final isDetected = _stage == _SurfaceScanStage.detected;

    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: EdgeInsets.only(top: 12.h),
          constraints: BoxConstraints(maxWidth: 300.w),
          padding: EdgeInsets.symmetric(horizontal: 18.w, vertical: 9.h),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.92),
            borderRadius: BorderRadius.circular(20.r),
            border: Border.all(
              color: isReady || isDetected
                  ? Colors.greenAccent.withOpacity(0.95)
                  : Colors.white.withOpacity(0.55),
              width: 1.2.r,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.22),
                blurRadius: 14.r,
                offset: Offset(0, 6.h),
              ),
            ],
          ),
          child: Text(
            _stageLabelKey.tr(),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isReady ? Colors.green.shade700 : Colors.grey.shade800,
              fontSize: 14.sp,
              fontWeight: FontWeight.w800,
            ),
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
            border: Border.all(
              color: hasPlane
                  ? Colors.greenAccent.withOpacity(0.55)
                  : Colors.white.withOpacity(0.18),
            ),
          ),
          child: Text(
            '${'surface_scan_planes'.tr()}: $_planeCount',
            style: TextStyle(
              color: hasPlane ? Colors.greenAccent : Colors.white70,
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnailStrip() {
    if (_captures.isEmpty) return const SizedBox.shrink();

    final latestCaptures = _captures.reversed.take(4).toList();

    return Positioned(
      top: 94.h,
      left: 10.w,
      child: Column(
        children: latestCaptures.map((capture) {
          return Container(
            width: 46.w,
            height: 62.h,
            margin: EdgeInsets.only(bottom: 7.h),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.48),
              borderRadius: BorderRadius.circular(6.r),
              border: Border.all(color: Colors.white, width: 1.r),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image(image: capture.imageProvider, fit: BoxFit.cover),
                Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    padding:
                        EdgeInsets.symmetric(horizontal: 4.w, vertical: 2.h),
                    color: Colors.black.withOpacity(0.55),
                    child: Text(
                      '${capture.index}',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSideActions() {
    return Positioned(
      right: 12.w,
      bottom: 128.h,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildPillAction(
            label: 'surface_scan_reset'.tr(),
            onPressed: _resetScan,
          ),
          SizedBox(height: 10.h),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: _captures.isEmpty ? 0 : 1,
            child: IgnorePointer(
              ignoring: _captures.isEmpty,
              child: _buildPillAction(
                label: 'surface_scan_show_report'.tr(),
                onPressed: _openReport,
              ),
            ),
          ),
        ],
      ),
    );
  }

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
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.64),
              borderRadius: BorderRadius.circular(14.r),
              border: Border.all(color: Colors.white.withOpacity(0.22)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'surface_scan_settings'.tr(),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 8.h),
                _buildSwitchRow(
                  label: 'surface_scan_show_planes'.tr(),
                  value: _showPlanes,
                  onChanged: (value) {
                    setState(() => _showPlanes = value);
                    _updateSessionSettings();
                  },
                ),
                _buildSwitchRow(
                  label: 'surface_scan_feature_points'.tr(),
                  value: _showFeaturePoints,
                  onChanged: (value) {
                    setState(() => _showFeaturePoints = value);
                    _updateSessionSettings();
                  },
                ),
                SizedBox(height: 8.h),
                Text(
                  '${'surface_scan_planes'.tr()}: $_planeCount',
                  style: TextStyle(color: Colors.white70, fontSize: 12.sp),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final canCapture = _stage == _SurfaceScanStage.ready;

    return Positioned(
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
              bottom: 0,
              child: _buildSettingsButton(),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: canCapture ? 1 : 0.42,
              child: GestureDetector(
                onTap: canCapture && !_isCapturing ? _takeSnapshot : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 74.r,
                  height: 74.r,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.26),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: canCapture ? Colors.white : Colors.white54,
                      width: 3.r,
                    ),
                  ),
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      width: 52.r,
                      height: 52.r,
                      decoration: BoxDecoration(
                        color: _isCapturing ? Colors.grey : Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: _isCapturing
                          ? Padding(
                              padding: EdgeInsets.all(13.r),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5.r,
                                color: Colors.black,
                              ),
                            )
                          : Icon(
                              Icons.camera_alt_rounded,
                              color: Colors.black,
                              size: 28.r,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsButton() {
    return GestureDetector(
      onTap: () => setState(() => _showSettings = !_showSettings),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42.r,
            height: 42.r,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.36),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.22)),
            ),
            child: Icon(Icons.settings, color: Colors.white, size: 22.r),
          ),
          SizedBox(height: 4.h),
          Text(
            'surface_scan_settings'.tr(),
            style: TextStyle(color: Colors.white, fontSize: 12.sp),
          ),
        ],
      ),
    );
  }

  Widget _buildCaptureCounter() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18.r),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 7.h),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.42),
            borderRadius: BorderRadius.circular(18.r),
            border: Border.all(color: Colors.white.withOpacity(0.22)),
          ),
          child: Text(
            '${_captures.length}',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14.sp,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Material(
          color: Colors.black.withOpacity(0.42),
          shape: const CircleBorder(),
          child: IconButton(
            icon: Icon(icon, color: Colors.white, size: 21.r),
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }

  Widget _buildPillAction({
    required String label,
    required VoidCallback onPressed,
  }) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: Colors.grey.shade500.withOpacity(0.72),
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(horizontal: 18.w, vertical: 9.h),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18.r),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.sp, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildSwitchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SizedBox(
      height: 38.h,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: 12.sp),
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeColor: Colors.greenAccent,
          ),
        ],
      ),
    );
  }

  String get _stageLabelKey {
    switch (_stage) {
      case _SurfaceScanStage.starting:
        return 'surface_scan_start';
      case _SurfaceScanStage.scanning:
        return 'surface_scan_area';
      case _SurfaceScanStage.detected:
        return 'surface_detected';
      case _SurfaceScanStage.ready:
        return 'tap_to_take_image';
    }
  }

  void _onARViewCreated(
    ARSessionManager arSessionManager,
    ARObjectManager arObjectManager,
    ARAnchorManager arAnchorManager,
    ARLocationManager arLocationManager,
  ) {
    _arSessionManager = arSessionManager;
    arSessionManager.onError = _handleArError;
    arSessionManager.onPlaneDetected = _handlePlaneDetected;
    _updateSessionSettings();
    arObjectManager.onInitialize();

    if (!mounted) return;
    setState(() {
      _isInitialized = true;
      _stage = _SurfaceScanStage.scanning;
    });
  }

  void _handleArError(String message) {
    if (!mounted) return;
    _showRawSnack(message);
  }

  void _handlePlaneDetected(int planeCount) {
    if (!mounted || planeCount <= 0) return;

    final shouldTransition = _stage == _SurfaceScanStage.starting ||
        _stage == _SurfaceScanStage.scanning;

    setState(() {
      _planeCount = planeCount;
      if (shouldTransition) _stage = _SurfaceScanStage.detected;
    });

    if (_showPlanes) {
      _arSessionManager?.showPlanes(true);
    }

    if (shouldTransition) {
      _detectedTimer?.cancel();
      _detectedTimer = Timer(const Duration(milliseconds: 850), () {
        if (!mounted) return;
        if (_stage == _SurfaceScanStage.detected) {
          setState(() => _stage = _SurfaceScanStage.ready);
        }
      });
    }
  }

  Future<void> _takeSnapshot() async {
    final manager = _arSessionManager;
    if (manager == null || _stage != _SurfaceScanStage.ready) {
      _showSnack('surface_scan_detect_first');
      return;
    }
    if (_isCapturing) return;

    setState(() => _isCapturing = true);

    try {
      final imageProvider = await manager.snapshot();
      if (!mounted) return;
      await precacheImage(imageProvider, context);
      if (!mounted) return;

      setState(() {
        _captureSequence += 1;
        _captures.add(
          _SurfaceCapture(
            index: _captureSequence,
            imageProvider: imageProvider,
          ),
        );
      });
    } catch (_) {
      if (mounted) _showSnack('surface_scan_capture_failed');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _resetScan() {
    _detectedTimer?.cancel();
    setState(() {
      _captures.clear();
      _captureSequence = 0;
      _planeCount = 0;
      _stage = _isInitialized
          ? _SurfaceScanStage.scanning
          : _SurfaceScanStage.starting;
    });
    _updateSessionSettings();
  }

  Future<void> _openReport() async {
    if (_captures.isEmpty) return;

    _arSessionManager?.disableCamera();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SurfaceScanReportScreen(
          captures: List.unmodifiable(_captures),
        ),
      ),
    );
    if (mounted) _arSessionManager?.enableCamera();
  }

  void _updateSessionSettings() {
    final manager = _arSessionManager;
    if (manager == null) return;

    manager.onInitialize(
      showAnimatedGuide: false,
      showFeaturePoints: _showFeaturePoints,
      showPlanes: _showPlanes && _planeCount > 0,
      customPlaneTexturePath: _planeTexturePath,
      showWorldOrigin: false,
      handleTaps: false,
    );
  }

  void _showSnack(String key) => _showRawSnack(key.tr());

  void _showRawSnack(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

enum _SurfaceScanStage { starting, scanning, detected, ready }

class _SurfaceCapture {
  const _SurfaceCapture({
    required this.index,
    required this.imageProvider,
  });

  final int index;
  final ImageProvider<Object> imageProvider;
}

class _SurfaceScanReportScreen extends StatefulWidget {
  const _SurfaceScanReportScreen({required this.captures});

  final List<_SurfaceCapture> captures;

  @override
  State<_SurfaceScanReportScreen> createState() =>
      _SurfaceScanReportScreenState();
}

class _SurfaceScanReportScreenState extends State<_SurfaceScanReportScreen> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final captures = widget.captures;

    return Scaffold(
      backgroundColor: const Color(0xFF171717),
      appBar: AppBar(
        title: Text('surface_scan_preview'.tr()),
        centerTitle: true,
        backgroundColor: const Color(0xFF171717),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: captures.isEmpty
            ? Center(
                child: Text(
                  'surface_scan_no_capture'.tr(),
                  style: TextStyle(color: Colors.white70, fontSize: 15.sp),
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: Center(
                      child: InteractiveViewer(
                        minScale: 1,
                        maxScale: 4,
                        child: Image(
                          image: captures[_selectedIndex].imageProvider,
                          fit: BoxFit.contain,
                          width: double.infinity,
                        ),
                      ),
                    ),
                  ),
                  _buildReportStrip(captures),
                ],
              ),
      ),
    );
  }

  Widget _buildReportStrip(List<_SurfaceCapture> captures) {
    return Container(
      height: 112.h,
      padding: EdgeInsets.fromLTRB(12.w, 10.h, 12.w, 16.h),
      color: Colors.black.withOpacity(0.30),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: captures.length,
        separatorBuilder: (_, __) => SizedBox(width: 10.w),
        itemBuilder: (context, index) {
          final capture = captures[index];
          final selected = index == _selectedIndex;

          return GestureDetector(
            onTap: () => setState(() => _selectedIndex = index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 68.w,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color: selected ? Colors.greenAccent : Colors.white24,
                  width: selected ? 2.r : 1.r,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image(image: capture.imageProvider, fit: BoxFit.cover),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(vertical: 3.h),
                      color: Colors.black.withOpacity(0.62),
                      child: Text(
                        '${capture.index}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11.sp,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
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
}
