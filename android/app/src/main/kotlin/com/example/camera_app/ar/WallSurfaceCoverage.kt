package com.example.camera_app.ar

import com.google.ar.core.Pose
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToInt

internal data class WallCoverageSnapshot(
    val minX: Float,
    val maxX: Float,
    val minY: Float,
    val maxY: Float,
    val meshVertices: List<Pose>,
)

/** Stores only the seed-connected area that was actually swept on the committed plane. */
internal class WallSurfaceCoverage {
    private data class Cell(val x: Int, val y: Int)

    private var plane: DepthPlane? = null
    private var axisX = Vec3(0f, 0f, 0f)
    private var axisY = Vec3(0f, 0f, 0f)
    private val cells = HashSet<Cell>()
    private var cachedSnapshot: WallCoverageSnapshot? = null

    val cellCount: Int
        get() = cells.size

    fun observe(targetPlane: DepthPlane, surface: DepthSurface): Boolean {
        ensurePlane(targetPlane)
        val candidates = rasterize(surface)
        if (candidates.isEmpty()) return false
        val additions = if (cells.isEmpty()) {
            limitSeed(candidates)
        } else {
            val bridge = findBridge(candidates) ?: return false
            val nearby = candidates.filterTo(HashSet()) {
                hasActiveNeighbor(it, MAX_GROWTH_CELLS)
            }
            nearby.addAll(bridgeLine(bridge.first, bridge.second))
            nearby
        }
        if (additions.isEmpty()) return false
        val available = MAX_CELLS - cells.size
        if (available <= 0 || additions.size > available) return false
        val changed = cells.addAll(additions)
        if (!changed) return false
        fillSmallHoles()
        cachedSnapshot = null
        return true
    }

    fun snapshot(): WallCoverageSnapshot? {
        cachedSnapshot?.let { return it }
        val reference = plane ?: return null
        if (cells.isEmpty()) return null
        val minCellX = cells.minOf { it.x }
        val maxCellX = cells.maxOf { it.x }
        val minCellY = cells.minOf { it.y }
        val maxCellY = cells.maxOf { it.y }
        val mesh = buildMesh(reference)
        return WallCoverageSnapshot(
            minCellX * CELL_SIZE_METERS,
            (maxCellX + 1) * CELL_SIZE_METERS,
            minCellY * CELL_SIZE_METERS,
            (maxCellY + 1) * CELL_SIZE_METERS,
            mesh,
        ).also { cachedSnapshot = it }
    }

    fun reset() {
        plane = null
        axisX = Vec3(0f, 0f, 0f)
        axisY = Vec3(0f, 0f, 0f)
        cells.clear()
        cachedSnapshot = null
    }

    private fun ensurePlane(target: DepthPlane) {
        val current = plane
        if (current != null && planesMatch(current, target)) return
        reset()
        val normal = target.normal.verticalized()
        plane = DepthPlane(target.point, normal)
        axisX = cross(WORLD_UP, normal).normalized()
        axisY = cross(normal, axisX).normalized().let {
            if (it.dot(WORLD_UP) < 0f) it * -1f else it
        }
    }

    private fun rasterize(surface: DepthSurface): HashSet<Cell> {
        val reference = plane ?: return hashSetOf()
        if (surface.corners.isEmpty()) return hashSetOf()
        val points = surface.corners.map(Pose::positionVec)
        val xs = points.map { (it - reference.point).dot(axisX) }
        val ys = points.map { (it - reference.point).dot(axisY) }
        val minX = (xs.minOrNull() ?: return hashSetOf()).coerceAtLeast(-MAX_EXTENT_METERS)
        val maxX = (xs.maxOrNull() ?: return hashSetOf()).coerceAtMost(MAX_EXTENT_METERS)
        val minY = (ys.minOrNull() ?: return hashSetOf()).coerceAtLeast(-MAX_EXTENT_METERS)
        val maxY = (ys.maxOrNull() ?: return hashSetOf()).coerceAtMost(MAX_EXTENT_METERS)
        if (maxX <= minX || maxY <= minY) return hashSetOf()
        val output = HashSet<Cell>()
        val startX = floor(minX / CELL_SIZE_METERS).toInt()
        val endX = floor(maxX / CELL_SIZE_METERS).toInt()
        val startY = floor(minY / CELL_SIZE_METERS).toInt()
        val endY = floor(maxY / CELL_SIZE_METERS).toInt()
        for (y in startY..endY) {
            val centerY = (y + 0.5f) * CELL_SIZE_METERS
            if (centerY !in minY..maxY) continue
            for (x in startX..endX) {
                val centerX = (x + 0.5f) * CELL_SIZE_METERS
                if (centerX in minX..maxX) output.add(Cell(x, y))
            }
        }
        return output
    }

    private fun limitSeed(candidates: Set<Cell>): Set<Cell> {
        if (candidates.size <= MAX_SEED_CELLS) return candidates
        val centerX = candidates.sumOf { it.x }.toFloat() / candidates.size
        val centerY = candidates.sumOf { it.y }.toFloat() / candidates.size
        return candidates.sortedBy {
            val dx = it.x - centerX
            val dy = it.y - centerY
            dx * dx + dy * dy
        }.take(MAX_SEED_CELLS).toSet()
    }

    private fun findBridge(candidates: Set<Cell>): Pair<Cell, Cell>? {
        for (candidate in candidates) {
            if (candidate in cells) return Pair(candidate, candidate)
            for (radius in 1..MAX_BRIDGE_CELLS) {
                for (dy in -radius..radius) {
                    for (dx in -radius..radius) {
                        if (max(abs(dx), abs(dy)) != radius) continue
                        val active = Cell(candidate.x + dx, candidate.y + dy)
                        if (active in cells) return Pair(active, candidate)
                    }
                }
            }
        }
        return null
    }

    private fun hasActiveNeighbor(candidate: Cell, radius: Int): Boolean {
        for (dy in -radius..radius) {
            for (dx in -radius..radius) {
                if (Cell(candidate.x + dx, candidate.y + dy) in cells) return true
            }
        }
        return false
    }

    private fun bridgeLine(first: Cell, second: Cell): Set<Cell> {
        val steps = max(abs(second.x - first.x), abs(second.y - first.y))
        if (steps == 0) return setOf(first)
        return (0..steps).mapTo(HashSet()) { step ->
            val ratio = step.toFloat() / steps
            Cell(
                (first.x + (second.x - first.x) * ratio).roundToInt(),
                (first.y + (second.y - first.y) * ratio).roundToInt(),
            )
        }
    }

    private fun fillSmallHoles() {
        val additions = HashSet<Cell>()
        for (cell in cells) {
            bridgeGap(cell, 1, 0, additions)
            bridgeGap(cell, 0, 1, additions)
        }
        val available = MAX_CELLS - cells.size
        if (available > 0) cells.addAll(additions.take(available))
    }

    private fun bridgeGap(cell: Cell, dx: Int, dy: Int, additions: MutableSet<Cell>) {
        for (gap in 1..MAX_HOLE_CELLS) {
            val end = Cell(cell.x + dx * (gap + 1), cell.y + dy * (gap + 1))
            if (end !in cells) continue
            for (step in 1..gap) {
                additions.add(Cell(cell.x + dx * step, cell.y + dy * step))
            }
        }
    }

    private fun buildMesh(reference: DepthPlane): List<Pose> {
        val output = ArrayList<Pose>()
        val rows = cells.groupBy { it.y }
        for ((y, rowCells) in rows) {
            val sorted = rowCells.map { it.x }.sorted()
            var start = sorted.first()
            var previous = start
            for (index in 1..sorted.size) {
                val next = sorted.getOrNull(index)
                if (next == previous + 1) {
                    previous = next
                    continue
                }
                addRun(output, reference.point, start, previous, y)
                if (next != null) {
                    start = next
                    previous = next
                }
            }
        }
        return output
    }

    private fun addRun(output: MutableList<Pose>, origin: Vec3, firstX: Int, lastX: Int, y: Int) {
        val left = firstX * CELL_SIZE_METERS
        val right = (lastX + 1) * CELL_SIZE_METERS
        val bottom = y * CELL_SIZE_METERS
        val top = (y + 1) * CELL_SIZE_METERS
        val topLeft = origin + axisX * left + axisY * top
        val topRight = origin + axisX * right + axisY * top
        val bottomRight = origin + axisX * right + axisY * bottom
        val bottomLeft = origin + axisX * left + axisY * bottom
        listOf(topLeft, topRight, bottomRight, topLeft, bottomRight, bottomLeft).forEach {
            output.add(Pose.makeTranslation(it.x, it.y, it.z))
        }
    }

    private fun planesMatch(first: DepthPlane, second: DepthPlane): Boolean =
        abs(first.normal.dot(second.normal)) >= PLANE_NORMAL_DOT &&
            abs((second.point - first.point).dot(first.normal)) <= PLANE_DISTANCE_METERS

    private companion object {
        val WORLD_UP = Vec3(0f, 1f, 0f)
        const val CELL_SIZE_METERS = 0.05f
        const val MAX_EXTENT_METERS = 3f
        const val MAX_BRIDGE_CELLS = 2
        const val MAX_GROWTH_CELLS = 5
        const val MAX_HOLE_CELLS = 2
        const val MAX_SEED_CELLS = 1800
        const val MAX_CELLS = 3200
        const val PLANE_NORMAL_DOT = 0.995f
        const val PLANE_DISTANCE_METERS = 0.04f
    }
}
