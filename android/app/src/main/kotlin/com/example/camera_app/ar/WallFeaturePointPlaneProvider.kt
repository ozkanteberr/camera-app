package com.example.camera_app.ar

import android.opengl.Matrix
import com.google.ar.core.Camera
import com.google.ar.core.Frame
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Fits a vertical plane from persistent ARCore feature points near screen center. */
internal class WallFeaturePointPlaneProvider {
    private data class TrackedPoint(
        val id: Int,
        val position: Vec3,
        val lastSeenAtMs: Long,
        val seenFrames: Int,
    )

    private data class PlaneFit(
        val plane: DepthPlane,
        val inliers: List<TrackedPoint>,
        val confidence: Float,
    )

    private val tracked = LinkedHashMap<Int, TrackedPoint>()
    private val geometry = WallSurfaceGeometry()

    var diagnostic: String = "idle"
        private set

    fun observe(frame: Frame, nowMs: Long): WallObservation? {
        updatePoints(frame, nowMs)
        tracked.entries.removeAll { nowMs - it.value.lastSeenAtMs > POINT_LIFETIME_MS }
        trimToLimit()
        if (tracked.size < MIN_INLIERS) return rejected("few_feature_points")
        val fit = fitPlane(tracked.values.toList()) ?: return rejected("no_feature_plane")
        val facing = viewFacing(fit.plane, frame.camera.pose.positionVec())
        if (facing < MIN_VIEW_FACING) return rejected("feature_plane_grazing")
        val confidence = (fit.confidence * FIT_CONFIDENCE_WEIGHT +
            facing * FACING_CONFIDENCE_WEIGHT).coerceIn(0f, 1f)
        val rect = sampleRect(fit.inliers, viewProjection(frame.camera))
            ?: return rejected("feature_plane_off_center")
        val surface = geometry.fromViewRect(frame.camera, rect, fit.plane)
            ?: return rejected("feature_projection_failed")
        diagnostic = "accepted:${fit.inliers.size}:q=${(confidence * 100f).toInt()}"
        return WallObservation(
            surface,
            WallObservationSource.FEATURE_POINTS,
            nowMs,
            confidence,
        )
    }

    fun reset() {
        tracked.clear()
        diagnostic = "idle"
    }

    private fun updatePoints(frame: Frame, nowMs: Long) {
        val viewProjection = viewProjection(frame.camera)
        val cameraPosition = frame.camera.pose.positionVec()
        var accepted = 0
        runCatching {
            frame.acquirePointCloud().use { cloud ->
                val points = cloud.points.duplicate().apply { rewind() }
                val ids = cloud.ids.duplicate().apply { rewind() }
                while (points.remaining() >= 4 && ids.hasRemaining() && accepted < MAX_FRAME_POINTS) {
                    val position = Vec3(points.get(), points.get(), points.get())
                    val confidence = points.get()
                    val id = ids.get()
                    if (confidence < MIN_CONFIDENCE ||
                        (position - cameraPosition).length() !in MIN_DISTANCE_METERS..MAX_DISTANCE_METERS
                    ) {
                        continue
                    }
                    val screen = project(viewProjection, position) ?: continue
                    if (screen.first !in SAMPLE_MIN..SAMPLE_MAX ||
                        screen.second !in SAMPLE_MIN..SAMPLE_MAX
                    ) {
                        continue
                    }
                    val previous = tracked[id]
                    tracked[id] = if (previous == null) {
                        TrackedPoint(id, position, nowMs, 1)
                    } else {
                        previous.copy(
                            position = previous.position * POSITION_HISTORY_WEIGHT +
                                position * POSITION_UPDATE_WEIGHT,
                            lastSeenAtMs = nowMs,
                            seenFrames = previous.seenFrames + 1,
                        )
                    }
                    accepted++
                }
            }
        }.onFailure {
            diagnostic = "point_cloud_unavailable"
        }
    }

    private fun fitPlane(samples: List<TrackedPoint>): PlaneFit? {
        val seeds = positionSeeds(samples)
        var bestPoint: Vec3? = null
        var bestNormal = Vec3(0f, 0f, 0f)
        var bestCount = 0
        for (firstIndex in 0 until seeds.lastIndex) {
            val first = seeds[firstIndex]
            for (secondIndex in firstIndex + 1 until seeds.size) {
                val delta = seeds[secondIndex].position - first.position
                if (Vec3(delta.x, 0f, delta.z).length() < MIN_SEED_SPAN_METERS) continue
                val normal = Vec3(-delta.z, 0f, delta.x).normalized()
                var count = 0
                var minY = Float.POSITIVE_INFINITY
                var maxY = Float.NEGATIVE_INFINITY
                for (sample in samples) {
                    if (abs((sample.position - first.position).dot(normal)) > SEED_DISTANCE_METERS) continue
                    count++
                    minY = minOf(minY, sample.position.y)
                    maxY = maxOf(maxY, sample.position.y)
                }
                if (count > bestCount && maxY - minY >= MIN_VERTICAL_SPAN_METERS) {
                    bestPoint = first.position
                    bestNormal = normal
                    bestCount = count
                }
            }
        }
        val required = maxOf(MIN_INLIERS, (samples.size * MIN_CLUSTER_FRACTION).toInt())
        val seedPoint = bestPoint ?: return null
        if (bestCount < required) return null
        val seedInliers = samples.filter {
            abs((it.position - seedPoint).dot(bestNormal)) <= SEED_DISTANCE_METERS
        }
        val plane = refinePlane(seedInliers, bestNormal)
        val inliers = samples.filter {
            abs((it.position - plane.point).dot(plane.normal)) <= INLIER_DISTANCE_METERS
        }
        if (inliers.size < required) return null
        val axisX = cross(WORLD_UP, plane.normal).normalized()
        val horizontalSpan = inliers.maxOf { (it.position - plane.point).dot(axisX) } -
            inliers.minOf { (it.position - plane.point).dot(axisX) }
        if (horizontalSpan < MIN_HORIZONTAL_SPAN_METERS) return null
        val verticalSpan = inliers.maxOf { it.position.y } - inliers.minOf { it.position.y }
        return PlaneFit(
            plane,
            inliers,
            fitConfidence(inliers, plane, horizontalSpan, verticalSpan),
        )
    }

    private fun fitConfidence(
        samples: List<TrackedPoint>,
        plane: DepthPlane,
        horizontalSpan: Float,
        verticalSpan: Float,
    ): Float {
        val residuals = samples.map {
            abs((it.position - plane.point).dot(plane.normal))
        }.sorted()
        val residualScore = (1f - residuals[residuals.size / 2] /
            INLIER_DISTANCE_METERS).coerceIn(0f, 1f)
        val persistentScore = samples.count { it.seenFrames >= PERSISTENT_POINT_FRAMES }
            .toFloat() / samples.size
        val spanScore = minOf(
            horizontalSpan / FULL_SPAN_METERS,
            verticalSpan / FULL_SPAN_METERS,
            1f,
        )
        val supportScore = (samples.size.toFloat() / FULL_SUPPORT_POINTS).coerceAtMost(1f)
        return residualScore * RESIDUAL_WEIGHT +
            planeLinearity(samples) * LINEARITY_WEIGHT +
            persistentScore * PERSISTENCE_WEIGHT +
            spanScore * SPAN_WEIGHT +
            supportScore * SUPPORT_WEIGHT
    }

    private fun planeLinearity(samples: List<TrackedPoint>): Float {
        val center = samples.map { it.position }.averageVec()
        var xx = 0f
        var xz = 0f
        var zz = 0f
        for (sample in samples) {
            val x = sample.position.x - center.x
            val z = sample.position.z - center.z
            xx += x * x
            xz += x * z
            zz += z * z
        }
        val trace = xx + zz
        if (trace <= 1e-6f) return 0f
        val spread = sqrt((xx - zz) * (xx - zz) + 4f * xz * xz)
        val major = (trace + spread) * 0.5f
        val minor = (trace - spread) * 0.5f
        return (1f - minor / major.coerceAtLeast(1e-6f)).coerceIn(0f, 1f)
    }

    private fun viewFacing(plane: DepthPlane, cameraPosition: Vec3): Float =
        abs(plane.normal.dot((cameraPosition - plane.point).normalized()))

    private fun refinePlane(samples: List<TrackedPoint>, seedNormal: Vec3): DepthPlane {
        val point = samples.map { it.position }.averageVec()
        var xx = 0f
        var xz = 0f
        var zz = 0f
        for (sample in samples) {
            val x = sample.position.x - point.x
            val z = sample.position.z - point.z
            xx += x * x
            xz += x * z
            zz += z * z
        }
        val angle = 0.5 * atan2(2.0 * xz, (xx - zz).toDouble())
        var normal = Vec3(-sin(angle).toFloat(), 0f, cos(angle).toFloat())
        if (normal.dot(seedNormal) < 0f) normal *= -1f
        return DepthPlane(point, normal)
    }

    private fun sampleRect(samples: List<TrackedPoint>, matrix: FloatArray): FloatArray? {
        val projected = samples.mapNotNull { project(matrix, it.position) }
            .filter { it.first in 0f..1f && it.second in 0f..1f }
        if (projected.size < MIN_VISIBLE_INLIERS) return null
        val rect = floatArrayOf(
            (projected.minOf { it.first } - RECT_PADDING).coerceIn(VIEW_MARGIN, 1f - VIEW_MARGIN),
            (projected.minOf { it.second } - RECT_PADDING).coerceIn(VIEW_MARGIN, 1f - VIEW_MARGIN),
            (projected.maxOf { it.first } + RECT_PADDING).coerceIn(VIEW_MARGIN, 1f - VIEW_MARGIN),
            (projected.maxOf { it.second } + RECT_PADDING).coerceIn(VIEW_MARGIN, 1f - VIEW_MARGIN),
        )
        if (rect[0] > FOCUS_CENTER || rect[2] < FOCUS_CENTER ||
            rect[1] > FOCUS_CENTER || rect[3] < FOCUS_CENTER ||
            rect[2] - rect[0] < MIN_RECT_SIZE || rect[3] - rect[1] < MIN_RECT_SIZE
        ) {
            return null
        }
        return rect
    }

    private fun positionSeeds(samples: List<TrackedPoint>): List<TrackedPoint> {
        if (samples.size <= MAX_SEEDS) return samples
        val stride = (samples.size / MAX_SEEDS).coerceAtLeast(1)
        return samples.filterIndexed { index, _ -> index % stride == 0 }.take(MAX_SEEDS)
    }

    private fun viewProjection(camera: Camera): FloatArray {
        val projection = FloatArray(16)
        val view = FloatArray(16)
        val output = FloatArray(16)
        camera.getProjectionMatrix(projection, 0, 0.1f, 100f)
        camera.getViewMatrix(view, 0)
        Matrix.multiplyMM(output, 0, projection, 0, view, 0)
        return output
    }

    private fun project(matrix: FloatArray, point: Vec3): Pair<Float, Float>? {
        val clip = FloatArray(4)
        Matrix.multiplyMV(clip, 0, matrix, 0, floatArrayOf(point.x, point.y, point.z, 1f), 0)
        if (clip[3] <= 1e-5f) return null
        return Pair(
            (clip[0] / clip[3] + 1f) * 0.5f,
            (1f - clip[1] / clip[3]) * 0.5f,
        )
    }

    private fun trimToLimit() {
        while (tracked.size > MAX_TRACKED_POINTS) {
            val oldest = tracked.values.minByOrNull { it.lastSeenAtMs } ?: return
            tracked.remove(oldest.id)
        }
    }

    private fun rejected(reason: String): WallObservation? {
        diagnostic = reason
        return null
    }

    private companion object {
        val WORLD_UP = Vec3(0f, 1f, 0f)
        const val POINT_LIFETIME_MS = 2600L
        const val MAX_FRAME_POINTS = 160
        const val MAX_TRACKED_POINTS = 180
        const val MAX_SEEDS = 42
        const val MIN_INLIERS = 7
        const val MIN_VISIBLE_INLIERS = 5
        const val PERSISTENT_POINT_FRAMES = 2
        const val MIN_CLUSTER_FRACTION = 0.14f
        const val MIN_CONFIDENCE = 0.25f
        const val MIN_DISTANCE_METERS = 0.30f
        const val MAX_DISTANCE_METERS = 5f
        const val POSITION_HISTORY_WEIGHT = 0.65f
        const val POSITION_UPDATE_WEIGHT = 0.35f
        const val SAMPLE_MIN = 0.18f
        const val SAMPLE_MAX = 0.82f
        const val MIN_SEED_SPAN_METERS = 0.10f
        const val MIN_VERTICAL_SPAN_METERS = 0.18f
        const val MIN_HORIZONTAL_SPAN_METERS = 0.14f
        const val SEED_DISTANCE_METERS = 0.055f
        const val INLIER_DISTANCE_METERS = 0.045f
        const val RECT_PADDING = 0.025f
        const val VIEW_MARGIN = 0.04f
        const val FOCUS_CENTER = 0.5f
        const val MIN_RECT_SIZE = 0.16f
        const val MIN_VIEW_FACING = 0.28f
        const val FULL_SPAN_METERS = 0.50f
        const val FULL_SUPPORT_POINTS = 24f
        const val RESIDUAL_WEIGHT = 0.26f
        const val LINEARITY_WEIGHT = 0.22f
        const val PERSISTENCE_WEIGHT = 0.20f
        const val SPAN_WEIGHT = 0.17f
        const val SUPPORT_WEIGHT = 0.15f
        const val FIT_CONFIDENCE_WEIGHT = 0.85f
        const val FACING_CONFIDENCE_WEIGHT = 0.15f
    }
}
