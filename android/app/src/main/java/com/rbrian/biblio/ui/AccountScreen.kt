package com.rbrian.biblio.ui

import android.app.Activity
import android.view.WindowManager
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.size
import com.rbrian.biblio.R
import com.rbrian.biblio.data.LibraryStore
import java.util.Locale
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
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
import kotlin.math.floor
import kotlin.math.round
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.rbrian.biblio.core.Core
import kotlinx.coroutines.launch

/** Library card, email, password, pickup location, language and borrowing history. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(session: Session, store: LibraryStore, chrome: Chrome) {
    val patron = session.patron
    val scope = rememberCoroutineScope()
    fun save(done: String, change: suspend Core.Client.() -> Unit, after: () -> Unit = {}) {
        scope.launch {
            try {
                session.client.change()
                session.refreshPatron()
                after()
                session.message = done
            } catch (e: Exception) {
                session.message = Core.messageOf(e, session.str(R.string.save_failed))
            }
        }
    }

    Column {
        TopAppBar(
            title = { Text(patron?.name ?: session.username) },
            actions = { OverflowMenu(chrome) },
        )
        if (patron == null) {
            Text(session.signInError ?: stringResource(R.string.signing_in), modifier = Modifier.padding(16.dp))
            return@Column
        }
        Column(
            Modifier.imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            LibraryCards(session, store)

            var email by remember(patron.email) { mutableStateOf(patron.email ?: "") }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = email, onValueChange = { email = it }, label = { Text(stringResource(R.string.email)) }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.weight(1f),
                )
                Button(onClick = { save(session.str(R.string.email_updated), { changeEmail(email) }) },
                    enabled = email.contains('@') && email != patron.email) { Text(stringResource(R.string.update)) }
            }

            var current by remember { mutableStateOf("") }
            var new by remember { mutableStateOf("") }
            var confirm by remember { mutableStateOf("") }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.password), style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(
                    value = current, onValueChange = { current = it }, label = { Text(stringResource(R.string.current_password)) },
                    singleLine = true, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = new, onValueChange = { new = it }, label = { Text(stringResource(R.string.new_password)) },
                    singleLine = true, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = confirm, onValueChange = { confirm = it }, label = { Text(stringResource(R.string.confirm_new_password)) },
                    singleLine = true, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth(),
                    isError = confirm.isNotEmpty() && confirm != new,
                )
                Button(
                    onClick = {
                        val newPassword = new
                        val currentPassword = current
                        save(session.str(R.string.password_changed), { changePassword(currentPassword, newPassword) }) {
                            // Keep the saved password and the core in step so automatic sign-in still works.
                            session.store.setPassword(session.library.subdomain, session.username, newPassword)
                            session.client.setPassword(newPassword)
                            current = ""; new = ""; confirm = ""
                        }
                    },
                    enabled = current.isNotEmpty() && new.isNotEmpty() && new == confirm,
                ) { Text(stringResource(R.string.change_password)) }
            }

            Picker(
                label = stringResource(R.string.pickup_location),
                options = session.locations.map { it.id to it.name },
                selected = patron.preferredPickup,
                footer = stringResource(R.string.pickup_footer),
            ) { id -> save(session.str(R.string.pickup_saved), { setPickup(id) }) }

            val languages = session.library.languages
            // The library answers in the account's language, so the catalog lists reload.
            val saveLanguage = { code: String ->
                save(session.str(R.string.language_changed), { setLanguage(code) }) {
                    session.search.reloadIfLoaded(); session.newTitles.reloadIfLoaded()
                }
            }
            Picker(
                label = stringResource(R.string.language),
                options = languages.map { it to (session.library.labels["LANGUAGE_NAME.$it"] ?: it) },
                selected = patron.language,
            ) { code -> saveLanguage(code) }
            // Never set automatically: the library language is the account's preference, not the app's.
            val system = remember(languages) { closestSystemLanguage(languages) }
            if (system != null && system != patron.language) TextButton(onClick = { saveLanguage(system) }) {
                Text(stringResource(R.string.use_system_language))
            }

            patron.borrowingHistoryEnabled?.let { enabled ->
                var confirmOff by remember { mutableStateOf(false) }
                ListItem(
                    headlineContent = { Text(stringResource(R.string.keep_borrowing_history)) },
                    supportingContent = { Text(stringResource(R.string.keep_borrowing_history_footer)) },
                    trailingContent = {
                        Switch(checked = enabled, onCheckedChange = { on ->
                            if (on) save(session.str(R.string.history_on), { setBorrowingHistory(true) }) { session.borrowed?.sync() }
                            else confirmOff = true
                        })
                    },
                )
                if (confirmOff) AlertDialog(
                    onDismissRequest = { confirmOff = false },
                    title = { Text(stringResource(R.string.turn_off_history_title)) },
                    text = { Text(stringResource(R.string.turn_off_history_text)) },
                    confirmButton = {
                        TextButton(onClick = {
                            confirmOff = false
                            save(session.str(R.string.history_off), { setBorrowingHistory(false) }) {
                                session.history.reloadIfLoaded()
                                session.borrowed?.clear()
                            }
                        }) { Text(stringResource(R.string.turn_off), color = MaterialTheme.colorScheme.error) }
                    },
                    dismissButton = { TextButton(onClick = { confirmOff = false }) { Text(stringResource(R.string.keep_history)) } },
                )
            }
            session.borrowed?.let { BorrowedRefresh(it, enabled = patron.borrowingHistoryEnabled != false) }
            VersionFooter(chrome.onAbout)
        }
    }
}

/** The library language closest to the system's: the same tag, else the same language. */
private fun closestSystemLanguage(languages: List<String>): String? {
    val system = Locale.getDefault()
    val tag = system.toLanguageTag().lowercase()
    fun String.normalized() = replace('_', '-').lowercase()
    return languages.firstOrNull { it.normalized() == tag }
        ?: languages.firstOrNull { it.normalized().substringBefore('-') == system.language.lowercase() }
}

@Composable
private fun Picker(label: String, options: List<Pair<String, String>>, selected: String?, footer: String? = null, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column {
        ListItem(
            headlineContent = { Text(label) },
            supportingContent = { Text(options.firstOrNull { it.first == selected }?.second ?: stringResource(R.string.not_set)) },
            modifier = Modifier.clickable { open = true },
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { open = false; if (id != selected) onPick(id) }) }
        }
        footer?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp)) }
    }
}

/** The library's card numbers as scannable barcodes: the signed-in user's first, then the others, swiping between them. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LibraryCards(session: Session, store: LibraryStore) {
    val subdomain = session.library.subdomain
    val barcode = session.patron?.barcode
    // The users of this library (observed), each with the card number saved when they last signed in.
    val users = store.library(subdomain)?.users.orEmpty()
    val cards = remember(users, barcode, session.username) {
        val others = users.filter { it != session.username }.mapNotNull { u -> store.barcode(subdomain, u)?.let { u to it } }
        listOfNotNull(barcode?.let { session.username to it }) + others
    }
    if (cards.isEmpty()) return
    val code128 = store.usesCode128(subdomain)
    val activity = LocalContext.current as? Activity
    // Full brightness while the card is shown, for self-checkout scanners.
    DisposableEffect(activity) {
        val window = activity?.window
        val previous = window?.attributes?.screenBrightness
        window?.let { it.attributes = it.attributes.apply { screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL } }
        onDispose { window?.let { w -> w.attributes = w.attributes.apply { screenBrightness = previous ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE } } }
    }
    val pager = rememberPagerState { cards.size }
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        HorizontalPager(pager, pageSpacing = 12.dp, modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth()) { page ->
            val (user, number) = cards[page]
            LibraryCard(number, code128, if (user == session.username) session.patron?.name ?: user else user)
        }
        if (cards.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            repeat(cards.size) { i ->
                Box(
                    Modifier.size(8.dp).background(
                        if (i == pager.currentPage) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant, CircleShape,
                    ),
                )
            }
        }
        SingleChoiceSegmentedButtonRow {
            SegmentedButton(
                selected = !code128, onClick = { store.setCode128(subdomain, false) },
                shape = SegmentedButtonDefaults.itemShape(0, 2),
            ) { Text(stringResource(R.string.codabar)) }
            SegmentedButton(
                selected = code128, onClick = { store.setCode128(subdomain, true) },
                shape = SegmentedButtonDefaults.itemShape(1, 2),
            ) { Text(stringResource(R.string.code_128)) }
        }
    }
}

/** One card: black bars on white in either theme, on whole pixels so scanners read them. */
@Composable
private fun LibraryCard(barcode: String, code128: Boolean, name: String) {
    val elements = remember(barcode, code128) {
        try {
            Core.barcode(barcode, code128)?.toList()
        } catch (e: Exception) {
            Core.messageOf(e, "")
            null
        } ?: emptyList()
    }
    val description = stringResource(R.string.card_description, name, barcode)
    Column(
        Modifier.widthIn(max = 420.dp).fillMaxWidth().background(Color.White, RoundedCornerShape(8.dp)).padding(12.dp)
            .semantics { contentDescription = description },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (elements.isNotEmpty()) Canvas(Modifier.fillMaxWidth().height(64.dp)) {
            val quiet = 10.0
            val total = elements.sum() + 2 * quiet
            // A whole number of pixels per narrow unit keeps every bar and space crisp; the card is centered.
            val unit = floor(size.width / total).coerceAtLeast(1.0)
            val origin = (size.width - total * unit) / 2 + quiet * unit
            var cursor = 0.0
            // Elements alternate bar, space, …; the gap after each character is a space, so even indices are bars.
            elements.forEachIndexed { i, w ->
                if (i % 2 == 0) {
                    val left = round(origin + cursor * unit).toFloat()
                    val right = maxOf(round(origin + (cursor + w) * unit).toFloat(), left + 1f)
                    drawRect(Color.Black, Offset(left, 0f), Size(right - left, size.height))
                }
                cursor += w
            }
        }
        Text(barcode, fontFamily = FontFamily.Monospace, color = Color.Black)
        Text(name, style = MaterialTheme.typography.bodySmall, color = Color.DarkGray)
    }
}
