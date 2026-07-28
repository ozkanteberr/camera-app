package com.example.camera_app.ar

import android.opengl.Matrix
import com.google.ar.core.Camera
import com.google.ar.core.DepthPoint
import com.google.ar.core.Frame
import com.google.ar.core.Pose
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

internal data class DepthPlane(
    val point: Vec3,
    val normal: Vec3,
)

internal data class DepthSurface(
    val plane: DepthPlane,
    val normalizedRect: FloatArray,
    val corners: List<Pose>,
    val meshVertices: List<Pose> = emptyList(),
)

internal data class Vec3(val x: Float, val y: Float, val z: Float) {
    operator fun plus(other: Vec3) = Vec3(x + other.x, y + other.y, z + other.z)
    operator fun minus(other: Vec3) = Vec3(x - other.x, y - other.y, z - other.z)
    operator fun times(scale: Float) = Vec3(x * scale, y * scale, z * scale)
    fun dot(other: Vec3): Float = x * other.x + y * other.y + z * other.z
    fun length(): Float = sqrt(dot(this))
    fun normalized(): Vec3 {
        val length = length()
        return if (length < 1e-6f) this else this * (1f / length)
    }
}

internal class DepthSurfaceTracker {
    private data class Sample(
        val normalizedX: Float,
        val normalizedY: Float,
        val position: Vec3,
        val normal: Vec3,
    )

    private var latestPlane: DepthPlane? = null
    private var lockedPlane: DepthPlane? = null

    fun setLocked(locked: Boolean) {
        lockedPlane = if (locked) latestPlane else null
    }

    fun reset() {
        latestPlane = null
        lockedPlane = null
    }

    fun detect(frame: Frame, width: Int, height: Int): DepthSurface? {
        if (width <= 0 || height <= 0) return null
        val samples = collectSamples(frame, width, height)
        if (samples.size < MIN_SAMPLES) return null

        val plane = lockedPlane ?: fitPlane(samples) ?: return null
        val inliers = samples.filter { sample ->
            abs((sample.position - plane.point).dot(plane.normal)) <= INLIER_DISTANCE_METERS &&
                abs(sample.normal.dot(plane.normal)) >= MIN_NORMAL_DOT
        }
        if (inliers.size < MIN_SAMPLES) return null

        val minX = inliers.minOf { it.normalizedX }
        val maxX = inliers.maxOf { it.normalizedX }
        val minY = inliers.minOf { it.normalizedY }
        val maxY = inliers.maxOf { it.normalizedY }
        val left = (minX - GRID_STEP_X * 0.5f).coerceIn(MARGIN_X, 1f - MARGIN_X)
        val right = (maxX + GRID_STEP_X * 0.5f).coerceIn(MARGIN_X, 1f - MARGIN_X)
        val top = (minY - GRID_STEP_Y * 0.5f).coerceIn(MARGIN_Y, 1f - MARGIN_Y)
        val bottom = (maxY + GRID_STEP_Y * 0.5f).coerceIn(MARGIN_Y, 1f - MARGIN_Y)
        if (right - left < MIN_RECT_SIZE || bottom - top < MIN_RECT_SIZE) return null

        val corners = listOf(
            intersectViewRay(frame.camera, left, top, plane),
            intersectViewRay(frame.camera, right, top, plane),
            intersectViewRay(frame.camera, right, bottom, plane),
            intersectViewRay(frame.camera, left, bottom, plane),
        )
        if (corners.any { it == null }) return null

        latestPlane = plane
        return DepthSurface(
            plane = plane,
            normalizedRect = floatArrayOf(left, top, right, bottom),
            corners = corners.filterNotNull(),
        )
    }

    private fun collectSamples(frame: Frame, width: Int, height: Int): List<Sample> {
        val samples = ArrayList<Sample>(GRID_COLUMNS * GRID_ROWS)
        for (row in 0 until GRID_ROWS) {
            val normalizedY = MARGIN_Y + GRID_STEP_Y * row
            for (column in 0 until GRID_COLUMNS) {
                val normalizedX = MARGIN_X + GRID_STEP_X * column
                val hit = frame.hitTest(normalizedX * width, normalizedY * height)
                    .firstOrNull { it.trackable is DepthPoint } ?: continue
                val positionArray = FloatArray(3)
                val normalArray = FloatArray(3)
                hit.hitPose.getTranslation(positionArray, 0)
                hit.hitPose.getTransformedAxis(1, 1f, normalArray, 0)
                val normal = Vec3(normalArray[0], normalArray[1], normalArray[2]).normalized()
                if (normal.length() < 0.9f) continue
                samples.add(
                    Sample(
                        normalizedX,
                        normalizedY,
                        Vec3(positionArray[0], positionArray[1], positionArray[2]),
                        normal,
                    ),
                )
            }
        }
        return samples
    }

    private fun fitPlane(samples: List<Sample>): DepthPlane? {
        var bestSeed: Sample? = null
        var bestCluster: List<Sample> = emptyList()
        for (seed in samples) {
            val cluster = samples.filter { candidate ->
                abs(candidate.normal.dot(seed.normal)) >= SEED_NORMAL_DOT &&
                    abs((candidate.position - seed.position).dot(seed.normal)) <= SEED_DISTANCE_METERS
            }
            if (cluster.size > bestCluster.size) {
                bestSeed = seed
                bestCluster = cluster
            }
        }
        val seed = bestSeed ?: return null
        if (bestCluster.size < MIN_SAMPLES || bestCluster.size < max(MIN_SAMPLES, samples.size / 2)) return null

        var normalSum = Vec3(0f, 0f, 0f)
        var pointSum = Vec3(0f, 0f, 0f)
        for (sample in bestCluster) {
            val alignedNormal = if (sample.normal.dot(seed.normal) < 0f) sample.normal * -1f else sample.normal
            normalSum += alignedNormal
            pointSum += sample.position
        }
        var normal = normalSum.normalized()
        val point = pointSum * (1f / bestCluster.size)

        latestPlane?.let { previous ->
            if (abs(previous.normal.dot(normal)) >= STABLE_NORMAL_DOT &&
                abs((point - previous.point).dot(previous.normal)) <= STABLE_DISTANCE_METERS
            ) {
                if (previous.normal.dot(normal) < 0f) normal = normal * -1f
                normal = (previous.normal * 0.82f + normal * 0.18f).normalized()
                val signedOffset = (point - previous.point).dot(normal)
                return DepthPlane(previous.point + normal * (signedOffset * 0.18f), normal)
            }
        }
        return DepthPlane(point, normal)
    }

    private fun intersectViewRay(camera: Camera, normalizedX: Float, normalizedY: Float, plane: DepthPlane): Pose? {
        val projection = FloatArray(16)
        val view = FloatArray(16)
        val viewProjection = FloatArray(16)
        val inverse = FloatArray(16)
        camera.getProjectionMatrix(projection, 0, 0.1f, 100f)
        camera.getViewMatrix(view, 0)
        Matrix.multiplyMM(viewProjection, 0, projection, 0, view, 0)
        if (!Matrix.invertM(inverse, 0, viewProjection, 0)) return null

        val ndcX = normalizedX * 2f - 1f
        val ndcY = 1f - normalizedY * 2f
        val near = unproject(inverse, ndcX, ndcY, -1f) ?: return null
        val far = unproject(inverse, ndcX, ndcY, 1f) ?: return null
        val direction = (far - near).normalized()
        val denominator = direction.dot(plane.normal)
        if (abs(denominator) < 1e-5f) return null
        val distance = (plane.point - near).dot(plane.normal) / denominator
        if (distance !in MIN_RAY_DISTANCE_METERS..MAX_RAY_DISTANCE_METERS) return null
        val intersection = near + direction * distance
        return Pose.makeTranslation(intersection.x, intersection.y, intersection.z)
    }

    private fun unproject(inverse: FloatArray, x: Float, y: Float, z: Float): Vec3? {
        val input = floatArrayOf(x, y, z, 1f)
        val output = FloatArray(4)
        Matrix.multiplyMV(output, 0, inverse, 0, input, 0)
        if (abs(output[3]) < 1e-6f) return null
        val inverseW = 1f / output[3]
        return Vec3(output[0] * inverseW, output[1] * inverseW, output[2] * inverseW)
    }

    private companion object {
        const val GRID_COLUMNS = 5
        const val GRID_ROWS = 7
        const val MARGIN_X = 0.08f
        const val MARGIN_Y = 0.10f
        const val GRID_STEP_X = (1f - MARGIN_X * 2f) / (GRID_COLUMNS - 1)
        const val GRID_STEP_Y = (1f - MARGIN_Y * 2f) / (GRID_ROWS - 1)
        const val MIN_SAMPLES = 8
        const val MIN_RECT_SIZE = 0.24f
        const val SEED_NORMAL_DOT = 0.90f
        const val MIN_NORMAL_DOT = 0.86f
        const val SEED_DISTANCE_METERS = 0.08f
        const val INLIER_DISTANCE_METERS = 0.055f
        const val STABLE_NORMAL_DOT = 0.94f
        const val STABLE_DISTANCE_METERS = 0.12f
        const val MIN_RAY_DISTANCE_METERS = 0.15f
        const val MAX_RAY_DISTANCE_METERS = 8f
    }
}
