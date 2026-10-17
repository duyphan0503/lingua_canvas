package com.linguacanvas.app

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.io.Closeable

private const val LIMIT = 10 * 1024 * 1024

private class GeneratedInput(private val count: Int, private val failAfter: Int? = null) : InputStream() {
    var consumed = 0
    var closed = false

    override fun read(): Int {
        if (failAfter != null && consumed >= failAfter) throw IOException("Provider failed")
        return if (consumed++ < count) 42 else -1
    }

    override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
        if (failAfter != null && consumed >= failAfter) throw IOException("Provider failed")
        if (consumed >= count) return -1
        val read = minOf(length, count - consumed)
        java.util.Arrays.fill(bytes, offset, offset + read, 42.toByte())
        consumed += read
        return read
    }

    override fun close() { closed = true }
}

private inline fun <reified T : Throwable> expectFailure(action: () -> Unit) {
    try {
        action()
        error("Expected ${T::class.java.simpleName}")
    } catch (error: Throwable) {
        check(error is T) { "Expected ${T::class.java.simpleName}, got $error" }
    }
}

fun main() {
    val tests = linkedMapOf<String, () -> Unit>(
        "rejects declared oversize before opening provider" to {
            var opened = false
            expectFailure<BackupDocumentTooLargeException> {
                BackupDocumentIo.readBounded(LIMIT.toLong() + 1, {
                    opened = true
                    ByteArrayInputStream(byteArrayOf(1))
                })
            }
            check(!opened)
        },
        "accepts exact 10 MiB and closes stream" to {
            val input = GeneratedInput(LIMIT)
            val bytes = BackupDocumentIo.readBounded(LIMIT.toLong(), { input })
            check(bytes.size == LIMIT)
            check(bytes.first() == 42.toByte() && bytes.last() == 42.toByte())
            check(input.closed)
        },
        "unknown or stale size stops at limit plus one and closes stream" to {
            for (declared in listOf(null, -1L, 1L)) {
                val input = GeneratedInput(LIMIT * 100)
                expectFailure<BackupDocumentTooLargeException> {
                    BackupDocumentIo.readBounded(declared, { input })
                }
                check(input.consumed == LIMIT + 1) { "Read ${input.consumed} bytes" }
                check(input.closed)
            }
        },
        "returns exact binary bytes without JSON decoding" to {
            val expected = byteArrayOf(0, -1, 123, 125)
            val actual = BackupDocumentIo.readBounded(null, { ByteArrayInputStream(expected) })
            check(actual.contentEquals(expected))
        },
        "provider read failure propagates and closes stream" to {
            val input = GeneratedInput(40000, failAfter = 8192)
            expectFailure<IOException> { BackupDocumentIo.readBounded(null, { input }) }
            check(input.closed)
            check(input.consumed < 40000)
        },
        "cancelled operation stops reading and closes stream" to {
            val input = GeneratedInput(LIMIT)
            expectFailure<BackupDocumentCancelledException> {
                BackupDocumentIo.readBounded(null, { input }, { input.consumed >= 8192 })
            }
            check(input.closed)
            check(input.consumed == 8192)
        },
        "finishing a session closes its resource and completes only once" to {
            var closed = 0
            val completions = mutableListOf<Any?>()
            val session = BackupDocumentSession { value, _, _ -> completions.add(value) }
            check(session.attach(Closeable { closed++ }))
            check(session.finish(false))
            check(!session.finish(true))
            check(session.isClosed)
            check(closed == 1)
            check(completions == listOf(false))
        },
        "activity close completes with an error and rejects late resources" to {
            val errors = mutableListOf<String?>()
            val session = BackupDocumentSession { _, code, _ -> errors.add(code) }
            check(session.finish(errorCode = "activity_closed", errorMessage = "Closed"))
            var closed = false
            check(!session.attach(Closeable { closed = true }))
            check(closed)
            check(errors == listOf("activity_closed"))
        },
    )
    var failures = 0
    tests.forEach { (name, test) ->
        try {
            test()
            println("PASS $name")
        } catch (error: Throwable) {
            failures++
            System.err.println("FAIL $name: $error")
        }
    }
    check(failures == 0) { "$failures/${tests.size} backup stream tests failed" }
    println("${tests.size} native backup stream tests passed")
}
