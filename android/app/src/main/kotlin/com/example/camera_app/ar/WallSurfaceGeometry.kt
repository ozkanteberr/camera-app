package com.example.camera_app.ar

import android.opengl.Matrix
import com.google.ar.core.Camera
import com.google.ar.core.Plane
import com.google.ar.core.Pose
import com.google.ar.core.TrackingState
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

internal class WallSurfaceGeometry {
    fun fromPlane(plane: Plane): DepthSurface? {
        if (plane.type != Plane.Type.VERTICAL || plane.trackingState != TrackingState.TRACKING) return null
        val polygon = plane.polygon.duplicate()
        polygon.position(0)
        if (polygon.remaining() < 6) return null
        var minX = Float.POSITIVE_INFINITY
        var maxX = Float.NEGATIVE_INFINITY
        var minZ = Float.POSITIVE_INFINITY
        var maxZ = Float.NEGATIVE_INFINITY
        while (polygon.remaining() >= 2) {
            val x = polygon.get()
            val z = polygon.get()
            minX = min(minX, x)
            maxX = max(maxX, x)
            minZ = min(minZ, z)
            maxZ = max(maxZ, z)
        }
        if (maxX - minX < MIN_SIZE_METERS || maxZ - minZ < MIN_SIZE_METERS) return null
        val corners = listOf(
            Pose.makeTranslation(minX, 0f, minZ),
            Pose.makeTranslation(maxX, 0f, minZ),
            Pose.makeTranslation(maxX, 0f, maxZ),
            Pose.makeTranslation(minX, 0f, maxZ),
        ).map(plane.centerPose::compose)
        val normal = FloatArray(3)
        plane.centerPose.getTransformedAxis(1, 1f, normal, 0)
        return DepthSurface(
            DepthPlane(plane.centerPose.positionVec(), Vec3(normal[0], normal[1], normal[2]).verticalized()),
            DEFAULT_RECT.copyOf(),
            corners,
        )
    }

    fun projectToViewport(camera: Camera, surface: DepthSurface): DepthSurface? {
        val projection = FloatArray(16)
        val view = FloatArray(16)
        val viewProjection = FloatArray(16)
        camera.getProjectionMatrix(projection, 0, 0.1f, 100f)
        camera.getViewMatrix(view, 0)
        Matrix.multiplyMM(viewProjection, 0, projection, 0, view, 0)
        val projected = surface.corners.mapNotNull { pose ->
            val clip = FloatArray(4)
            Matrix.multiplyMV(
                clip,
                0,
                viewProjection,
                0,
                floatArrayOf(pose.tx(), pose.ty(), pose.tz(), 1f),
                0,
            )
            if (clip[3] <= 1e-5f) null else Pair(
                (clip[0] / clip[3] + 1f) * 0.5f,
                (1f - clip[1] / clip[3]) * 0.5f,
            )
        }
        if (projected.size != 4) return null
        val left = projected.minOf { it.first }.coerceIn(VIEW_MARGIN, 1f - VIEW_MARGIN)
        val right = projected.maxOf { it.first }.coerceIn(VIEW_MARGIN, 1f - VIEW_MARGIN)
        val top = projected.minOf { it.second }.coerceIn(VIEW_MARGIN, 1f - VIEW_MARGIN)
        val bottom = projected.maxOf { it.second }.coerceIn(VIEW_MARGIN, 1f - VIEW_MARGIN)
        if (right - left < MIN_NORMALIZED_SIZE || bottom - top < MIN_NORMALIZED_SIZE) return null
        val corners = listOf(
            intersectViewRay(camera, left, top, surface.plane),
            intersectViewRay(camera, right, top, surface.plane),
            intersectViewRay(camera, right, bottom, surface.plane),
            intersectViewRay(camera, left, bottom, surface.plane),
        )
        if (corners.any { it == null }) return null
        return DepthSurface(
            surface.plane,
            floatArrayOf(left, top, right, bottom),
            corners.filterNotNull(),
        )
    }

    private fun intersectViewRay(camera: Camera, x: Float, y: Float, plane: DepthPlane): Pose? {
        val projection = FloatArray(16)
        val view = FloatArray(16)
        val viewProjection = FloatArray(16)
        val inverse = FloatArray(16)
        camera.getProjectionMatrix(projection, 0, 0.1f, 100f)
        camera.getViewMatrix(view, 0)
        Matrix.multiplyMM(viewProjection, 0, projection, 0, view, 0)
        if (!Matrix.invertM(inverse, 0, viewProjection, 0)) return null
        val near = unproject(inverse, x * 2f - 1f, 1f - y * 2f, -1f) ?: return null
        val far = unproject(inverse, x * 2f - 1f, 1f - y * 2f, 1f) ?: return null
        val direction = (far - near).normalized()
        val denominator = direction.dot(plane.normal)
        if (abs(denominator) < 1e-5f) return null
        val distance = (plane.point - near).dot(plane.normal) / denominator
        if (distance !in MIN_RAY_DISTANCE_METERS..MAX_RAY_DISTANCE_METERS) return null
        val point = near + direction * distance
        return Pose.makeTranslation(point.x, point.y, point.z)
    }

    private fun unproject(inverse: FloatArray, x: Float, y: Float, z: Float): Vec3? {
        val output = FloatArray(4)
        Matrix.multiplyMV(output, 0, inverse, 0, floatArrayOf(x, y, z, 1f), 0)
        if (abs(output[3]) < 1e-6f) return null
        return Vec3(output[0] / output[3], output[1] / output[3], output[2] / output[3])
    }

    private companion object {
        val DEFAULT_RECT = floatArrayOf(0.15f, 0.15f, 0.85f, 0.85f)
        const val MIN_SIZE_METERS = 0.16f
        const val VIEW_MARGIN = 0.025f
        const val MIN_NORMALIZED_SIZE = 0.10f
        const val MIN_RAY_DISTANCE_METERS = 0.15f
        const val MAX_RAY_DISTANCE_METERS = 8f
    }
}

internal fun Pose.positionVec() = Vec3(tx(), ty(), tz())

internal fun Vec3.verticalized(): Vec3 {
    val projected = Vec3(x, 0f, z).normalized()
    return if (projected.length() < 0.9f) normalized() else projected
}

internal fun cross(first: Vec3, second: Vec3) = Vec3(
    first.y * second.z - first.z * second.y,
    first.z * second.x - first.x * second.z,
    first.x * second.y - first.y * second.x,
)

internal fun List<Vec3>.averageVec(): Vec3 {
    if (isEmpty()) return Vec3(0f, 0f, 0f)
    var sum = Vec3(0f, 0f, 0f)
    for (point in this) sum += point
    return sum * (1f / size)
}
