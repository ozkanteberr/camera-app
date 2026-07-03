import 'package:camera/camera.dart';
import 'package:camera_app/providers/camera_provider.dart';
import 'package:camera_app/providers/smart_selfie_provider.dart';
import 'package:camera_app/screens/gallery_screen.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'package:provider/provider.dart';

class SmartSelfieScreen extends StatefulWidget {
  const SmartSelfieScreen({super.key});

  @override
  State<SmartSelfieScreen> createState() => _SmartSelfieScreenState();
}

class _SmartSelfieScreenState extends State<SmartSelfieScreen> {
  late final SmartSelfieProvider _smartSelfieProvider;

  @override
  void initState() {
    super.initState();
    _smartSelfieProvider = context.read<SmartSelfieProvider>();
    Future.microtask(() async {
      final provider = _smartSelfieProvider;
      provider.setSpokenMessages(_spokenMessages());
      await provider.setVoiceLanguage(context.locale.toLanguageTag());
      provider.setViewActive(true);
      await provider.initializeCameras();
    });
  }

  @override
  void dispose() {
    _smartSelfieProvider.releaseResources();
    super.dispose();
  }

  Map<String, String> _spokenMessages() {
    return {
      'duz_bak': 'duz_bak'.tr(),
      'saga_cevir': 'saga_cevir'.tr(),
      'sola_cevir': 'sola_cevir'.tr(),
      'yuz_bulunamadi': 'yuz_bulunamadi'.tr(),
      'multiple_faces': 'multiple_faces'.tr(),
      'yukari_kaldir': 'yukari_kaldir'.tr(),
      'asagi_indir': 'asagi_indir'.tr(),
      'harika_bekle': 'harika_bekle'.tr(),
      'cekiliyor': 'cekiliyor'.tr(),
      'kaydedildi': 'kaydedildi'.tr(),
    };
  }

  Future<void> _openGallery() async {
    final smartSelfieProvider = _smartSelfieProvider;
    final cameraProvider = context.read<CameraProvider>();

    await smartSelfieProvider.releaseResources();
    cameraProvider.loadSavedPhotos();

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GalleryScreen()),
    );

    if (!mounted) return;
    smartSelfieProvider.setSpokenMessages(_spokenMessages());
    await smartSelfieProvider.setVoiceLanguage(context.locale.toLanguageTag());
    smartSelfieProvider.setViewActive(true);
    await smartSelfieProvider.initializeCameras();
  }

  Future<void> _closeScreen() async {
    final navigator = Navigator.of(context);
    await _smartSelfieProvider.releaseResources();
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _smartSelfieProvider.releaseResources();
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Consumer<SmartSelfieProvider>(
          builder: (context, provider, child) {
            if (!provider.isInitialized || provider.controller == null) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.yellowAccent),
              );
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(provider.controller!),
                if (provider.faceBoundingBox != null &&
                    provider.cameraImageSize != null)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: SmartSelfieFacePainter(
                        faceBox: provider.faceBoundingBox!,
                        imageSize: provider.cameraImageSize!,
                        isFrontCamera:
                            provider.controller!.description.lensDirection ==
                                CameraLensDirection.front,
                      ),
                    ),
                  ),
                _buildTopActions(),
                _buildGuidancePanel(provider),
                if (provider.countdown != null) _buildCountdown(provider),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopActions() {
    return Positioned(
      top: 50.h,
      left: 20.w,
      right: 20.w,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildCircleButton(
            icon: Icons.arrow_back_ios_new,
            onPressed: _closeScreen,
          ),
          _buildCircleButton(
            icon: Icons.photo_library,
            onPressed: _openGallery,
          ),
        ],
      ),
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 22.r),
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildGuidancePanel(SmartSelfieProvider provider) {
    return Positioned(
      left: 24.w,
      right: 24.w,
      bottom: 48.h,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.62),
          borderRadius: BorderRadius.circular(28.r),
          border: Border.all(color: Colors.yellowAccent.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            Icon(
              _iconForGuidance(provider.guidanceKey),
              color: Colors.yellowAccent,
              size: 30.r,
            ),
            SizedBox(width: 14.w),
            Expanded(
              child: Text(
                provider.guidanceKey.tr(),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountdown(SmartSelfieProvider provider) {
    return Center(
      child: Container(
        width: 132.r,
        height: 132.r,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.58),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3.r),
        ),
        child: Text(
          provider.countdown.toString(),
          style: TextStyle(
            color: Colors.white,
            fontSize: 64.sp,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  IconData _iconForGuidance(String key) {
    switch (key) {
      case 'saga_cevir':
        return Icons.turn_right;
      case 'sola_cevir':
        return Icons.turn_left;
      case 'multiple_faces':
        return Icons.groups;
      case 'yukari_kaldir':
        return Icons.keyboard_arrow_up;
      case 'asagi_indir':
        return Icons.keyboard_arrow_down;
      case 'harika_bekle':
        return Icons.check_circle_outline;
      case 'cekiliyor':
        return Icons.camera;
      case 'kaydedildi':
        return Icons.done_all;
      case 'yuz_bulunamadi':
        return Icons.face_retouching_off;
      default:
        return Icons.face;
    }
  }
}

class SmartSelfieFacePainter extends CustomPainter {
  final Rect faceBox;
  final Size imageSize;
  final bool isFrontCamera;

  const SmartSelfieFacePainter({
    required this.faceBox,
    required this.imageSize,
    required this.isFrontCamera,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = _scaleRect(faceBox, size, imageSize).inflate(12.r);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.r
      ..color = Colors.yellowAccent;
    final centerPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white;

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(12.r)),
      paint,
    );
    canvas.drawCircle(rect.center, 5, centerPaint);
    canvas.drawLine(
      Offset(rect.center.dx - 14, rect.center.dy),
      Offset(rect.center.dx + 14, rect.center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(rect.center.dx, rect.center.dy - 14),
      Offset(rect.center.dx, rect.center.dy + 14),
      paint,
    );
  }

  Rect _scaleRect(Rect rect, Size canvasSize, Size sourceSize) {
    final scale = (canvasSize.width / sourceSize.width) >
            (canvasSize.height / sourceSize.height)
        ? canvasSize.width / sourceSize.width
        : canvasSize.height / sourceSize.height;
    final paintedSize = Size(
      sourceSize.width * scale,
      sourceSize.height * scale,
    );
    final offset = Offset(
      (canvasSize.width - paintedSize.width) / 2,
      (canvasSize.height - paintedSize.height) / 2,
    );

    final scaleX = paintedSize.width / sourceSize.width;
    final scaleY = paintedSize.height / sourceSize.height;
    final left = rect.left * scaleX + offset.dx;
    final right = rect.right * scaleX + offset.dx;
    final top = rect.top * scaleY + offset.dy;
    final bottom = rect.bottom * scaleY + offset.dy;

    if (!isFrontCamera) {
      return Rect.fromLTRB(left, top, right, bottom);
    }

    return Rect.fromLTRB(
      canvasSize.width - right,
      top,
      canvasSize.width - left,
      bottom,
    );
  }

  @override
  bool shouldRepaint(covariant SmartSelfieFacePainter oldDelegate) {
    return oldDelegate.faceBox != faceBox ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.isFrontCamera != isFrontCamera;
  }
}
