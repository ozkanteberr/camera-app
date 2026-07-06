import 'dart:async';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:provider/provider.dart';

import '../providers/camera_provider.dart';
import '../providers/panorama_provider.dart';
import 'gallery_screen.dart';

class PanoramaScreen extends StatefulWidget {
  const PanoramaScreen({super.key});

  @override
  State<PanoramaScreen> createState() => _PanoramaScreenState();
}

class _PanoramaScreenState extends State<PanoramaScreen> {
  late final PanoramaProvider _panoramaProvider;

  @override
  void initState() {
    super.initState();
    _panoramaProvider = context.read<PanoramaProvider>();
    Future.microtask(() async {
      _panoramaProvider.setViewActive(true);
      await _panoramaProvider.initializeCameras();
    });
  }

  @override
  void dispose() {
    unawaited(_panoramaProvider.releaseResources(notify: false));
    super.dispose();
  }

  Future<void> _openGallery() async {
    final cameraProvider = context.read<CameraProvider>();
    await _panoramaProvider.releaseResources();
    cameraProvider.loadSavedPhotos();

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GalleryScreen()),
    );

    if (!mounted) return;
    _panoramaProvider.setViewActive(true);
    await _panoramaProvider.initializeCameras();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _panoramaProvider.releaseResources();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Consumer<PanoramaProvider>(
          builder: (context, provider, child) {
            if (!provider.isInitialized || provider.controller == null) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.white),
              );
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(provider.controller!),
                _buildTopBar(provider),
                _buildGuidancePanel(provider),
                _buildFrameStrip(provider),
                _buildBottomControls(provider),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopBar(PanoramaProvider provider) {
    return Positioned(
      top: 46.h,
      left: 16.w,
      right: 16.w,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildCircleButton(
            Icons.arrow_back_ios_new,
            provider.isProcessing
                ? null
                : () => Navigator.of(context).maybePop(),
          ),
          _buildCircleButton(
            Icons.photo_library_outlined,
            provider.isProcessing ? null : _openGallery,
          ),
        ],
      ),
    );
  }

  Widget _buildFrameStrip(PanoramaProvider provider) {
    final progress = provider.captureProgress;

    return Align(
      alignment: const Alignment(0.0, 0.26),
      child: SizedBox(
        width: 310.w,
        height: 86.h,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final filledWidth = constraints.maxWidth * progress;
            final viewfinderWidth = 54.w;
            final viewfinderLeft = (filledWidth - viewfinderWidth / 2)
                .clamp(0.0, constraints.maxWidth - viewfinderWidth)
                .toDouble();

            return Stack(
              children: [
                Align(
                  alignment: Alignment.center,
                  child: Container(
                    height: 48.h,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.30),
                      borderRadius: BorderRadius.circular(8.r),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.45),
                        width: 1.1.r,
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    width: filledWidth,
                    height: 48.h,
                    decoration: BoxDecoration(
                      color: provider.canFinishCapture
                          ? Colors.greenAccent.withOpacity(0.28)
                          : Colors.lightBlueAccent.withOpacity(0.26),
                      borderRadius: BorderRadius.circular(8.r),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  left: viewfinderLeft,
                  top: 0,
                  child: Container(
                    width: viewfinderWidth,
                    height: constraints.maxHeight,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8.r),
                      border: Border.all(color: Colors.white, width: 2.r),
                      color: Colors.white.withOpacity(0.08),
                    ),
                    child: Center(
                      child: Container(
                        width: 16.w,
                        height: 16.w,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withOpacity(0.95),
                            width: 1.4.r,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBottomControls(PanoramaProvider provider) {
    return Positioned(
      bottom: 34.h,
      left: 0,
      right: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedOpacity(
            opacity: provider.isCapturing || provider.isProcessing ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Container(
              margin: EdgeInsets.only(bottom: 16.h),
              padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 7.h),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.52),
                borderRadius: BorderRadius.circular(18.r),
                border: Border.all(color: Colors.white.withOpacity(0.22)),
              ),
              child: Text(
                '${provider.frameCount}/${provider.progressTargetFrames}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              if (provider.isProcessing) return;
              if (provider.isCapturing) {
                unawaited(provider.stopAndStitch());
              } else {
                unawaited(provider.startCapture());
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 74.r,
              height: 74.r,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: provider.isCapturing ? Colors.redAccent : Colors.white,
                  width: 4.r,
                ),
                color: Colors.black.withOpacity(0.12),
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: provider.isCapturing ? 30.r : 56.r,
                  height: provider.isCapturing ? 30.r : 56.r,
                  decoration: BoxDecoration(
                    color: provider.isProcessing
                        ? Colors.grey
                        : provider.isCapturing
                            ? Colors.redAccent
                            : Colors.white,
                    shape: provider.isCapturing ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius:
                        provider.isCapturing ? BorderRadius.circular(8.r) : null,
                  ),
                  child: provider.isProcessing
                      ? Padding(
                          padding: EdgeInsets.all(10.r),
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.4.r,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCircleButton(IconData icon, VoidCallback? onPressed) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Material(
          color: Colors.black.withOpacity(onPressed == null ? 0.18 : 0.42),
          shape: const CircleBorder(),
          child: IconButton(
            icon: Icon(
              icon,
              color: Colors.white.withOpacity(onPressed == null ? 0.42 : 1),
              size: 22.r,
            ),
            onPressed: onPressed,
          ),
        ),
      ),
    );
  }

  Widget _buildGuidancePanel(PanoramaProvider provider) {
    final isWarning = provider.guidanceKey == 'hold_phone_upright' ||
        provider.guidanceKey == 'panorama_rotate_slower' ||
        provider.guidanceKey == 'panorama_need_more_frames' ||
        provider.guidanceKey == 'merge_failed';

    return Align(
      alignment: const Alignment(0.0, -0.62),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18.r),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            constraints: BoxConstraints(maxWidth: 330.w),
            padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 14.h),
            decoration: BoxDecoration(
              color: isWarning
                  ? Colors.redAccent.withOpacity(0.48)
                  : Colors.black.withOpacity(0.46),
              borderRadius: BorderRadius.circular(18.r),
              border: Border.all(
                color: Colors.white.withOpacity(0.28),
                width: 1.2.r,
              ),
            ),
            child: Text(
              provider.guidanceKey.tr(),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16.sp,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}