package com.example.camera_app.ar

import com.google.ar.core.Anchor
import com.google.ar.core.Camera
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

internal enum class WallSurfaceState(val wireValue: String) {
    SEARCHING("searching"),
    PREVIEW("preview"),
    STABLE("stable"),
    TEMPORARILY_LOST("lost"),
    LOCKED("locked"),
}

internal data class WallSurfaceUpdate(
    val surface: DepthSurface?,
    val state: WallSurfaceState,
)

/**
 * Accumulates one ground-aligned vertical surface in world coordinates.
 * Its bounds expand but never shrink, and survive temporary tracking loss.
 */
internal class WallSurfaceTracker {
    private data class Model(
        val plane: DepthPlane,
        val axisX: Vec3,
        val axisY: Vec3,
        var minX: Float,
        var maxX: Float,
        var minY: Float,
        var maxY: Float,
        var confirmations: Int,
        var lastEvidenceAtMs: Long,
        var lastRect: FloatArray,
    )

    private data class LockedModel(
        val anchor: Anchor?,
        val localCorners: List<Vec3>,
        val fallback: DepthSurface,
    )

    private val geometry = WallSurfaceGeometry()
    private var model: Model? = null
    private var cachedSurface: DepthSurface? = null
    private var lockedModel: LockedModel? = null
    private var state = WallSurfaceState.SEARCHING

    fun observeSurface(
        surface: DepthSurface,
        nowMs: Long,
        stableEvidence: Boolean,
    ): WallSurfaceUpdate {
        observe(surface, nowMs, stableEvidence)
        return current(nowMs)
    }

    fun advance(nowMs: Long): WallSurfaceUpdate = current(nowMs)

    fun lock(session: Session, fallbackSurface: DepthSurface? = null): Boolean {
        if (lockedModel != null) return true
        fallbackSurface?.let {
            observe(it, android.os.SystemClock.elapsedRealtime(), stableEvidence = true)
        }
        if (state != WallSurfaceState.STABLE) return false
        val surface = renderSurface() ?: return false
        val center = surface.corners.map(Pose::positionVec).averageVec()
        val anchor = runCatching {
            session.createAnchor(Pose.makeTranslation(center.x, center.y, center.z))
        }.getOrNull()
        lockedModel = LockedModel(
            anchor = anchor,
            localCorners = surface.corners.map { it.positionVec() - center },
            fallback = surface,
        )
        state = WallSurfaceState.LOCKED
        return true
    }

    fun unlock() {
        lockedModel?.anchor?.detach()
        lockedModel = null
        state = if ((model?.confirmations ?: 0) >= STABLE_CONFIRMATIONS) {
            WallSurfaceState.STABLE
        } else {
            WallSurfaceState.PREVIEW
        }
    }

    fun renderUpdate(nowMs: Long): WallSurfaceUpdate = current(nowMs)

    fun visibleSurface(camera: Camera, width: Int, height: Int): DepthSurface? {
        if (width <= 0 || height <= 0) return null
        return geometry.projectToViewport(camera, renderSurface() ?: return null)
    }

    fun reset() {
        lockedModel?.anchor?.detach()
        lockedModel = null
        model = null
        cachedSurface = null
        state = WallSurfaceState.SEARCHING
    }

    private fun observe(
        surface: DepthSurface,
        nowMs: Long,
        stableEvidence: Boolean,
    ) {
        val current = model
        if (current == null) {
            model = createModel(surface, nowMs, if (stableEvidence) STABLE_CONFIRMATIONS else 1)
            cachedSurface = model?.let(::buildSurface)
            state = if (stableEvidence) WallSurfaceState.STABLE else WallSurfaceState.PREVIEW
            return
        }
        if (!isCompatible(current.plane, surface.plane)) {
            val canReplace = stableEvidence || current.confirmations < STABLE_CONFIRMATIONS ||
                nowMs - current.lastEvidenceAtMs >= REPLACE_AFTER_MS
            if (!canReplace) return
            model = createModel(surface, nowMs, if (stableEvidence) STABLE_CONFIRMATIONS else 1)
            cachedSurface = model?.let(::buildSurface)
            state = if (stableEvidence) WallSurfaceState.STABLE else WallSurfaceState.PREVIEW
            return
        }

        val observedPoints = surface.corners.map(Pose::positionVec)
        if (current.confirmations < STABLE_CONFIRMATIONS &&
            (stableEvidence || planeChanged(current.plane, surface.plane))
        ) {
            if (!isConnected(current, observedPoints)) {
                if (stableEvidence) {
                    model = createModel(surface, nowMs, STABLE_CONFIRMATIONS)
                    cachedSurface = model?.let(::buildSurface)
                    state = WallSurfaceState.STABLE
                }
                return
            }
            val confirmations = if (stableEvidence) STABLE_CONFIRMATIONS else 1
            val rebased = rebaseModel(current, surface, nowMs, confirmations)
            model = rebased
            cachedSurface = buildSurface(rebased)
            state = if (stableEvidence) WallSurfaceState.STABLE else WallSurfaceState.PREVIEW
            return
        }

        if (!isConnected(current, observedPoints)) {
            if (stableEvidence) {
                model = createModel(surface, nowMs, STABLE_CONFIRMATIONS)
                cachedSurface = model?.let(::buildSurface)
                state = WallSurfaceState.STABLE
            }
            return
        }
        expandBounds(
            current,
            observedPoints,
            if (stableEvidence) STABLE_MAX_GROWTH_METERS else MAX_GROWTH_METERS,
        )
        current.lastEvidenceAtMs = max(current.lastEvidenceAtMs, nowMs)
        current.lastRect = surface.normalizedRect.copyOf()
        current.confirmations = if (stableEvidence) {
            STABLE_CONFIRMATIONS
        } else {
            current.confirmations
        }
        cachedSurface = buildSurface(current)
        state = if (current.confirmations >= STABLE_CONFIRMATIONS) {
            WallSurfaceState.STABLE
        } else {
            WallSurfaceState.PREVIEW
        }
    }

    private fun current(nowMs: Long): WallSurfaceUpdate {
        lockedSurface()?.let { return WallSurfaceUpdate(it, WallSurfaceState.LOCKED) }
        val current = model ?: return WallSurfaceUpdate(null, WallSurfaceState.SEARCHING)
        if (nowMs - current.lastEvidenceAtMs > LOST_AFTER_MS) {
            state = WallSurfaceState.TEMPORARILY_LOST
        }
        return WallSurfaceUpdate(renderSurface(), state)
    }

    private fun createModel(
        surface: DepthSurface,
        nowMs: Long,
        confirmations: Int,
    ): Model {
        val normal = surface.plane.normal.verticalized()
        val axisX = cross(WORLD_UP, normal).normalized()
        var axisY = cross(normal, axisX).normalized()
        if (axisY.dot(WORLD_UP) < 0f) axisY *= -1f
        val point = surface.plane.point
        val positions = surface.corners.map(Pose::positionVec)
        val xs = positions.map { (it - point).dot(axisX) }
        val ys = positions.map { (it - point).dot(axisY) }
        val xBounds = paddedBounds(xs.minOrNull() ?: 0f, xs.maxOrNull() ?: 0f)
        val yBounds = paddedBounds(ys.minOrNull() ?: 0f, ys.maxOrNull() ?: 0f)
        return Model(
            DepthPlane(point, normal),
            axisX,
            axisY,
            xBounds.first,
            xBounds.second,
            yBounds.first,
            yBounds.second,
            confirmations,
            nowMs,
            surface.normalizedRect.copyOf(),
        )
    }

    private fun rebaseModel(
        previous: Model,
        surface: DepthSurface,
        nowMs: Long,
        confirmations: Int,
    ): Model {
        val rebased = createModel(surface, nowMs, confirmations)
        includeBounds(rebased, buildSurface(previous).corners.map(Pose::positionVec))
        return rebased
    }

    private fun includeBounds(current: Model, points: List<Vec3>) {
        if (points.isEmpty()) return
        val xs = points.map { (it - current.plane.point).dot(current.axisX) }
        val ys = points.map { (it - current.plane.point).dot(current.axisY) }
        current.minX = min(current.minX, xs.minOrNull() ?: current.minX)
            .coerceAtLeast(-MAX_EXTENT_METERS)
        current.maxX = max(current.maxX, xs.maxOrNull() ?: current.maxX)
            .coerceAtMost(MAX_EXTENT_METERS)
        current.minY = min(current.minY, ys.minOrNull() ?: current.minY)
            .coerceAtLeast(-MAX_EXTENT_METERS)
        current.maxY = max(current.maxY, ys.maxOrNull() ?: current.maxY)
            .coerceAtMost(MAX_EXTENT_METERS)
    }

    private fun expandBounds(current: Model, points: List<Vec3>, maxGrowth: Float) {
        val xs = points.map { (it - current.plane.point).dot(current.axisX) }
        val ys = points.map { (it - current.plane.point).dot(current.axisY) }
        val proposedMinX = (xs.minOrNull() ?: current.minX) - EDGE_PADDING_METERS
        val proposedMaxX = (xs.maxOrNull() ?: current.maxX) + EDGE_PADDING_METERS
        val proposedMinY = (ys.minOrNull() ?: current.minY) - EDGE_PADDING_METERS
        val proposedMaxY = (ys.maxOrNull() ?: current.maxY) + EDGE_PADDING_METERS
        current.minX = max(max(proposedMinX, current.minX - maxGrowth), -MAX_EXTENT_METERS)
            .coerceAtMost(current.minX)
        current.maxX = min(min(proposedMaxX, current.maxX + maxGrowth), MAX_EXTENT_METERS)
            .coerceAtLeast(current.maxX)
        current.minY = max(max(proposedMinY, current.minY - maxGrowth), -MAX_EXTENT_METERS)
            .coerceAtMost(current.minY)
        current.maxY = min(min(proposedMaxY, current.maxY + maxGrowth), MAX_EXTENT_METERS)
            .coerceAtLeast(current.maxY)
    }

    private fun renderSurface(): DepthSurface? {
        lockedSurface()?.let { return it }
        return cachedSurface
    }

    private fun buildSurface(current: Model): DepthSurface {
        val p = current.plane.point
        val corners = listOf(
            p + current.axisX * current.minX + current.axisY * current.maxY,
            p + current.axisX * current.maxX + current.axisY * current.maxY,
            p + current.axisX * current.maxX + current.axisY * current.minY,
            p + current.axisX * current.minX + current.axisY * current.minY,
        ).map { Pose.makeTranslation(it.x, it.y, it.z) }
        return DepthSurface(current.plane, current.lastRect.copyOf(), corners)
    }

    private fun lockedSurface(): DepthSurface? {
        val locked = lockedModel ?: return null
        val anchor = locked.anchor
        if (anchor == null || anchor.trackingState == TrackingState.STOPPED) return locked.fallback
        val corners = locked.localCorners.map { offset ->
            anchor.pose.compose(Pose.makeTranslation(offset.x, offset.y, offset.z))
        }
        val positions = corners.map(Pose::positionVec)
        val normal = cross(positions[1] - positions[0], positions[3] - positions[0]).normalized()
        return DepthSurface(
            DepthPlane(positions.averageVec(), normal),
            locked.fallback.normalizedRect,
            corners,
        )
    }

    private fun isCompatible(first: DepthPlane, second: DepthPlane): Boolean =
        abs(first.normal.dot(second.normal)) >= COMPATIBLE_NORMAL_DOT &&
            abs((second.point - first.point).dot(first.normal)) <= COMPATIBLE_DISTANCE_METERS

    private fun planeChanged(first: DepthPlane, second: DepthPlane): Boolean =
        abs(first.normal.dot(second.normal)) < REBASE_NORMAL_DOT ||
            abs((second.point - first.point).dot(first.normal)) > REBASE_DISTANCE_METERS

    private fun isConnected(current: Model, points: List<Vec3>): Boolean {
        if (points.isEmpty()) return false
        val xs = points.map { (it - current.plane.point).dot(current.axisX) }
        val ys = points.map { (it - current.plane.point).dot(current.axisY) }
        return intervalGap(current.minX, current.maxX, xs.minOrNull()!!, xs.maxOrNull()!!) <=
            MAX_JOIN_GAP_METERS &&
            intervalGap(current.minY, current.maxY, ys.minOrNull()!!, ys.maxOrNull()!!) <=
            MAX_JOIN_GAP_METERS
    }

    private fun intervalGap(aMin: Float, aMax: Float, bMin: Float, bMax: Float): Float =
        when {
            bMin > aMax -> bMin - aMax
            aMin > bMax -> aMin - bMax
            else -> 0f
        }

    private fun paddedBounds(minimum: Float, maximum: Float): Pair<Float, Float> {
        var low = minimum - EDGE_PADDING_METERS
        var high = maximum + EDGE_PADDING_METERS
        if (high - low < MIN_INITIAL_SIZE_METERS) {
            val center = (low + high) * 0.5f
            low = center - MIN_INITIAL_SIZE_METERS * 0.5f
            high = center + MIN_INITIAL_SIZE_METERS * 0.5f
        }
        return Pair(
            low.coerceAtLeast(-MAX_EXTENT_METERS),
            high.coerceAtMost(MAX_EXTENT_METERS),
        )
    }

    private companion object {
        val WORLD_UP = Vec3(0f, 1f, 0f)
        const val LOST_AFTER_MS = 1800L
        const val REPLACE_AFTER_MS = 4000L
        const val STABLE_CONFIRMATIONS = 2
        const val COMPATIBLE_NORMAL_DOT = 0.90f
        const val COMPATIBLE_DISTANCE_METERS = 0.15f
        const val REBASE_NORMAL_DOT = 0.9995f
        const val REBASE_DISTANCE_METERS = 0.01f
        const val MAX_JOIN_GAP_METERS = 0.28f
        const val EDGE_PADDING_METERS = 0.035f
        const val MIN_INITIAL_SIZE_METERS = 0.16f
        const val MAX_GROWTH_METERS = 0.22f
        const val STABLE_MAX_GROWTH_METERS = 0.30f
        const val MAX_EXTENT_METERS = 3f
    }
}
