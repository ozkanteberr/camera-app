package com.example.camera_app.ar

import com.google.ar.core.Frame
import kotlin.math.abs

/** Adapts the previously reliable DepthPoint rectangle detector to wall observations. */
internal class WallDepthProbeProvider {
    private val detector = DepthSurfaceTracker()

    var diagnostic: String = "idle"
        private set

    fun observe(
        frame: Frame,
        width: Int,
        height: Int,
        nowMs: Long,
        depthSupported: Boolean,
    ): WallObservation? {
        if (!depthSupported) return rejected("depth_unsupported")
        val surface = detector.detect(frame, width, height) ?: return rejected("no_depth_patch")
        if (!isVertical(surface)) return rejected("non_vertical_patch")
        if (!isFocused(surface.normalizedRect)) return rejected("off_center_patch")
        diagnostic = "accepted"
        return WallObservation(surface, WallObservationSource.DEPTH_PATCH, nowMs)
    }

    fun reset() {
        detector.reset()
        diagnostic = "idle"
    }

    private fun isVertical(surface: DepthSurface): Boolean {
        val normal = surface.plane.normal.normalized()
        return normal.length() >= 0.9f && abs(normal.y) <= MAX_NORMAL_Y
    }

    private fun isFocused(rect: FloatArray): Boolean = rect.size == 4 &&
        rect[0] <= FOCUS_CENTER && rect[2] >= FOCUS_CENTER &&
        rect[1] <= FOCUS_CENTER && rect[3] >= FOCUS_CENTER

    private fun rejected(reason: String): WallObservation? {
        diagnostic = reason
        return null
    }

    private companion object {
        const val MAX_NORMAL_Y = 0.72f
        const val FOCUS_CENTER = 0.5f
    }
}
