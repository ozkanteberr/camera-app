import 'package:camera_app/screens/ocr_screen.dart';
import 'package:camera_app/screens/panorama_screen.dart';
import 'package:camera_app/screens/pose_screen.dart';
import 'package:camera_app/screens/smart_selfie_screen.dart';
import 'package:camera_app/screens/surface_scan_screen.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil_plus/flutter_screenutil_plus.dart';
import 'camera_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: Text(
          "ML Kit Laboratuvarı",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18.sp),
        ),
        centerTitle: true,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          PopupMenuButton<Locale>(
            icon: Icon(Icons.language, size: 24.r),
            onSelected: (Locale locale) => context.setLocale(locale),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: Locale('tr', 'TR'),
                child: Text("🇹🇷 Türkçe"),
              ),
              PopupMenuItem(
                value: Locale('en', 'US'),
                child: Text("🇺🇸 English"),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 620 ||
                MediaQuery.orientationOf(context) == Orientation.landscape;
            final horizontalPadding = isWide ? 28.w : 20.w;
            final cardGap = isWide ? 14.w : 16.h;
            final cardWidth = isWide
                ? (constraints.maxWidth - (horizontalPadding * 2) - cardGap) / 2
                : constraints.maxWidth - (horizontalPadding * 2);

            final cards = [
              _buildMenuCard(
                context,
                width: cardWidth,
                title: "face_detection_title".tr(),
                subtitle: "face_detection_subtitle".tr(),
                icon: Icons.face_retouching_natural,
                color: Colors.blueAccent,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const CameraScreen()),
                  );
                },
              ),
              _buildMenuCard(
                context,
                width: cardWidth,
                title: "text_recognition_title".tr(),
                subtitle: "text_recognition_subtitle".tr(),
                icon: Icons.document_scanner,
                color: Colors.orangeAccent,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const OCRScreen()),
                  );
                },
              ),
              _buildMenuCard(
                context,
                width: cardWidth,
                title: "pose_detection_title".tr(),
                subtitle: "pose_detection_subtitle".tr(),
                icon: Icons.accessibility_new,
                color: Colors.greenAccent,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const PoseScreen()),
                  );
                },
              ),
              _buildMenuCard(
                context,
                width: cardWidth,
                title: "smart_selfie_title".tr(),
                subtitle: "smart_selfie_subtitle".tr(),
                icon: Icons.photo_camera_front_outlined,
                color: Colors.yellowAccent,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const SmartSelfieScreen()),
                  );
                },
              ),
              _buildMenuCard(
                context,
                width: cardWidth,
                title: "panorama_title".tr(),
                subtitle: "panorama_subtitle".tr(),
                icon: Icons.panorama_photosphere_rounded,
                color: Colors.purpleAccent,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const PanoramaScreen()),
                  );
                },
              ),
              _buildMenuCard(
                context,
                width: cardWidth,
                title: "surface_scan_title".tr(),
                subtitle: "surface_scan_subtitle".tr(),
                icon: Icons.view_in_ar_rounded,
                color: Colors.tealAccent,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const SurfaceScanScreen()),
                  );
                },
              ),
            ];

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                20.h,
                horizontalPadding,
                24.h,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    "home_screen_title".tr(),
                    style: TextStyle(color: Colors.white70, fontSize: 16.sp),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: isWide ? 18.h : 30.h),
                  Wrap(
                    spacing: isWide ? cardGap : 0,
                    runSpacing: isWide ? 14.h : 16.h,
                    children: cards,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildMenuCard(
    BuildContext context, {
    required double width,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: width,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: 96.h),
          padding: EdgeInsets.all(18.r),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(15.r),
            border: Border.all(color: color.withOpacity(0.35), width: 1.r),
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(12.r),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 30.r),
              ),
              SizedBox(width: 16.w),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17.sp,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4.h),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13.sp,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8.w),
              Icon(Icons.arrow_forward_ios, color: Colors.white30, size: 15.r),
            ],
          ),
        ),
      ),
    );
  }
}
