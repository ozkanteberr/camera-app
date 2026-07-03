import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:camera_app/providers/camera_provider.dart';
import 'package:camera_app/screens/gallery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:provider/provider.dart';
import 'package:easy_localization/easy_localization.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late final CameraProvider _cameraProvider;

  @override
  void initState() {
    super.initState();
    _cameraProvider = context.read<CameraProvider>();
    Future.microtask(() async {
      _cameraProvider.setViewActive(true);
      await _cameraProvider.initializeCameras();
    });
  }

  @override
  void dispose() {
    _cameraProvider.closeCamera(notify: false);
    super.dispose();
  }

  Future<void> _closeScreen() async {
    final navigator = Navigator.of(context);
    await _cameraProvider.closeCamera();
    if (mounted) navigator.pop();
  }

  Future<void> _openGallery() async {
    await _cameraProvider.closeCamera();
    _cameraProvider.loadSavedPhotos();

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GalleryScreen()),
    );

    if (!mounted) return;
    _cameraProvider.setViewActive(true);
    await _cameraProvider.initializeCameras();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _cameraProvider.closeCamera();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Consumer<CameraProvider>(
          builder: (context, provider, child) {
            if (!provider.isInitialized || provider.controller == null) {
              return const Center(
                  child: CircularProgressIndicator(color: Colors.white));
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: provider.capturedImage != null
                      ? Image.file(File(provider.capturedImage!.path),
                          fit: BoxFit.cover)
                      : CameraPreview(provider.controller!),
                ),
                if (provider.capturedImage == null)
                  Align(
                    alignment: const Alignment(0.0, -0.65),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20.r),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: 32.w, vertical: 20.h),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(20.r),
                            border: Border.all(
                                color: Colors.white.withOpacity(0.3),
                                width: 1.5.r),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                provider.guidanceKey == 'saga_cevir'
                                    ? Icons.turn_right
                                    : provider.guidanceKey == 'sola_cevir'
                                        ? Icons.turn_left
                                        : provider.guidanceKey ==
                                                'yuz_bulunamadi'
                                            ? Icons.face_retouching_off
                                            : Icons.face,
                                color: Colors.white,
                                size: 36.r,
                              ),
                              SizedBox(width: 16.w),
                              Text(provider.guidanceKey.tr(),
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 24.sp,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 50.h,
                  left: 20.w,
                  child: Container(
                    decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        shape: BoxShape.circle),
                    child: IconButton(
                      icon: Icon(Icons.arrow_back_ios_new,
                          color: Colors.white, size: 20.r),
                      onPressed: _closeScreen,
                    ),
                  ),
                ),
                Positioned(
                  top: 50.h,
                  right: 20.w,
                  child: Container(
                    decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        shape: BoxShape.circle),
                    child: IconButton(
                      icon: Icon(Icons.photo_library,
                          color: Colors.white, size: 22.r),
                      onPressed: _openGallery,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 40.h,
                  left: 20.w,
                  right: 20.w,
                  child: Container(
                    padding:
                        EdgeInsets.symmetric(horizontal: 20.w, vertical: 15.h),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(30.r),
                    ),
                    child: provider.capturedImage != null
                        ? _buildConfirmRow(provider)
                        : _buildCameraControls(provider),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildConfirmRow(CameraProvider provider) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        TextButton.icon(
          onPressed: () => provider.clearCapturedImage(),
          icon: Icon(Icons.close, color: Colors.redAccent),
          label: Text("cancel".tr(), style: TextStyle(color: Colors.redAccent)),
        ),
        ElevatedButton.icon(
          onPressed: () async => await provider.saveCapturedImage(),
          icon: Icon(Icons.check, color: Colors.white),
          label: Text("confirm".tr(), style: TextStyle(color: Colors.white)),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
        ),
      ],
    );
  }

  Widget _buildCameraControls(CameraProvider provider) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        PopupMenuButton<ResolutionPreset>(
          icon: Icon(Icons.hd, color: Colors.white, size: 26.r),
          color: Colors.black87,
          initialValue: provider.selectedResolution,
          onSelected: (value) => provider.changeResolution(value),
          itemBuilder: (context) => [
            PopupMenuItem(
                value: ResolutionPreset.low,
                child: Text("low".tr(), style: TextStyle(color: Colors.white))),
            PopupMenuItem(
                value: ResolutionPreset.medium,
                child:
                    Text("medium".tr(), style: TextStyle(color: Colors.white))),
            PopupMenuItem(
                value: ResolutionPreset.high,
                child:
                    Text("high".tr(), style: TextStyle(color: Colors.white))),
            PopupMenuItem(
                value: ResolutionPreset.max,
                child: Text("max".tr(), style: TextStyle(color: Colors.white))),
          ],
        ),
        GestureDetector(
          onTap: () => provider.isTakingPicture ? null : provider.takePicture(),
          child: Container(
            width: 66.r,
            height: 66.r,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3.r)),
            child: Container(
              margin: EdgeInsets.all(5.r),
              decoration: BoxDecoration(
                  color: provider.isTakingPicture ? Colors.grey : Colors.white,
                  shape: BoxShape.circle),
              child: provider.isTakingPicture
                  ? CircularProgressIndicator(
                      color: Colors.black, strokeWidth: 2.5.r)
                  : null,
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.cameraswitch, color: Colors.white, size: 26.r),
          onPressed: () => provider.toggleCamera(),
        ),
      ],
    );
  }
}
