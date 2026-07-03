import 'package:camera_app/core/painters/pose_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import '../providers/pose_provider.dart';

class PoseScreen extends StatefulWidget {
  const PoseScreen({super.key});

  @override
  State<PoseScreen> createState() => _PoseScreenState();
}

class _PoseScreenState extends State<PoseScreen> {
  late final PoseProvider _poseProvider;

  @override
  void initState() {
    super.initState();
    _poseProvider = context.read<PoseProvider>();
    Future.microtask(() async {
      _poseProvider.setViewActive(true);
      await _poseProvider.initializeCameras();
    });
  }

  @override
  void dispose() {
    _poseProvider.releaseResources(notify: false);
    super.dispose();
  }

  Future<void> _closeScreen() async {
    final navigator = Navigator.of(context);
    await _poseProvider.releaseResources();
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _poseProvider.releaseResources();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Consumer<PoseProvider>(
          builder: (context, provider, child) {
            if (!provider.isInitialized || provider.controller == null) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.greenAccent),
              );
            }

            final previewSize = provider.controller!.value.previewSize!;
            final imageSize = Size(previewSize.height, previewSize.width);
            final lensDirection =
                provider.controller!.description.lensDirection;
            final rotation = lensDirection == CameraLensDirection.front
                ? InputImageRotation.rotation270deg
                : InputImageRotation.rotation90deg;
            final isFrontCamera = lensDirection == CameraLensDirection.front;

            return Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(provider.controller!),
                if (provider.poses.isNotEmpty)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: PosePainter(
                        provider.poses,
                        imageSize,
                        rotation,
                        isFrontCamera,
                      ),
                    ),
                  ),
                Positioned(
                  top: 50.h,
                  left: 20.w,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: Icon(Icons.arrow_back_ios_new,
                          color: Colors.white, size: 20.r),
                      onPressed: _closeScreen,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 40.h,
                  right: 30.w,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.greenAccent.withOpacity(0.5),
                          width: 2.r),
                    ),
                    child: IconButton(
                      icon: Icon(Icons.cameraswitch,
                          color: Colors.white, size: 28.r),
                      onPressed: () => provider.toggleCamera(),
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
}
