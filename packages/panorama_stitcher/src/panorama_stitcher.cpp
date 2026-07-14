#include <opencv2/opencv.hpp>
#include <opencv2/stitching.hpp>
#include <android/log.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdint.h>
#include <vector>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "PanoramaEngine", __VA_ARGS__)

namespace {
constexpr size_t kMaxCapturedFrames = 18;
constexpr int kMaxFrameWidth = 960;
constexpr double kMinSharpness = 14.0;
constexpr double kMinFrameDifference = 3.0;

std::mutex frames_mutex;
std::vector<cv::Mat> captured_frames;
cv::Mat last_frame_signature;

constexpr size_t kMaxSurfaceFrames = 18;
constexpr double kSurfacePixelsPerMeter = 850.0;
constexpr int kMaxSurfaceFrameSide = 900;
constexpr int kMaxSurfaceCropSide = 1100;
constexpr int kMaxSurfaceOutputSide = 3200;

struct SurfaceFrame {
  cv::Mat image;
  std::vector<cv::Point2f> plane_points;
};

std::vector<SurfaceFrame> surface_frames;
int32_t current_frame_count() {
  std::lock_guard<std::mutex> lock(frames_mutex);
  return static_cast<int32_t>(captured_frames.size());
}

cv::Mat resize_for_stitching(const cv::Mat &bgr_img) {
  cv::Mat output_img;
  const int max_side = bgr_img.cols > bgr_img.rows ? bgr_img.cols : bgr_img.rows;
  if (max_side > kMaxFrameWidth) {
    const double scale = static_cast<double>(kMaxFrameWidth) / max_side;
    cv::resize(bgr_img, output_img, cv::Size(), scale, scale, cv::INTER_AREA);
  } else {
    output_img = bgr_img;
  }

  if (output_img.cols > output_img.rows) {
    cv::rotate(output_img, output_img, cv::ROTATE_90_CLOCKWISE);
  }

  return output_img;
}

bool build_signature_if_sharp(const cv::Mat &bgr_img, cv::Mat *signature) {
  cv::Mat gray;
  cv::cvtColor(bgr_img, gray, cv::COLOR_BGR2GRAY);
  cv::resize(gray, *signature, cv::Size(120, 160), 0, 0, cv::INTER_AREA);

  cv::Mat edges;
  cv::Laplacian(*signature, edges, CV_64F);
  cv::Scalar mean;
  cv::Scalar stddev;
  cv::meanStdDev(edges, mean, stddev);
  const double sharpness = stddev[0] * stddev[0];
  return sharpness >= kMinSharpness;
}

bool is_new_viewpoint_locked(const cv::Mat &signature) {
  if (last_frame_signature.empty()) {
    return true;
  }

  cv::Mat diff;
  cv::absdiff(signature, last_frame_signature, diff);
  return cv::mean(diff)[0] >= kMinFrameDifference;
}

int32_t add_bgr_frame(const cv::Mat &bgr_img, const char *log_label) {
  cv::Mat output_img = resize_for_stitching(bgr_img);
  cv::Mat signature;
  if (!build_signature_if_sharp(output_img, &signature)) {
    LOGI("%s frame skipped: blurry.", log_label);
    return current_frame_count();
  }

  std::lock_guard<std::mutex> lock(frames_mutex);
  if (captured_frames.size() >= kMaxCapturedFrames) {
    return static_cast<int32_t>(captured_frames.size());
  }

  if (!is_new_viewpoint_locked(signature)) {
    LOGI("%s frame skipped: too similar.", log_label);
    return static_cast<int32_t>(captured_frames.size());
  }

  captured_frames.push_back(output_img.clone());
  last_frame_signature = signature.clone();
  LOGI("%s frame accepted. Total frames: %d", log_label, (int)captured_frames.size());
  return static_cast<int32_t>(captured_frames.size());
}

cv::Mat resize_for_surface(const cv::Mat &bgr_img) {
  cv::Mat output_img;
  const int max_side = bgr_img.cols > bgr_img.rows ? bgr_img.cols : bgr_img.rows;
  if (max_side > kMaxSurfaceFrameSide) {
    const double scale = static_cast<double>(kMaxSurfaceFrameSide) / max_side;
    cv::resize(bgr_img, output_img, cv::Size(), scale, scale, cv::INTER_AREA);
  } else {
    output_img = bgr_img.clone();
  }
  return output_img;
}

cv::Rect mask_bounds(const cv::Mat &mask) {
  std::vector<cv::Point> points;
  cv::findNonZero(mask, points);
  if (points.empty()) return cv::Rect();
  return cv::boundingRect(points);
}

cv::Rect largest_covered_rectangle(const cv::Mat &mask) {
  if (mask.empty() || mask.type() != CV_8UC1) return cv::Rect();

  std::vector<int> heights(mask.cols, 0);
  cv::Rect best;
  int64_t best_area = 0;

  for (int y = 0; y < mask.rows; ++y) {
    const uint8_t *row = mask.ptr<uint8_t>(y);
    for (int x = 0; x < mask.cols; ++x) {
      heights[x] = row[x] != 0 ? heights[x] + 1 : 0;
    }

    std::vector<std::pair<int, int>> stack;
    stack.reserve(mask.cols);
    for (int x = 0; x <= mask.cols; ++x) {
      const int height = x < mask.cols ? heights[x] : 0;
      int start = x;
      while (!stack.empty() && stack.back().second > height) {
        const int bar_start = stack.back().first;
        const int bar_height = stack.back().second;
        stack.pop_back();
        const int64_t area = static_cast<int64_t>(bar_height) * (x - bar_start);
        if (area > best_area) {
          best_area = area;
          best = cv::Rect(bar_start, y - bar_height + 1, x - bar_start, bar_height);
        }
        start = bar_start;
      }
      if (height > 0 && (stack.empty() || stack.back().second < height)) {
        stack.emplace_back(start, height);
      }
    }
  }
  return best;
}

void crop_to_coverage(cv::Mat *image, cv::Mat *coverage) {
  if (image == nullptr || coverage == nullptr || image->empty() || coverage->empty()) return;

  const cv::Rect bounds = mask_bounds(*coverage);
  if (bounds.width <= 0 || bounds.height <= 0) return;
  cv::Mat safe_coverage;
  cv::threshold((*coverage)(bounds), safe_coverage, 250, 255, cv::THRESH_BINARY);
  cv::erode(
      safe_coverage,
      safe_coverage,
      cv::getStructuringElement(cv::MORPH_RECT, cv::Size(3, 3)));

  const cv::Rect local_solid = largest_covered_rectangle(safe_coverage);
  const bool solid_crop_is_usable = local_solid.width >= 32 &&
                                    local_solid.height >= 32 &&
                                    local_solid.area() >= bounds.area() * 0.22;
  const cv::Rect crop = solid_crop_is_usable
      ? cv::Rect(bounds.x + local_solid.x, bounds.y + local_solid.y, local_solid.width, local_solid.height)
      : bounds;

  LOGI("Surface coverage crop: bounds=%dx%d solid=%dx%d", bounds.width, bounds.height, crop.width, crop.height);
  *image = (*image)(crop).clone();
  *coverage = (*coverage)(crop).clone();
}

double clamp_double(double value, double min_value, double max_value) {
  return std::max(min_value, std::min(max_value, value));
}

int32_t encode_jpeg_result(const cv::Mat &image, uint8_t **output_image_bytes, int32_t *out_width, int32_t *out_height) {
  std::vector<uchar> buffer;
  const std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 88};
  if (!cv::imencode(".jpg", image, buffer, params) || buffer.empty()) {
    return 0;
  }

  uint8_t *native_buffer = static_cast<uint8_t *>(std::malloc(buffer.size()));
  if (native_buffer == nullptr) {
    return 0;
  }

  std::memcpy(native_buffer, buffer.data(), buffer.size());
  *output_image_bytes = native_buffer;
  *out_width = image.cols;
  *out_height = image.rows;
  return static_cast<int32_t>(buffer.size());
}
void crop_black_edges(cv::Mat *image) {
  if (image == nullptr || image->empty()) return;

  cv::Mat gray;
  cv::cvtColor(*image, gray, cv::COLOR_BGR2GRAY);

  cv::Mat mask;
  cv::threshold(gray, mask, 5, 255, cv::THRESH_BINARY);
  cv::morphologyEx(
      mask,
      mask,
      cv::MORPH_CLOSE,
      cv::getStructuringElement(cv::MORPH_RECT, cv::Size(7, 7)));

  std::vector<cv::Point> points;
  cv::findNonZero(mask, points);
  if (points.empty()) return;

  const cv::Rect bounds = cv::boundingRect(points);
  const bool usable_crop = bounds.width > image->cols * 0.45 &&
                           bounds.height > image->rows * 0.45 &&
                           bounds.area() < image->cols * image->rows;
  if (usable_crop) {
    *image = (*image)(bounds).clone();
  }
}
}

extern "C" {

__attribute__((visibility("default"))) __attribute__((used))
int32_t init_panorama_engine() {
  cv::setUseOptimized(true);
  cv::setNumThreads(2);
  LOGI("Panorama engine ready.");
  return 1;
}

__attribute__((visibility("default"))) __attribute__((used))
void clear_frames() {
  std::lock_guard<std::mutex> lock(frames_mutex);
  captured_frames.clear();
  captured_frames.reserve(kMaxCapturedFrames);
  last_frame_signature.release();
  LOGI("Frame memory cleared.");
}

__attribute__((visibility("default"))) __attribute__((used))
int32_t add_frame(uint8_t *image_bytes, int32_t width, int32_t height) {
  if (image_bytes == nullptr || width <= 0 || height <= 0) {
    LOGI("Invalid camera frame.");
    return -1;
  }

  if (current_frame_count() >= static_cast<int32_t>(kMaxCapturedFrames)) {
    return current_frame_count();
  }

  try {
    cv::Mat nv21_img(height + height / 2, width, CV_8UC1, image_bytes);
    cv::Mat bgr_img;
    cv::cvtColor(nv21_img, bgr_img, cv::COLOR_YUV2BGR_NV21);
    return add_bgr_frame(bgr_img, "NV21");
  } catch (const cv::Exception &e) {
    LOGI("OpenCV add_frame error: %s", e.what());
    return -2;
  } catch (...) {
    LOGI("Unknown add_frame error.");
    return -3;
  }
}

__attribute__((visibility("default"))) __attribute__((used))
int32_t add_encoded_frame(uint8_t *image_bytes, int32_t length) {
  if (image_bytes == nullptr || length <= 0) {
    LOGI("Invalid JPEG frame.");
    return -1;
  }

  if (current_frame_count() >= static_cast<int32_t>(kMaxCapturedFrames)) {
    return current_frame_count();
  }

  try {
    std::vector<uchar> buffer(image_bytes, image_bytes + length);
    cv::Mat bgr_img = cv::imdecode(buffer, cv::IMREAD_COLOR);
    if (bgr_img.empty()) {
      LOGI("JPEG decode failed.");
      return -2;
    }

    return add_bgr_frame(bgr_img, "JPEG");
  } catch (const cv::Exception &e) {
    LOGI("OpenCV JPEG add error: %s", e.what());
    return -3;
  } catch (...) {
    LOGI("Unknown JPEG add error.");
    return -4;
  }
}

__attribute__((visibility("default"))) __attribute__((used))
int32_t process_panorama(uint8_t **output_image_bytes, int32_t *out_width, int32_t *out_height) {
  if (output_image_bytes == nullptr || out_width == nullptr || out_height == nullptr) {
    return -1;
  }

  *output_image_bytes = nullptr;
  *out_width = 0;
  *out_height = 0;

  std::vector<cv::Mat> frames_snapshot;
  {
    std::lock_guard<std::mutex> lock(frames_mutex);
    if (captured_frames.size() < 2) {
      LOGI("Not enough frames for stitching.");
      return -2;
    }

    frames_snapshot.reserve(captured_frames.size());
    for (const cv::Mat &frame : captured_frames) {
      if (!frame.empty()) {
        frames_snapshot.push_back(frame.clone());
      }
    }
    captured_frames.clear();
    captured_frames.reserve(kMaxCapturedFrames);
    last_frame_signature.release();
  }

  if (frames_snapshot.size() < 2) {
    return -3;
  }

  try {
    LOGI("Stitching started. Frame count: %d", (int)frames_snapshot.size());

    cv::Ptr<cv::Stitcher> stitcher = cv::Stitcher::create(cv::Stitcher::SCANS);
    stitcher->setRegistrationResol(0.45);
    stitcher->setSeamEstimationResol(0.08);
    stitcher->setCompositingResol(0.8);
    stitcher->setPanoConfidenceThresh(0.45);

    cv::Mat result_img;
    cv::Stitcher::Status status = stitcher->stitch(frames_snapshot, result_img);

    if (status != cv::Stitcher::OK || result_img.empty()) {
      LOGI("SCANS failed. Code: %d. Trying PANORAMA.", int(status));
      cv::Ptr<cv::Stitcher> fallback_stitcher = cv::Stitcher::create(cv::Stitcher::PANORAMA);
      fallback_stitcher->setRegistrationResol(0.45);
      fallback_stitcher->setSeamEstimationResol(0.08);
      fallback_stitcher->setCompositingResol(0.8);
      fallback_stitcher->setPanoConfidenceThresh(0.45);
      result_img.release();
      status = fallback_stitcher->stitch(frames_snapshot, result_img);
    }

    if (status != cv::Stitcher::OK || result_img.empty()) {
      LOGI("Stitching failed. OpenCV status: %d", int(status));
      return -4;
    }

    crop_black_edges(&result_img);

    std::vector<uchar> buffer;
    const std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, 92};
    if (!cv::imencode(".jpg", result_img, buffer, params) || buffer.empty()) {
      LOGI("JPG encoding failed.");
      return -5;
    }

    uint8_t *native_buffer = static_cast<uint8_t *>(std::malloc(buffer.size()));
    if (native_buffer == nullptr) {
      LOGI("Could not allocate output buffer.");
      return -6;
    }

    std::memcpy(native_buffer, buffer.data(), buffer.size());
    *output_image_bytes = native_buffer;
    *out_width = result_img.cols;
    *out_height = result_img.rows;

    LOGI("Stitching complete. Output: %d x %d", result_img.cols, result_img.rows);
    return static_cast<int32_t>(buffer.size());
  } catch (const cv::Exception &e) {
    LOGI("OpenCV stitching error: %s", e.what());
    return -7;
  } catch (...) {
    LOGI("Unknown stitching error.");
    return -8;
  }
}

__attribute__((visibility("default"))) __attribute__((used))
int32_t crop_encoded_image(
    uint8_t *image_bytes,
    int32_t length,
    double left,
    double top,
    double right,
    double bottom,
    int32_t screen_width,
    int32_t screen_height,
    uint8_t **output_image_bytes,
    int32_t *out_width,
    int32_t *out_height) {
  if (image_bytes == nullptr || length <= 0 || output_image_bytes == nullptr || out_width == nullptr || out_height == nullptr) {
    return -1;
  }

  *output_image_bytes = nullptr;
  *out_width = 0;
  *out_height = 0;

  try {
    std::vector<uchar> buffer(image_bytes, image_bytes + length);
    cv::Mat decoded_img = cv::imdecode(buffer, cv::IMREAD_COLOR);
    if (decoded_img.empty()) {
      LOGI("Crop image decode failed.");
      return -2;
    }

    if (screen_width > 0 && screen_height > 0 && decoded_img.cols > decoded_img.rows && screen_height > screen_width) {
      cv::rotate(decoded_img, decoded_img, cv::ROTATE_90_CLOCKWISE);
    }

    const double crop_left = clamp_double(left, 0.0, 1.0);
    const double crop_top = clamp_double(top, 0.0, 1.0);
    const double crop_right = clamp_double(right, crop_left + 0.001, 1.0);
    const double crop_bottom = clamp_double(bottom, crop_top + 0.001, 1.0);

    const int src_left = std::max(0, std::min(decoded_img.cols - 1, static_cast<int>(std::floor(crop_left * decoded_img.cols))));
    const int src_top = std::max(0, std::min(decoded_img.rows - 1, static_cast<int>(std::floor(crop_top * decoded_img.rows))));
    const int src_right = std::max(src_left + 1, std::min(decoded_img.cols, static_cast<int>(std::ceil(crop_right * decoded_img.cols))));
    const int src_bottom = std::max(src_top + 1, std::min(decoded_img.rows, static_cast<int>(std::ceil(crop_bottom * decoded_img.rows))));
    const cv::Rect crop_rect(src_left, src_top, src_right - src_left, src_bottom - src_top);

    cv::Mat cropped = decoded_img(crop_rect);
    cv::Mat output_img;
    const int max_side = cropped.cols > cropped.rows ? cropped.cols : cropped.rows;
    if (max_side > kMaxSurfaceCropSide) {
      const double scale = static_cast<double>(kMaxSurfaceCropSide) / max_side;
      cv::resize(cropped, output_img, cv::Size(), scale, scale, cv::INTER_AREA);
    } else {
      output_img = cropped.clone();
    }

    const int32_t encoded_size = encode_jpeg_result(output_img, output_image_bytes, out_width, out_height);
    if (encoded_size <= 0) {
      LOGI("Crop JPG encoding failed.");
      return -3;
    }
    return encoded_size;
  } catch (const cv::Exception &e) {
    LOGI("OpenCV crop error: %s", e.what());
    return -4;
  } catch (...) {
    LOGI("Unknown crop error.");
    return -5;
  }
}
__attribute__((visibility("default"))) __attribute__((used))
void clear_surface_frames() {
  std::lock_guard<std::mutex> lock(frames_mutex);
  surface_frames.clear();
  surface_frames.reserve(kMaxSurfaceFrames);
  LOGI("Surface frame memory cleared.");
}

__attribute__((visibility("default"))) __attribute__((used))
int32_t add_surface_frame(uint8_t *image_bytes, int32_t length, double *plane_points, int32_t point_count) {
  if (image_bytes == nullptr || length <= 0 || plane_points == nullptr || point_count != 4) {
    LOGI("Invalid surface frame.");
    return -1;
  }

  try {
    std::vector<uchar> buffer(image_bytes, image_bytes + length);
    cv::Mat decoded_img = cv::imdecode(buffer, cv::IMREAD_COLOR);
    if (decoded_img.empty()) {
      LOGI("Surface frame decode failed.");
      return -2;
    }

    SurfaceFrame frame;
    frame.image = resize_for_surface(decoded_img);
    frame.plane_points.reserve(4);
    for (int i = 0; i < 4; ++i) {
      frame.plane_points.push_back(cv::Point2f(
          static_cast<float>(plane_points[i * 2]),
          static_cast<float>(plane_points[i * 2 + 1])));
    }

    std::lock_guard<std::mutex> lock(frames_mutex);
    if (surface_frames.size() >= kMaxSurfaceFrames) {
      return static_cast<int32_t>(surface_frames.size());
    }
    surface_frames.push_back(frame);
    LOGI("Surface frame accepted. Total frames: %d", (int)surface_frames.size());
    return static_cast<int32_t>(surface_frames.size());
  } catch (const cv::Exception &e) {
    LOGI("OpenCV surface add error: %s", e.what());
    return -3;
  } catch (...) {
    LOGI("Unknown surface add error.");
    return -4;
  }
}

__attribute__((visibility("default"))) __attribute__((used))
int32_t process_surface_scan(uint8_t **output_image_bytes, int32_t *out_width, int32_t *out_height) {
  if (output_image_bytes == nullptr || out_width == nullptr || out_height == nullptr) {
    return -1;
  }

  *output_image_bytes = nullptr;
  *out_width = 0;
  *out_height = 0;

  std::vector<SurfaceFrame> frames_snapshot;
  {
    std::lock_guard<std::mutex> lock(frames_mutex);
    if (surface_frames.empty()) {
      LOGI("Not enough surface frames.");
      return -2;
    }

    frames_snapshot.reserve(surface_frames.size());
    for (const SurfaceFrame &frame : surface_frames) {
      if (!frame.image.empty() && frame.plane_points.size() == 4) {
        SurfaceFrame copy;
        copy.image = frame.image.clone();
        copy.plane_points = frame.plane_points;
        frames_snapshot.push_back(copy);
      }
    }
    surface_frames.clear();
    surface_frames.reserve(kMaxSurfaceFrames);
  }

  if (frames_snapshot.empty()) {
    return -3;
  }

  try {
    float min_x = frames_snapshot[0].plane_points[0].x;
    float max_x = min_x;
    float min_y = frames_snapshot[0].plane_points[0].y;
    float max_y = min_y;
    for (const SurfaceFrame &frame : frames_snapshot) {
      for (const cv::Point2f &point : frame.plane_points) {
        min_x = std::min(min_x, point.x);
        max_x = std::max(max_x, point.x);
        min_y = std::min(min_y, point.y);
        max_y = std::max(max_y, point.y);
      }
    }

    const double width_meters = std::max(0.01f, max_x - min_x);
    const double height_meters = std::max(0.01f, max_y - min_y);
    double scale = kSurfacePixelsPerMeter;
    const double raw_width = width_meters * scale;
    const double raw_height = height_meters * scale;
    const double max_side = std::max(raw_width, raw_height);
    if (max_side > kMaxSurfaceOutputSide) {
      scale *= static_cast<double>(kMaxSurfaceOutputSide) / max_side;
    }

    const int output_width = std::max(1, static_cast<int>(std::ceil(width_meters * scale)));
    const int output_height = std::max(1, static_cast<int>(std::ceil(height_meters * scale)));
    cv::Mat canvas(output_height, output_width, CV_8UC3, cv::Scalar(0, 0, 0));
    cv::Mat coverage(output_height, output_width, CV_8UC1, cv::Scalar(0));
    const int64 start_tick = cv::getTickCount();

    for (const SurfaceFrame &frame : frames_snapshot) {
      std::vector<cv::Point2f> src_points = {
        cv::Point2f(0.0f, 0.0f),
        cv::Point2f(static_cast<float>(frame.image.cols - 1), 0.0f),
        cv::Point2f(static_cast<float>(frame.image.cols - 1), static_cast<float>(frame.image.rows - 1)),
        cv::Point2f(0.0f, static_cast<float>(frame.image.rows - 1))
      };

      std::vector<cv::Point2f> dst_points;
      dst_points.reserve(4);
      for (const cv::Point2f &point : frame.plane_points) {
        dst_points.push_back(cv::Point2f(
            static_cast<float>((point.x - min_x) * scale),
            static_cast<float>((point.y - min_y) * scale)));
      }

      cv::Mat homography = cv::getPerspectiveTransform(src_points, dst_points);
      cv::Mat warped;
      cv::warpPerspective(frame.image, warped, homography, canvas.size(), cv::INTER_LINEAR, cv::BORDER_REPLICATE);

      cv::Mat source_mask(frame.image.rows, frame.image.cols, CV_8UC1, cv::Scalar(255));
      cv::Mat warped_mask;
      cv::warpPerspective(source_mask, warped_mask, homography, canvas.size(), cv::INTER_NEAREST, cv::BORDER_CONSTANT);

      const cv::Rect roi = mask_bounds(warped_mask);
      if (roi.width <= 0 || roi.height <= 0) continue;

      cv::Mat canvas_roi = canvas(roi);
      cv::Mat coverage_roi = coverage(roi);
      cv::Mat warped_roi = warped(roi);
      cv::Mat mask_roi = warped_mask(roi);

      cv::Mat inverted_coverage;
      cv::bitwise_not(coverage_roi, inverted_coverage);

      cv::Mat new_pixels_mask;
      cv::bitwise_and(mask_roi, inverted_coverage, new_pixels_mask);
      warped_roi.copyTo(canvas_roi, new_pixels_mask);

      cv::Mat overlap_mask;
      cv::bitwise_and(mask_roi, coverage_roi, overlap_mask);
      if (cv::countNonZero(overlap_mask) > 0) {
        cv::Mat blended_roi;
        cv::addWeighted(canvas_roi, 0.58, warped_roi, 0.42, 0.0, blended_roi);
        blended_roi.copyTo(canvas_roi, overlap_mask);
      }

      cv::bitwise_or(coverage_roi, mask_roi, coverage_roi);
    }

    if (cv::countNonZero(coverage) <= 0) {
      LOGI("Surface compositor produced no covered pixels.");
      return -4;
    }

    crop_to_coverage(&canvas, &coverage);
    const int32_t encoded_size = encode_jpeg_result(canvas, output_image_bytes, out_width, out_height);
    if (encoded_size <= 0) {
      LOGI("Surface JPG encoding failed.");
      return -4;
    }

    const double elapsed_ms = (cv::getTickCount() - start_tick) * 1000.0 / cv::getTickFrequency();
    LOGI("Surface scan complete. Output: %d x %d in %.1f ms", canvas.cols, canvas.rows, elapsed_ms);
    return encoded_size;
  } catch (const cv::Exception &e) {
    LOGI("OpenCV surface processing error: %s", e.what());
    return -5;
  } catch (...) {
    LOGI("Unknown surface processing error.");
    return -6;
  }
}
__attribute__((visibility("default"))) __attribute__((used))
void free_panorama_buffer(uint8_t *buffer) {
  if (buffer != nullptr) {
    std::free(buffer);
  }
}

}
