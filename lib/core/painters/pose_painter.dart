import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class PosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size absoluteImageSize;
  final InputImageRotation rotation;
  final bool isFrontCamera;

  PosePainter(
      this.poses, this.absoluteImageSize, this.rotation, this.isFrontCamera);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..color = Colors.greenAccent;
    final leftPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..color = Colors.yellowAccent;
    final rightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..color = Colors.lightBlueAccent;
    final jointPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white;

    for (final pose in poses) {
      // Eklem Noktalarını (Yuvarlaklar) Çiz
      pose.landmarks.forEach((_, landmark) {
        final x = translateX(landmark.x, size, absoluteImageSize);
        final y = translateY(landmark.y, size, absoluteImageSize);
        canvas.drawCircle(Offset(x, y), 4.0, jointPaint);
      });

      //Kemikleri Çiz
      void paintLine(
          PoseLandmarkType type1, PoseLandmarkType type2, Paint paintType) {
        final joint1 = pose.landmarks[type1];
        final joint2 = pose.landmarks[type2];
        if (joint1 != null && joint2 != null) {
          canvas.drawLine(
            Offset(translateX(joint1.x, size, absoluteImageSize),
                translateY(joint1.y, size, absoluteImageSize)),
            Offset(translateX(joint2.x, size, absoluteImageSize),
                translateY(joint2.y, size, absoluteImageSize)),
            paintType,
          );
        }
      }

      // Kollar
      paintLine(
          PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow, leftPaint);
      paintLine(
          PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist, leftPaint);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow,
          rightPaint);
      paintLine(
          PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist, rightPaint);

      // Gövde
      paintLine(
          PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder, paint);
      paintLine(
          PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip, leftPaint);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip,
          rightPaint);
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.rightHip, paint);

      // Bacaklar
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee, leftPaint);
      paintLine(
          PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle, leftPaint);
      paintLine(
          PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee, rightPaint);
      paintLine(
          PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle, rightPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return oldDelegate.absoluteImageSize != absoluteImageSize ||
        oldDelegate.poses != poses;
  }

  // x ekseni - Ayna Efekti ve Oranlama Düzeltmesi
  double translateX(double x, Size canvasSize, Size imageSize) {
    double scaledX = x * canvasSize.width / imageSize.width;
    return isFrontCamera
        ? canvasSize.width - scaledX
        : scaledX; // Ön kameraysa ekseni ters çevir!
  }

  // y ekseni - Oranlama Düzeltmesi
  double translateY(double y, Size canvasSize, Size imageSize) {
    return y * canvasSize.height / imageSize.height;
  }
}
