package com.linguacanvas.app

import java.io.IOException
import java.io.InputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable

internal class BackupDocumentTooLargeException : IOException("Backup exceeds 10 MiB")
internal class BackupDocumentCancelledException : IOException("Backup operation closed")

internal class BackupDocumentSession(
    private val onFinish: (Any?, String?, String?) -> Unit,
) {
    private val lock = Any()
    private var closed = false
    private var resource: Closeable? = null
    val isClosed: Boolean get() = synchronized(lock) { closed }

    fun attach(resource: Closeable): Boolean {
        synchronized(lock) {
            if (!closed) {
                this.resource = resource
                return true
            }
        }
        try { resource.close() } catch (_: Exception) {}
        return false
    }

    fun finish(value: Any? = null, errorCode: String? = null, errorMessage: String? = null): Boolean {
        val closing = synchronized(lock) {
            if (closed) return false
            closed = true
            resource.also { resource = null }
        }
        try { closing?.close() } catch (_: Exception) {}
        onFinish(value, errorCode, errorMessage)
        return true
    }
}

internal object BackupDocumentIo {
    const val MAX_BYTES = 10 * 1024 * 1024

    fun readBounded(
        declaredSize: Long?,
        openInput: () -> InputStream,
        isCancelled: () -> Boolean = { false },
    ): ByteArray {
        if (declaredSize != null && declaredSize > MAX_BYTES) {
            throw BackupDocumentTooLargeException()
        }
        if (isCancelled()) throw BackupDocumentCancelledException()
        return openInput().use { input ->
            val initialSize = declaredSize?.takeIf { it in 1..MAX_BYTES.toLong() }?.toInt() ?: 8192
            val output = ByteArrayOutputStream(initialSize)
            val buffer = ByteArray(8192)
            while (true) {
                if (isCancelled()) throw BackupDocumentCancelledException()
                // Probe at most one byte beyond the limit, even if metadata was
                // absent, stale, or supplied by a non-file document provider.
                val length = minOf(buffer.size, MAX_BYTES - output.size() + 1)
                val read = input.read(buffer, 0, length)
                if (isCancelled()) throw BackupDocumentCancelledException()
                if (read < 0) break
                if (output.size() + read > MAX_BYTES) throw BackupDocumentTooLargeException()
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        }
    }
}
