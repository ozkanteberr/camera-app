package com.example.camera_app.ar

import android.media.Image
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import kotlin.math.abs
import kotlin.math.max

/** Conservatively trims the focus brush at strong cabinet or wall image boundaries. */
internal class WallLumaBoundaryProvider {
    private data class Profile(
        val positions: FloatArray,
        val luma: IntArray,
    )

    var diagnostic: String = "idle"
        private set

    fun refine(frame: Frame, baseRect: FloatArray): FloatArray {
        if (baseRect.size != 4) return baseRect
        return runCatching {
            frame.acquireCameraImage().use { image -> refineWithImage(frame, image, baseRect) }
        }.getOrElse {
            diagnostic = "image_unavailable"
            baseRect
        }
    }

    fun reset() {
        diagnostic = "idle"
    }

    private fun refineWithImage(frame: Frame, image: Image, base: FloatArray): FloatArray {
        val horizontal = profile(frame, image, horizontalCoordinates())
        val vertical = profile(frame, image, verticalCoordinates())
        if (horizontal == null || vertical == null) {
            diagnostic = "luma_unavailable"
            return base
        }
        val output = base.copyOf()
        strongestEdge(horizontal, base[0], FOCUS_CENTER - CENTER_GUARD)?.let {
            output[0] = max(output[0], it + EDGE_INSET)
        }
        strongestEdge(horizontal, FOCUS_CENTER + CENTER_GUARD, base[2])?.let {
            output[2] = minOf(output[2], it - EDGE_INSET)
        }
        strongestEdge(vertical, base[1], FOCUS_CENTER - CENTER_GUARD)?.let {
            output[1] = max(output[1], it + EDGE_INSET)
        }
        strongestEdge(vertical, FOCUS_CENTER + CENTER_GUARD, base[3])?.let {
            output[3] = minOf(output[3], it - EDGE_INSET)
        }
        if (output[2] - output[0] < MIN_BRUSH_SIZE ||
            output[3] - output[1] < MIN_BRUSH_SIZE
        ) {
            diagnostic = "edge_ambiguous"
            return base
        }
        diagnostic = if (output.contentEquals(base)) "clear" else "clamped"
        return output
    }

    private fun profile(frame: Frame, image: Image, viewPoints: FloatArray): Profile? {
        val imagePoints = FloatArray(viewPoints.size)
        frame.transformCoordinates2d(
            Coordinates2d.VIEW_NORMALIZED,
            viewPoints,
            Coordinates2d.IMAGE_PIXELS,
            imagePoints,
        )
        val yPlane = image.planes.firstOrNull() ?: return null
        val positions = FloatArray(viewPoints.size / 2)
        val values = IntArray(positions.size)
        for (index in positions.indices) {
            positions[index] = if (viewPoints[index * 2] == FOCUS_CENTER) {
                viewPoints[index * 2 + 1]
            } else {
                viewPoints[index * 2]
            }
            values[index] = sampleLuma(
                yPlane,
                image.width,
                image.height,
                imagePoints[index * 2],
                imagePoints[index * 2 + 1],
            ) ?: return null
        }
        return Profile(positions, values)
    }

    private fun sampleLuma(
        plane: Image.Plane,
        width: Int,
        height: Int,
        imageX: Float,
        imageY: Float,
    ): Int? {
        val x = imageX.toInt().coerceIn(0, width - 1)
        val y = imageY.toInt().coerceIn(0, height - 1)
        val offset = y * plane.rowStride + x * plane.pixelStride
        val buffer = plane.buffer
        if (offset !in 0 until buffer.limit()) return null
        return buffer.get(offset).toInt() and 0xff
    }

    private fun strongestEdge(profile: Profile, minimum: Float, maximum: Float): Float? {
        if (maximum <= minimum) return null
        val gradients = (0 until profile.luma.lastIndex).map {
            abs(profile.luma[it + 1] - profile.luma[it])
        }
        if (gradients.isEmpty()) return null
        val median = gradients.sorted()[gradients.size / 2]
        val threshold = max(MIN_LUMA_GRADIENT, median * MEDIAN_MULTIPLIER + MEDIAN_OFFSET)
        var bestGradient = threshold - 1
        var bestPosition: Float? = null
        for (index in gradients.indices) {
            val position = (profile.positions[index] + profile.positions[index + 1]) * 0.5f
            if (position !in minimum..maximum || gradients[index] <= bestGradient) continue
            bestGradient = gradients[index]
            bestPosition = position
        }
        return bestPosition
    }

    private fun horizontalCoordinates(): FloatArray = FloatArray(PROFILE_SAMPLES * 2).also { points ->
        for (index in 0 until PROFILE_SAMPLES) {
            points[index * 2] = profilePosition(index)
            points[index * 2 + 1] = FOCUS_CENTER
        }
    }

    private fun verticalCoordinates(): FloatArray = FloatArray(PROFILE_SAMPLES * 2).also { points ->
        for (index in 0 until PROFILE_SAMPLES) {
            points[index * 2] = FOCUS_CENTER
            points[index * 2 + 1] = profilePosition(index)
        }
    }

    private fun profilePosition(index: Int): Float =
        PROFILE_MIN + (PROFILE_MAX - PROFILE_MIN) * index / (PROFILE_SAMPLES - 1)

    private companion object {
        const val PROFILE_SAMPLES = 21
        const val PROFILE_MIN = 0.32f
        const val PROFILE_MAX = 0.68f
        const val FOCUS_CENTER = 0.5f
        const val CENTER_GUARD = 0.035f
        const val EDGE_INSET = 0.008f
        const val MIN_BRUSH_SIZE = 0.10f
        const val MIN_LUMA_GRADIENT = 26
        const val MEDIAN_MULTIPLIER = 3
        const val MEDIAN_OFFSET = 8
    }
}
