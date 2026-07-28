package com.example.camera_app.ar

import android.opengl.GLES20
import android.opengl.Matrix
import com.google.ar.core.Camera
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

internal class ArDepthSurfaceRenderer {
    private var vertices: FloatBuffer = allocateBuffer(4)
    private var program = 0
    private var positionAttribute = 0
    private var mvpUniform = 0
    private var colorUniform = 0

    fun createOnGlThread() {
        program = GlProgram.create(VERTEX_SHADER, FRAGMENT_SHADER)
        positionAttribute = GLES20.glGetAttribLocation(program, "a_Position")
        mvpUniform = GLES20.glGetUniformLocation(program, "u_Mvp")
        colorUniform = GLES20.glGetUniformLocation(program, "u_Color")
    }

    fun draw(
        camera: Camera,
        surface: DepthSurface,
        wallState: WallSurfaceState? = null,
    ) {
        if (surface.corners.size != 4) return
        val mesh = surface.meshVertices
        val fillVertices = if (mesh.isNotEmpty() && mesh.size % 3 == 0) mesh else surface.corners
        loadVertices(fillVertices)

        val projection = FloatArray(16)
        val view = FloatArray(16)
        val mvp = FloatArray(16)
        camera.getProjectionMatrix(projection, 0, 0.1f, 100f)
        camera.getViewMatrix(view, 0)
        Matrix.multiplyMM(mvp, 0, projection, 0, view, 0)

        GLES20.glUseProgram(program)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glDepthMask(false)
        GLES20.glUniformMatrix4fv(mvpUniform, 1, false, mvp, 0)
        GLES20.glEnableVertexAttribArray(positionAttribute)
        GLES20.glVertexAttribPointer(positionAttribute, 3, GLES20.GL_FLOAT, false, 0, vertices)
        val colors = colorsFor(wallState)
        GLES20.glUniform4f(colorUniform, colors[0], colors[1], colors[2], colors[3])
        val fillMode = if (fillVertices === mesh) GLES20.GL_TRIANGLES else GLES20.GL_TRIANGLE_FAN
        GLES20.glDrawArrays(fillMode, 0, fillVertices.size)
        loadVertices(surface.corners)
        GLES20.glVertexAttribPointer(positionAttribute, 3, GLES20.GL_FLOAT, false, 0, vertices)
        GLES20.glUniform4f(colorUniform, colors[4], colors[5], colors[6], colors[7])
        GLES20.glLineWidth(2.5f)
        GLES20.glDrawArrays(GLES20.GL_LINE_LOOP, 0, 4)
        GLES20.glDisableVertexAttribArray(positionAttribute)
        GLES20.glDepthMask(true)
        GLES20.glDisable(GLES20.GL_BLEND)
    }

    private fun loadVertices(poses: List<com.google.ar.core.Pose>) {
        val required = poses.size * 3
        if (vertices.capacity() < required) vertices = allocateBuffer(poses.size)
        vertices.clear()
        poses.forEach { pose -> vertices.put(pose.tx()).put(pose.ty()).put(pose.tz()) }
        vertices.flip()
    }

    private fun allocateBuffer(vertexCount: Int): FloatBuffer =
        ByteBuffer.allocateDirect(vertexCount * 3 * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()

    private fun colorsFor(state: WallSurfaceState?): FloatArray = when (state) {
        WallSurfaceState.PREVIEW -> PREVIEW_COLORS
        WallSurfaceState.STABLE -> STABLE_COLORS
        WallSurfaceState.TEMPORARILY_LOST -> LOST_COLORS
        WallSurfaceState.LOCKED -> LOCKED_COLORS
        else -> DEFAULT_COLORS
    }

    private companion object {
        val DEFAULT_COLORS = floatArrayOf(0.48f, 0.50f, 0.54f, 0.16f, 0.78f, 0.80f, 0.84f, 0.68f)
        val PREVIEW_COLORS = floatArrayOf(1f, 0.55f, 0.05f, 0.20f, 1f, 0.68f, 0.20f, 0.92f)
        val STABLE_COLORS = floatArrayOf(0.15f, 0.88f, 0.48f, 0.22f, 0.30f, 1f, 0.62f, 0.94f)
        val LOST_COLORS = floatArrayOf(0.72f, 0.42f, 0.12f, 0.12f, 0.95f, 0.62f, 0.25f, 0.55f)
        val LOCKED_COLORS = floatArrayOf(0.05f, 0.76f, 0.72f, 0.24f, 0.20f, 1f, 0.92f, 0.98f)
        const val VERTEX_SHADER = """
            uniform mat4 u_Mvp;
            attribute vec3 a_Position;
            void main() { gl_Position = u_Mvp * vec4(a_Position, 1.0); }
        """
        const val FRAGMENT_SHADER = """
            precision mediump float;
            uniform vec4 u_Color;
            void main() { gl_FragColor = u_Color; }
        """
    }
}
