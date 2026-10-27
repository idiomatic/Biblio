package com.rbrian.biblio.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The bridge to libbiblio, the Zig core shared with the Apple, GNOME and Windows apps.
 *
 * Every operation is a JSON request answered with `{"ok": true, "result": …}` or
 * `{"ok": false, "error": {…}}` (see core/include/biblio.h). Calls block, so they run on
 * [Dispatchers.IO]. The core paces requests app-wide to stay gentle with library sites.
 */
object Core {
    init {
        System.loadLibrary("biblio_jni")
    }

    val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }

    @JvmStatic private external fun nativeNewClient(subdomain: ByteArray, username: ByteArray, password: ByteArray?): Long
    @JvmStatic private external fun nativeSetPassword(client: Long, password: ByteArray)
    @JvmStatic private external fun nativeFreeClient(client: Long)
    @JvmStatic private external fun nativeCall(client: Long, request: ByteArray): ByteArray?

    /** A library error, with a message ready to show. */
    class Failure(val kind: String, message: String, val status: Int? = null) : Exception(message)

    /** One core client: a (library, username) session, or a guest when [username] is empty. */
    class Client(val subdomain: String, val username: String, password: String?) : AutoCloseable {
        private var handle: Long =
            nativeNewClient(subdomain.encodeToByteArray(), username.encodeToByteArray(), password?.encodeToByteArray())
        val isGuest get() = username.isEmpty()

        suspend fun <T> call(serializer: KSerializer<T>, op: String, args: JsonObjectBuilder.() -> Unit = {}): T =
            Core.call(handle, serializer, op, args)

        suspend fun call(op: String, args: JsonObjectBuilder.() -> Unit = {}): JsonElement =
            Core.callRaw(handle, op, args)

        /** After a password change, so automatic sign-in keeps working. */
        fun setPassword(password: String) = nativeSetPassword(handle, password.encodeToByteArray())

        override fun close() {
            if (handle != 0L) nativeFreeClient(handle)
            handle = 0L
        }
    }

    suspend fun <T> call(serializer: KSerializer<T>, op: String, args: JsonObjectBuilder.() -> Unit = {}): T =
        call(0L, serializer, op, args)

    suspend fun callRaw(op: String, args: JsonObjectBuilder.() -> Unit = {}): JsonElement = callRaw(0L, op, args)

    private suspend fun <T> call(handle: Long, serializer: KSerializer<T>, op: String, args: JsonObjectBuilder.() -> Unit): T =
        json.decodeFromJsonElement(serializer, callRaw(handle, op, args))

    /** Runs an operation that never touches the network (formatName, sortName, codabar) right away. */
    fun callNow(op: String, args: JsonObjectBuilder.() -> Unit = {}): JsonElement = decode(nativeCall(0L, request(op, args)))

    private fun request(op: String, args: JsonObjectBuilder.() -> Unit): ByteArray =
        buildJsonObject {
            put("op", kotlinx.serialization.json.JsonPrimitive(op))
            args()
        }.toString().encodeToByteArray()

    private suspend fun callRaw(handle: Long, op: String, args: JsonObjectBuilder.() -> Unit): JsonElement {
        val request = request(op, args)
        return decode(withContext(Dispatchers.IO) { nativeCall(handle, request) })
    }

    private fun decode(bytes: ByteArray?): JsonElement {
        if (bytes == null) throw Failure("unexpected", "Biblio couldn’t reach its library engine.")
        val response = json.parseToJsonElement(bytes.decodeToString()).jsonObject
        if (response["ok"]?.jsonPrimitive?.boolean == true) return response["result"] ?: JsonNull
        val error = response["error"]?.jsonObject ?: JsonObject(emptyMap())
        throw Failure(
            kind = error["kind"]?.jsonPrimitive?.contentOrNull ?: "unexpected",
            message = error["message"]?.jsonPrimitive?.contentOrNull ?: "Something went wrong.",
            status = error["status"]?.jsonPrimitive?.intOrNull,
        )
    }
}
