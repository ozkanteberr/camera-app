#include <opencv2/opencv.hpp>
#include <opencv2/stitching.hpp>
#include <android/log.h>
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
void free_panorama_buffer(uint8_t *buffer) {
  if (buffer != nullptr) {
    std::free(buffer);
  }
}

}