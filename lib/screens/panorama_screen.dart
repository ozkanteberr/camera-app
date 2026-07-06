import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:provider/provider.dart';
import 'package:easy_localization/easy_localization.dart';

import '../providers/panorama_provider.dart';
import '../providers/camera_provider.dart';
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
    _panoramaProvider.releaseResources(notify: false);
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
                  child: CircularProgressIndicator(color: Colors.blueAccent));
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(provider.controller!),
                Center(child: _buildFrameStrip(provider)),

                _buildGuidancePanel(provider),

                // Üst Bar Butonları
                Positioned(
                  top: 50.h,
                  left: 20.w,
                  child: _buildCircleButton(
                      Icons.arrow_back_ios_new, () => Navigator.pop(context)),
                ),
                Positioned(
                  top: 50.h,
                  right: 20.w,
                  child: _buildCircleButton(Icons.photo_library, _openGallery),
                ),

                // Alt Kısım - Çekim Kontrolleri
                Positioned(
                  bottom: 40.h,
                  left: 0,
                  right: 0,
                  child: Column(
                    children: [
                      // Kaç kare çekildiğini gösteren sayaç
                      if (provider.isCapturing)
                        Container(
                          margin: EdgeInsets.only(bottom: 20.h),
                          padding: EdgeInsets.symmetric(
                              horizontal: 16.w, vertical: 8.h),
                          decoration: BoxDecoration(
                            color: Colors.blueAccent.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(20.r),
                          ),
                          child: Text(
                            "${provider.frameCount} Kare Yakalandı",
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16.sp),
                          ),
                        ),

                      // Deklanşör / Durdur Butonu
                      GestureDetector(
                        onTap: () {
                          if (provider.isProcessing) return;
                          if (provider.isCapturing) {
                            provider.stopAndStitch();
                          } else {
                            provider.startCapture();
                          }
                        },
                        child: Container(
                          width: 72.r,
                          height: 72.r,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: provider.isCapturing
                                    ? Colors.redAccent
                                    : Colors.white,
                                width: 4.r),
                          ),
                          child: Container(
                            margin: EdgeInsets.all(6.r),
                            decoration: BoxDecoration(
                              color: provider.isProcessing
                                  ? Colors.grey
                                  : (provider.isCapturing
                                      ? Colors.redAccent
                                      : Colors.white),
                              shape: provider.isCapturing
                                  ? BoxShape.rectangle
                                  : BoxShape.circle,
                              borderRadius: provider.isCapturing
                                  ? BorderRadius.circular(10.r)
                                  : null,
                            ),
                            child: provider.isProcessing
                                ? Padding(
                                    padding: EdgeInsets.all(12.r),
                                    child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2.5.r),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildFrameStrip(PanoramaProvider provider) {
    final progress = (provider.frameCount / provider.progressTargetFrames).clamp(0.0, 1.0);

    return SizedBox(
      width: 300.w,
      height: 82.h,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final filledWidth = constraints.maxWidth * progress;
          final viewfinderWidth = 54.w;
          final viewfinderLeft = (filledWidth - viewfinderWidth / 2)
              .clamp(0.0, constraints.maxWidth - viewfinderWidth);

          return Stack(
            children: [
              Align(
                alignment: Alignment.center,
                child: Container(
                  height: 54.h,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.32),
                    borderRadius: BorderRadius.circular(8.r),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.45),
                      width: 1.2.r,
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: filledWidth,
                  height: 54.h,
                  decoration: BoxDecoration(
                    color: Colors.lightBlueAccent.withOpacity(0.28),
                    borderRadius: BorderRadius.circular(8.r),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 160),
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
                      width: 18.w,
                      height: 18.w,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withOpacity(0.9),
                          width: 1.5.r,
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
    );
  }
  Widget _buildCircleButton(IconData icon, VoidCallback onPressed) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 22.r),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildGuidancePanel(PanoramaProvider provider) {
    return Align(
      alignment: const Alignment(0.0, -0.65),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20.r),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 20.h),
            decoration: BoxDecoration(
              color: provider.guidanceKey == 'hold_phone_upright'
                  ? Colors.redAccent.withOpacity(0.5)
                  : Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(20.r),
              border: Border.all(
                  color: Colors.white.withOpacity(0.3), width: 1.5.r),
            ),
            child: Text(
              provider.guidanceKey.tr(),
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }
}
