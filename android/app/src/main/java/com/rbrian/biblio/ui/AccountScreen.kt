package com.rbrian.biblio.ui

import android.app.Activity
import android.view.WindowManager
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SwitchAccount
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.rbrian.biblio.core.Core
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive

/** Library card, email, password, pickup location, language and borrowing history. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(session: Session, onSwitch: () -> Unit) {
    val patron = session.patron
    val scope = rememberCoroutineScope()
    fun save(op: String, done: String, args: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit, after: () -> Unit = {}) {
        scope.launch {
            try {
                session.client.call(Boolean.serializer(), op, args)
                session.refreshPatron()
                after()
                session.message = done
            } catch (e: Core.Failure) {
                session.message = e.message
            }
        }
    }

    Column {
        TopAppBar(
            title = { Text(patron?.name ?: session.username) },
            actions = { IconButton(onClick = onSwitch) { Icon(Icons.Filled.SwitchAccount, "Switch user or library") } },
        )
        if (patron == null) {
            Text(session.signInError ?: "Signing in…", modifier = Modifier.padding(16.dp))
            return@Column
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            patron.barcode?.let { LibraryCard(it) }

            var email by remember(patron.email) { mutableStateOf(patron.email ?: "") }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = email, onValueChange = { email = it }, label = { Text("Email") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.weight(1f),
                )
                Button(onClick = { save("changeEmail", "Email address updated.", { put("email", JsonPrimitive(email)) }) },
                    enabled = email.contains('@') && email != patron.email) { Text("Update") }
            }

            var current by remember { mutableStateOf("") }
            var new by remember { mutableStateOf("") }
            var confirm by remember { mutableStateOf("") }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Password", style = MaterialTheme.typography.titleMedium)
                for ((label, value, set) in listOf(
                    Triple("Current password", current) { v: String -> current = v },
                    Triple("New password", new) { v: String -> new = v },
                    Triple("Confirm new password", confirm) { v: String -> confirm = v },
                )) OutlinedTextField(
                    value = value, onValueChange = set, label = { Text(label) }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth(),
                    isError = label.startsWith("Confirm") && confirm.isNotEmpty() && confirm != new,
                )
                Button(
                    onClick = {
                        val newPassword = new
                        save("changePassword", "Password changed.", {
                            put("current", JsonPrimitive(current)); put("new", JsonPrimitive(newPassword))
                        }) {
                            // Keep the saved password and the core in step so automatic sign-in still works.
                            session.store.setPassword(session.library.subdomain, session.username, newPassword)
                            session.client.setPassword(newPassword)
                            current = ""; new = ""; confirm = ""
                        }
                    },
                    enabled = current.isNotEmpty() && new.isNotEmpty() && new == confirm,
                ) { Text("Change password") }
            }

            Picker(
                label = "Pickup location",
                options = session.locations.map { it.id to it.name },
                selected = patron.preferredPickup,
                footer = "Used for new holds unless you choose another location when placing one.",
            ) { id -> save("setPickup", "Default pickup location saved.", { put("branchId", JsonPrimitive(id)) }) }

            Picker(
                label = "Language",
                options = session.library.languages.map { it to (session.library.labels["LANGUAGE_NAME.$it"] ?: it) },
                selected = patron.language,
            ) { code ->
                save("setLanguage", "Language changed.", { put("code", JsonPrimitive(code)) }) {
                    session.search.reloadIfLoaded(); session.newTitles.reloadIfLoaded()
                }
            }

            patron.borrowingHistoryEnabled?.let { enabled ->
                var confirmOff by remember { mutableStateOf(false) }
                ListItem(
                    headlineContent = { Text("Keep borrowing history") },
                    supportingContent = { Text("When on, the library keeps a list of the items you check out.") },
                    trailingContent = {
                        Switch(checked = enabled, onCheckedChange = { on ->
                            if (on) save("setBorrowingHistory", "Borrowing history turned on.", { put("enabled", JsonPrimitive(true)) })
                            else confirmOff = true
                        })
                    },
                )
                if (confirmOff) AlertDialog(
                    onDismissRequest = { confirmOff = false },
                    title = { Text("Turn off borrowing history?") },
                    text = { Text("The library may permanently delete your existing borrowing history.") },
                    confirmButton = {
                        TextButton(onClick = {
                            confirmOff = false
                            save("setBorrowingHistory", "Borrowing history turned off.", { put("enabled", JsonPrimitive(false)) }) {
                                session.history.reloadIfLoaded()
                            }
                        }) { Text("Turn off", color = MaterialTheme.colorScheme.error) }
                    },
                    dismissButton = { TextButton(onClick = { confirmOff = false }) { Text("Keep history") } },
                )
            }
        }
    }
}

@Composable
private fun Picker(label: String, options: List<Pair<String, String>>, selected: String?, footer: String? = null, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column {
        ListItem(
            headlineContent = { Text(label) },
            supportingContent = { Text(options.firstOrNull { it.first == selected }?.second ?: "Not set") },
            modifier = Modifier.clickable { open = true },
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { open = false; if (id != selected) onPick(id) }) }
        }
        footer?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp)) }
    }
}

/**
 * The library card as a scannable Codabar barcode: black on white in either theme, with the
 * screen at full brightness while it is shown, for self-checkout scanners.
 */
@Composable
private fun LibraryCard(barcode: String) {
    val activity = LocalContext.current as? Activity
    DisposableEffect(activity) {
        val window = activity?.window
        val previous = window?.attributes?.screenBrightness
        window?.let { it.attributes = it.attributes.apply { screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL } }
        onDispose { window?.let { w -> w.attributes = w.attributes.apply { screenBrightness = previous ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE } } }
    }
    val elements = remember(barcode) {
        runCatching { (Core.callNow("codabar") { put("value", JsonPrimitive(barcode)) } as JsonArray).mapNotNull { it.jsonPrimitive.doubleOrNull } }
            .getOrDefault(emptyList())
    }
    Column(
        Modifier.fillMaxWidth().widthIn(max = 420.dp).background(Color.White, RoundedCornerShape(8.dp)).padding(12.dp)
            .semantics { contentDescription = "Library card barcode $barcode" },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (elements.isNotEmpty()) Canvas(Modifier.fillMaxWidth().height(64.dp)) {
            val quiet = 10.0
            val unit = size.width.toDouble() / (elements.sum() + 2 * quiet)
            var x = quiet * unit
            // Elements alternate bar, space, …; the gap after each character is a space, so even indices are bars.
            elements.forEachIndexed { i, w ->
                if (i % 2 == 0) drawRect(Color.Black, Offset(x.toFloat(), 0f), Size((w * unit).toFloat(), size.height))
                x += w * unit
            }
        }
        Text(barcode, fontFamily = FontFamily.Monospace, color = Color.Black)
    }
}
