package com.example.camera_app.ar

import com.google.ar.core.Frame
import com.google.ar.core.HitResult
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.TrackingState

internal class ArSurfaceHitTester {
    fun hitTestPlaneQuad(
        frame: Frame,
        surfaceWidth: Int,
        surfaceHeight: Int,
        points: List<Map<String, Any>>,
        requiredPlane: Plane? = null,
    ): ArrayList<DoubleArray>? {
        val output = ArrayList<DoubleArray>(points.size)
        var selectedPlane = requiredPlane
        for (point in points) {
            val x = (point["x"] as? Number)?.toFloat() ?: return null
            val y = (point["y"] as? Number)?.toFloat() ?: return null
            val hit = hitTestPlaneAt(
                frame,
                surfaceWidth,
                surfaceHeight,
                x,
                y,
                selectedPlane,
            ) ?: return null
            selectedPlane = hit.trackable as Plane
            output.add(serializePose(hit.hitPose))
        }
        return output
    }

    fun hitTestPlaneViewport(
        frame: Frame,
        surfaceWidth: Int,
        surfaceHeight: Int,
        columns: Int,
        rows: Int,
        marginX: Float,
        marginY: Float,
        requiredPlane: Plane? = null,
    ): HashMap<String, Any>? {
        val leftLimit = marginX
        val rightLimit = 1f - marginX
        val topLimit = marginY
        val bottomLimit = 1f - marginY
        if (rightLimit <= leftLimit || bottomLimit <= topLimit) return null
        val stepX = (rightLimit - leftLimit) / (columns - 1)
        val stepY = (bottomLimit - topLimit) / (rows - 1)
        val hitsByPlane = HashMap<Plane, MutableList<Pair<Float, Float>>>()

        for (row in 0 until rows) {
            val y = topLimit + stepY * row
            for (column in 0 until columns) {
                val x = leftLimit + stepX * column
                val hit = hitTestPlaneAt(
                    frame,
                    surfaceWidth,
                    surfaceHeight,
                    x,
                    y,
                    requiredPlane,
                ) ?: continue
                val plane = hit.trackable as Plane
                hitsByPlane.getOrPut(plane) { mutableListOf() }.add(Pair(x, y))
            }
        }
        val selected = hitsByPlane.maxByOrNull { it.value.size } ?: return null
        if (selected.value.size < 4) return null
        val plane = selected.key
        val minX = selected.value.minOf { it.first }
        val maxX = selected.value.maxOf { it.first }
        val minY = selected.value.minOf { it.second }
        val maxY = selected.value.maxOf { it.second }
        val baseLeft = (minX - stepX * 0.5f).coerceIn(leftLimit, rightLimit)
        val baseRight = (maxX + stepX * 0.5f).coerceIn(leftLimit, rightLimit)
        val baseTop = (minY - stepY * 0.5f).coerceIn(topLimit, bottomLimit)
        val baseBottom = (maxY + stepY * 0.5f).coerceIn(topLimit, bottomLimit)
        if (baseRight - baseLeft < 0.14f || baseBottom - baseTop < 0.14f) return null

        for (shrink in floatArrayOf(0f, 0.015f, 0.03f, 0.05f, 0.075f, 0.10f)) {
            val left = (baseLeft + shrink).coerceIn(leftLimit, rightLimit)
            val right = (baseRight - shrink).coerceIn(leftLimit, rightLimit)
            val top = (baseTop + shrink).coerceIn(topLimit, bottomLimit)
            val bottom = (baseBottom - shrink).coerceIn(topLimit, bottomLimit)
            if (right - left < 0.12f || bottom - top < 0.12f) continue
            val corners = listOf(Pair(left, top), Pair(right, top), Pair(right, bottom), Pair(left, bottom))
            val hits = ArrayList<DoubleArray>(4)
            for (corner in corners) {
                val hit = hitTestPlaneAt(
                    frame,
                    surfaceWidth,
                    surfaceHeight,
                    corner.first,
                    corner.second,
                    plane,
                ) ?: break
                hits.add(serializePose(hit.hitPose))
            }
            if (hits.size == 4) {
                return hashMapOf(
                    "rect" to arrayListOf(left.toDouble(), top.toDouble(), right.toDouble(), bottom.toDouble()),
                    "hits" to hits,
                )
            }
        }
        return null
    }

    private fun hitTestPlaneAt(
        frame: Frame,
        surfaceWidth: Int,
        surfaceHeight: Int,
        normalizedX: Float,
        normalizedY: Float,
        requiredPlane: Plane? = null,
    ): HitResult? {
        if (surfaceWidth <= 0 || surfaceHeight <= 0) return null
        val x = normalizedX.coerceIn(0f, 1f) * surfaceWidth
        val y = normalizedY.coerceIn(0f, 1f) * surfaceHeight
        return frame.hitTest(x, y).firstOrNull { hit ->
            val plane = hit.trackable as? Plane ?: return@firstOrNull false
            plane.trackingState == TrackingState.TRACKING &&
                plane.isPoseInPolygon(hit.hitPose) &&
                (requiredPlane == null || requiredPlane == plane)
        }
    }

    private fun serializePose(pose: Pose): DoubleArray {
        val matrix = FloatArray(16)
        pose.toMatrix(matrix, 0)
        return DoubleArray(matrix.size) { matrix[it].toDouble() }
    }
}
