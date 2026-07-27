package com.example.camera_app.ar

import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.TrackingState

internal class ArActivePlaneSelector {
    private var activePlane: Plane? = null
    private var pendingPlane: Plane? = null
    private var pendingConfirmations = 0
    private var lastActiveSeenAtMs = 0L

    var holdsSelection: Boolean = false
        private set

    fun select(
        frame: Frame,
        trackedPlanes: List<Plane>,
        surfaceWidth: Int,
        surfaceHeight: Int,
        nowMs: Long,
    ): Plane? {
        activePlane?.let { previous ->
            val root = rootPlane(previous)
            val trackedRoot = trackedPlanes.firstOrNull { it == root }
            if (trackedRoot != null) {
                activePlane = trackedRoot
                lastActiveSeenAtMs = nowMs
                holdsSelection = true
                clearPending()
                return trackedRoot
            }
            if (nowMs - lastActiveSeenAtMs <= ACTIVE_LOSS_GRACE_MS) {
                holdsSelection = true
                return null
            }
            clearActive()
        }

        val candidate = focusHitCandidate(frame, trackedPlanes, surfaceWidth, surfaceHeight)
        if (candidate == null) {
            clearPending()
            return null
        }

        if (candidate == pendingPlane) {
            pendingConfirmations++
        } else {
            pendingPlane = candidate
            pendingConfirmations = 1
        }
        if (pendingConfirmations < REQUIRED_CONFIRMATIONS) return null

        activePlane = candidate
        lastActiveSeenAtMs = nowMs
        holdsSelection = true
        clearPending()
        return candidate
    }

    fun reset() {
        clearActive()
        clearPending()
    }

    private fun focusHitCandidate(
        frame: Frame,
        trackedPlanes: List<Plane>,
        surfaceWidth: Int,
        surfaceHeight: Int,
    ): Plane? {
        if (surfaceWidth <= 0 || surfaceHeight <= 0) return null
        val hitCounts = HashMap<Plane, Int>()
        for (probe in FOCUS_PROBES) {
            for (hit in frame.hitTest(surfaceWidth * probe.first, surfaceHeight * probe.second)) {
                val plane = hit.trackable as? Plane ?: continue
                if (plane.trackingState != TrackingState.TRACKING || !plane.isPoseInPolygon(hit.hitPose)) continue
                val root = rootPlane(plane)
                val trackedRoot = trackedPlanes.firstOrNull { it == root } ?: continue
                hitCounts[trackedRoot] = (hitCounts[trackedRoot] ?: 0) + 1
                break
            }
        }
        return hitCounts.maxByOrNull { it.value }?.key
    }

    private fun rootPlane(plane: Plane): Plane {
        var current = plane
        while (true) {
            val parent = current.subsumedBy ?: return current
            current = parent
        }
    }

    private fun clearActive() {
        activePlane = null
        lastActiveSeenAtMs = 0L
        holdsSelection = false
    }

    private fun clearPending() {
        pendingPlane = null
        pendingConfirmations = 0
    }

    private companion object {
        const val REQUIRED_CONFIRMATIONS = 3
        const val ACTIVE_LOSS_GRACE_MS = 900L
        val FOCUS_PROBES = listOf(
            Pair(0.50f, 0.50f),
            Pair(0.42f, 0.50f),
            Pair(0.58f, 0.50f),
            Pair(0.50f, 0.42f),
            Pair(0.50f, 0.58f),
        )
    }
}
