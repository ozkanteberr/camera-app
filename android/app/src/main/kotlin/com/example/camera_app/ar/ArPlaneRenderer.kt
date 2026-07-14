package com.example.camera_app.ar

import android.opengl.GLES20
import android.opengl.Matrix
import com.google.ar.core.Camera
import com.google.ar.core.Plane
import com.google.ar.core.TrackingState
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

internal class ArPlaneRenderer {
    private var program = 0
    private var positionAttribute = 0
    private var mvpUniform = 0
    private var colorUniform = 0
    private var polygonBuffer = allocateFloatBuffer(INITIAL_POLYGON_FLOAT_CAPACITY)

    fun createOnGlThread() {
        program = GlProgram.create(VERTEX_SHADER, FRAGMENT_SHADER)
        positionAttribute = GLES20.glGetAttribLocation(program, "a_Position")
        mvpUniform = GLES20.glGetUniformLocation(program, "u_Mvp")
        colorUniform = GLES20.glGetUniformLocation(program, "u_Color")
    }

    fun draw(camera: Camera, planes: Collection<Plane>) {
        val projection = FloatArray(16)
        val view = FloatArray(16)
        val model = FloatArray(16)
        val viewModel = FloatArray(16)
        val mvp = FloatArray(16)
        camera.getProjectionMatrix(projection, 0, 0.1f, 100f)
        camera.getViewMatrix(view, 0)
        GLES20.glUseProgram(program)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glDepthMask(false)

        for (plane in planes) {
            if (plane.trackingState != TrackingState.TRACKING || plane.subsumedBy != null) continue
            val polygon = copyToNativeBuffer(plane.polygon)
            val vertexCount = polygon.remaining() / 2
            if (vertexCount < 3) continue
            plane.centerPose.toMatrix(model, 0)
            Matrix.multiplyMM(viewModel, 0, view, 0, model, 0)
            Matrix.multiplyMM(mvp, 0, projection, 0, viewModel, 0)
            GLES20.glUniformMatrix4fv(mvpUniform, 1, false, mvp, 0)
            GLES20.glEnableVertexAttribArray(positionAttribute)
            GLES20.glVertexAttribPointer(positionAttribute, 2, GLES20.GL_FLOAT, false, 0, polygon)
            GLES20.glUniform4f(colorUniform, 0.12f, 0.85f, 0.62f, 0.20f)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_FAN, 0, vertexCount)
            polygon.position(0)
            GLES20.glUniform4f(colorUniform, 0.35f, 1.0f, 0.78f, 0.85f)
            GLES20.glLineWidth(2.5f)
            GLES20.glDrawArrays(GLES20.GL_LINE_LOOP, 0, vertexCount)
            GLES20.glDisableVertexAttribArray(positionAttribute)
        }
        GLES20.glDepthMask(true)
        GLES20.glDisable(GLES20.GL_BLEND)
    }

    private fun copyToNativeBuffer(source: FloatBuffer): FloatBuffer {
        source.position(0)
        val requiredFloats = source.remaining()
        if (polygonBuffer.capacity() < requiredFloats) {
            var newCapacity = polygonBuffer.capacity()
            while (newCapacity < requiredFloats) newCapacity *= 2
            polygonBuffer = allocateFloatBuffer(newCapacity)
        }
        polygonBuffer.clear()
        polygonBuffer.put(source)
        polygonBuffer.flip()
        source.position(0)
        return polygonBuffer
    }

    private fun allocateFloatBuffer(floatCapacity: Int): FloatBuffer =
        ByteBuffer.allocateDirect(floatCapacity * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()

    private companion object {
        const val INITIAL_POLYGON_FLOAT_CAPACITY = 256
        const val VERTEX_SHADER = """
            uniform mat4 u_Mvp;
            attribute vec2 a_Position;
            void main() { gl_Position = u_Mvp * vec4(a_Position.x, 0.0, a_Position.y, 1.0); }
        """
        const val FRAGMENT_SHADER = """
            precision mediump float;
            uniform vec4 u_Color;
            void main() { gl_FragColor = u_Color; }
        """
    }
}
