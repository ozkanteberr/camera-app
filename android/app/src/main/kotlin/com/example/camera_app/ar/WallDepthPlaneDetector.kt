package com.example.camera_app.ar

import com.google.ar.core.DepthPoint
import com.google.ar.core.Frame
import kotlin.math.abs

internal data class WallSurfaceSample(
    val normalizedX: Float,
    val normalizedY: Float,
    val position: Vec3,
    val normal: Vec3,
)

internal data class WallSurfaceCandidate(
    val plane: DepthPlane,
    val samples: List<WallSurfaceSample>,
    val rect: FloatArray,
)

internal class WallDepthPlaneDetector {
    fun detect(frame: Frame, width: Int, height: Int): WallSurfaceCandidate? {
        val samples = collectSamples(frame, width, height)
        if (samples.size < MIN_SAMPLES) return null
        var bestCluster: List<WallSurfaceSample> = emptyList()
        var bestNormal = Vec3(0f, 0f, 0f)
        for (seed in samples) {
            val seedNormal = seed.normal.verticalized()
            val cluster = samples.filter { sample ->
                abs(sample.normal.verticalized().dot(seedNormal)) >= SEED_NORMAL_DOT &&
                    abs((sample.position - seed.position).dot(seedNormal)) <= SEED_DISTANCE_METERS
            }
            if (cluster.size > bestCluster.size) {
                bestCluster = cluster
                bestNormal = seedNormal
            }
        }
        if (bestCluster.size < MIN_SAMPLES || bestCluster.size < samples.size / 2) return null

        var pointSum = Vec3(0f, 0f, 0f)
        var normalSum = Vec3(0f, 0f, 0f)
        for (sample in bestCluster) {
            var normal = sample.normal.verticalized()
            if (normal.dot(bestNormal) < 0f) normal *= -1f
            normalSum += normal
            pointSum += sample.position
        }
        val plane = DepthPlane(
            pointSum * (1f / bestCluster.size),
            normalSum.normalized().verticalized(),
        )
        val inliers = bestCluster.filter {
            abs((it.position - plane.point).dot(plane.normal)) <= INLIER_DISTANCE_METERS
        }
        if (inliers.size < MIN_SAMPLES) return null
        return WallSurfaceCandidate(plane, inliers, sampleRect(inliers))
    }

    private fun collectSamples(frame: Frame, width: Int, height: Int): List<WallSurfaceSample> {
        if (width <= 0 || height <= 0) return emptyList()
        val output = ArrayList<WallSurfaceSample>(GRID_COLUMNS * GRID_ROWS)
        for (row in 0 until GRID_ROWS) {
            val normalizedY = MARGIN_Y + GRID_STEP_Y * row
            for (column in 0 until GRID_COLUMNS) {
                val normalizedX = MARGIN_X + GRID_STEP_X * column
                val hit = frame.hitTest(normalizedX * width, normalizedY * height)
                    .firstOrNull { it.trackable is DepthPoint } ?: continue
                val normalValues = FloatArray(3)
                hit.hitPose.getTransformedAxis(1, 1f, normalValues, 0)
                val normal = Vec3(normalValues[0], normalValues[1], normalValues[2]).normalized()
                if (normal.length() < 0.9f || abs(normal.y) > MAX_VERTICAL_NORMAL_Y) continue
                output.add(
                    WallSurfaceSample(
                        normalizedX,
                        normalizedY,
                        hit.hitPose.positionVec(),
                        normal,
                    ),
                )
            }
        }
        return output
    }

    private fun sampleRect(samples: List<WallSurfaceSample>): FloatArray = floatArrayOf(
        (samples.minOf { it.normalizedX } - GRID_STEP_X * 0.5f).coerceIn(MARGIN_X, 1f - MARGIN_X),
        (samples.minOf { it.normalizedY } - GRID_STEP_Y * 0.5f).coerceIn(MARGIN_Y, 1f - MARGIN_Y),
        (samples.maxOf { it.normalizedX } + GRID_STEP_X * 0.5f).coerceIn(MARGIN_X, 1f - MARGIN_X),
        (samples.maxOf { it.normalizedY } + GRID_STEP_Y * 0.5f).coerceIn(MARGIN_Y, 1f - MARGIN_Y),
    )

    private companion object {
        const val GRID_COLUMNS = 7
        const val GRID_ROWS = 9
        const val MARGIN_X = 0.08f
        const val MARGIN_Y = 0.08f
        const val GRID_STEP_X = (1f - MARGIN_X * 2f) / (GRID_COLUMNS - 1)
        const val GRID_STEP_Y = (1f - MARGIN_Y * 2f) / (GRID_ROWS - 1)
        const val MIN_SAMPLES = 7
        const val MAX_VERTICAL_NORMAL_Y = 0.48f
        const val SEED_NORMAL_DOT = 0.90f
        const val SEED_DISTANCE_METERS = 0.075f
        const val INLIER_DISTANCE_METERS = 0.055f
    }
}
