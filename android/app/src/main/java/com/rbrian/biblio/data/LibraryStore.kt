package com.rbrian.biblio.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.compose.runtime.mutableStateListOf
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.LibraryInfo
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Added libraries and their usernames (in shared preferences), with each user's password
 * encrypted by a device-bound Android Keystore key that never leaves secure hardware.
 */
class LibraryStore(context: Context) {
    private val prefs = context.getSharedPreferences("libraries", Context.MODE_PRIVATE)
    private val secrets = context.getSharedPreferences("passwords", Context.MODE_PRIVATE)

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
        library(subdomain)?.users?.forEach { deletePassword(subdomain, it) }
        libraries.removeAll { it.subdomain == subdomain }
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
        libraries[i] = libraries[i].copy(users = libraries[i].users - username)
        save()
    }

    private fun save() {
        prefs.edit().putString("libraries.v1", Core.json.encodeToString(libraries.toList())).apply()
    }

    // Passwords: AES-GCM with a Keystore key; stored as base64(iv || ciphertext).

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

    fun password(subdomain: String, username: String): String? {
        val stored = secrets.getString(account(subdomain, username), null) ?: return null
        return runCatching {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
            cipher.doFinal(bytes, 12, bytes.size - 12).decodeToString()
        }.getOrNull()
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

    private companion object {
        const val KEY_ALIAS = "biblio-passwords"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
