package com.rbrian.biblio.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.LibraryInfo
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.builtins.ListSerializer

/**
 * Added libraries and their usernames (in shared preferences), with each user's password
 * encrypted by a device-bound Android Keystore key that never leaves secure hardware, and each
 * user's borrowed-before index in a private file (not backed up).
 */
class LibraryStore(context: Context) {
    private val prefs = context.getSharedPreferences("libraries", Context.MODE_PRIVATE)
    private val secrets = context.getSharedPreferences("passwords", Context.MODE_PRIVATE)
    private val borrowedDir = File(context.filesDir, "borrowed")

    val libraries = mutableStateListOf<LibraryInfo>().apply {
        prefs.getString("libraries.v1", null)?.let { text ->
            runCatching { Core.json.decodeFromString<List<LibraryInfo>>(text) }.getOrNull()?.let(::addAll)
        }
    }

    fun library(subdomain: String) = libraries.firstOrNull { it.subdomain == subdomain }

    fun upsert(info: LibraryInfo) {
        val i = libraries.indexOfFirst { it.subdomain == info.subdomain }
        if (i >= 0) libraries[i] = info.copy(users = libraries[i].users) else libraries += info.copy(users = emptyList())
        save()
    }

    fun remove(subdomain: String) {
        library(subdomain)?.users?.forEach { deletePassword(subdomain, it); deleteBorrowed(subdomain, it); deleteBarcode(subdomain, it) }
        libraries.removeAll { it.subdomain == subdomain }
        code128.remove(subdomain)
        cards.edit().remove(CODE128_PREFIX + subdomain).apply()
        save()
    }

    fun addUser(subdomain: String, username: String, password: String) {
        val i = libraries.indexOfFirst { it.subdomain == subdomain }.takeIf { it >= 0 } ?: return
        setPassword(subdomain, username, password)
        if (username !in libraries[i].users) libraries[i] = libraries[i].copy(users = libraries[i].users + username)
        save()
    }

    fun removeUser(subdomain: String, username: String) {
        val i = libraries.indexOfFirst { it.subdomain == subdomain }.takeIf { it >= 0 } ?: return
        deletePassword(subdomain, username)
        deleteBorrowed(subdomain, username)
        deleteBarcode(subdomain, username)
        libraries[i] = libraries[i].copy(users = libraries[i].users - username)
        save()
    }

    private fun save() {
        prefs.edit().putString("libraries.v1", Core.json.encodeToString(ListSerializer(LibraryInfo.serializer()), libraries.toList())).apply()
    }

    // Passwords: AES-GCM with a Keystore key; stored as base64(iv || ciphertext).

    /** Synchronized so two first uses don't each generate the key. */
    @Synchronized
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private fun account(subdomain: String, username: String) = "$subdomain|$username"

    /** The saved password was there but couldn't be decrypted (the Keystore key was lost, as after a restore). */
    class PasswordUnreadable(cause: Throwable) : Exception(cause)

    /** Null if none is saved; throws [PasswordUnreadable] if one is but can't be read, so the user can enter it again. */
    fun password(subdomain: String, username: String): String? {
        val stored = secrets.getString(account(subdomain, username), null) ?: return null
        try {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
            return cipher.doFinal(bytes, 12, bytes.size - 12).decodeToString()
        } catch (e: Exception) {
            throw PasswordUnreadable(e)
        }
    }

    fun setPassword(subdomain: String, username: String, password: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(password.encodeToByteArray())
        secrets.edit().putString(account(subdomain, username), Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    fun deletePassword(subdomain: String, username: String) {
        secrets.edit().remove(account(subdomain, username)).apply()
    }

    // Cards: each user's library card number (so the account screen can rotate between a library's
    // cards) and the barcode type, a sticky choice per library.

    private val cards = context.getSharedPreferences("cards", Context.MODE_PRIVATE)
    private val code128 = mutableStateMapOf<String, Boolean>().apply {
        for ((k, v) in cards.all) if (k.startsWith(CODE128_PREFIX) && v is Boolean) put(k.removePrefix(CODE128_PREFIX), v)
    }

    fun barcode(subdomain: String, username: String): String? = cards.getString(BARCODE_PREFIX + account(subdomain, username), null)

    fun setBarcode(subdomain: String, username: String, barcode: String) {
        if (barcode(subdomain, username) != barcode) cards.edit().putString(BARCODE_PREFIX + account(subdomain, username), barcode).apply()
    }

    fun usesCode128(subdomain: String): Boolean = code128[subdomain] == true

    fun setCode128(subdomain: String, on: Boolean) {
        code128[subdomain] = on
        cards.edit().putBoolean(CODE128_PREFIX + subdomain, on).apply()
    }

    private fun deleteBarcode(subdomain: String, username: String) {
        cards.edit().remove(BARCODE_PREFIX + account(subdomain, username)).apply()
    }

    // Borrowed-before indexes (Core.BorrowedIndex's bytes), one file per user, named by a hash so
    // the name doesn't say whose it is.

    private fun borrowedFile(subdomain: String, username: String): AtomicFile {
        val digest = MessageDigest.getInstance("SHA-256").digest(account(subdomain, username).encodeToByteArray())
        return AtomicFile(File(borrowedDir, digest.take(16).joinToString("") { "%02x".format(it) } + ".json"))
    }

    fun loadBorrowed(subdomain: String, username: String): ByteArray? =
        runCatching { borrowedFile(subdomain, username).readFully() }.getOrNull()

    fun saveBorrowed(subdomain: String, username: String, bytes: ByteArray) {
        borrowedDir.mkdirs()
        val file = borrowedFile(subdomain, username)
        val out = runCatching { file.startWrite() }.getOrNull() ?: return
        try {
            out.write(bytes)
            file.finishWrite(out)
        } catch (e: java.io.IOException) {
            file.failWrite(out)
        }
    }

    fun deleteBorrowed(subdomain: String, username: String) {
        borrowedFile(subdomain, username).delete()
    }

    private companion object {
        const val KEY_ALIAS = "biblio-passwords"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val BARCODE_PREFIX = "barcode."
        const val CODE128_PREFIX = "code128."
    }
}
