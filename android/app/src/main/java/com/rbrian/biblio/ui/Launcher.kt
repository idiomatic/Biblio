package com.rbrian.biblio.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.LocalLibrary
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Button
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.rbrian.biblio.core.Core
import com.rbrian.biblio.core.DirectoryEntry
import com.rbrian.biblio.core.LibraryInfo
import com.rbrian.biblio.data.LibraryStore
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibrariesScreen(store: LibraryStore, onOpen: (String) -> Unit) {
    var adding by remember { mutableStateOf(false) }
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = { LargeTopAppBar(title = { Text("Libraries") }, scrollBehavior = scroll) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { adding = true },
                icon = { Icon(Icons.Filled.Add, contentDescription = null) },
                text = { Text("Add library") },
            )
        },
    ) { padding ->
        if (store.libraries.isEmpty()) {
            Column(
                Modifier.fillMaxSize().padding(padding).padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(Icons.Filled.LocalLibrary, contentDescription = null, modifier = Modifier.padding(bottom = 16.dp))
                Text("Add your library", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Search its catalog, place holds and see what you have checked out.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyColumn(contentPadding = padding) {
                items(store.libraries, key = { it.subdomain }) { lib ->
                    ListItem(
                        headlineContent = { Text(lib.name) },
                        supportingContent = {
                            Text(when (lib.users.size) { 0 -> "No users"; 1 -> "1 user"; else -> "${lib.users.size} users" })
                        },
                        leadingContent = {
                            LibraryIcon(
                                LibraryIcons.key(lib.website, lib.subdomain), lib.website, subdomain = lib.subdomain,
                                tint = brandColor(lib.primaryColor) ?: MaterialTheme.colorScheme.primary,
                            )
                        },
                        modifier = Modifier.clickable { onOpen(lib.subdomain) },
                    )
                }
            }
        }
    }
    if (adding) AddLibrarySheet(store, onDismiss = { adding = false })
}

/** Finds a library by catalog subdomain or address, or by name from BiblioCommons' partner list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddLibrarySheet(store: LibraryStore, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val directory = remember { mutableStateListOf<DirectoryEntry>() }

    LaunchedEffect(Unit) {
        var next: String? = null
        val seen = mutableSetOf<String>()
        do {
            val url = next
            val page = runCatching { Core.directoryPage(url) }.getOrNull() ?: break
            val fresh = page.entries.filter { seen.add(it.name) }
            directory += fresh
            next = page.next
        } while (next != null && fresh.isNotEmpty())
    }

    fun add(subdomain: String?) {
        if (subdomain == null) {
            error = "Enter a library name or catalog address."
            return
        }
        working = true
        error = null
        scope.launch {
            try {
                store.upsert(Core.libraryInfo(subdomain))
                onDismiss()
            } catch (e: Core.Failure) {
                error = e.message
            } finally {
                working = false
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Add library", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                label = { Text("Library") },
                placeholder = { Text("wccls or https://wccls.bibliocommons.com") },
                supportingText = { Text(error ?: "The name before “.bibliocommons.com”, or search by library name.") },
                isError = error != null,
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = {
                    add(runCatching { Core.subdomainFrom(text) }.getOrNull())
                }),
                modifier = Modifier.fillMaxWidth(),
                enabled = !working,
            )
            if (working) CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally))
            val t = text.trim()
            val suggestions = if (t.length < 2) emptyList() else directory.filter {
                it.name.contains(t, ignoreCase = true) || (it.website?.contains(t, ignoreCase = true) ?: false)
            }.take(12)
            LazyColumn {
                items(suggestions, key = { it.name }) { entry ->
                    ListItem(
                        headlineContent = { Text(entry.name) },
                        supportingContent = entry.region?.let { { Text(it) } },
                        leadingContent = { LibraryIcon(LibraryIcons.key(entry.website, entry.name), entry.website, logo = entry.logo) },
                        modifier = Modifier.clickable(enabled = !working) {
                            working = true
                            scope.launch {
                                val sub = runCatching { Core.resolveSubdomain(entry.name, entry.website) }.getOrNull()
                                working = false
                                if (sub == null) error = "Couldn’t find the catalog for ${entry.name}. Enter its subdomain instead."
                                else add(sub)
                            }
                        },
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(store: LibraryStore, library: LibraryInfo, onBack: () -> Unit, onOpen: (String) -> Unit) {
    var addingUser by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf(false) }
    Scaffold(
        topBar = {
            LargeTopAppBar(
                title = { Text(library.displayName) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
                actions = {
                    IconButton(onClick = {
                        // Removing a library without users loses nothing, so it doesn't ask.
                        if (library.users.isEmpty()) { store.remove(library.subdomain); onBack() } else confirmRemove = true
                    }) { Icon(Icons.Filled.Delete, "Remove library") }
                },
            )
        },
    ) { padding ->
        LazyColumn(contentPadding = padding) {
            items(library.users, key = { it }) { user ->
                ListItem(
                    headlineContent = { Text(user) },
                    leadingContent = { Icon(Icons.Filled.AccountCircle, contentDescription = null) },
                    trailingContent = {
                        IconButton(onClick = { store.removeUser(library.subdomain, user) }) { Icon(Icons.Filled.Delete, "Remove $user") }
                    },
                    modifier = Modifier.clickable { onOpen(user) },
                )
            }
            item {
                ListItem(
                    headlineContent = { Text("Add user") },
                    leadingContent = { Icon(Icons.Filled.PersonAdd, contentDescription = null) },
                    modifier = Modifier.clickable { addingUser = true },
                )
                HorizontalDivider()
                ListItem(
                    headlineContent = { Text("Browse as guest") },
                    supportingContent = { Text("Guests can search and browse the catalog but can’t place holds or see an account.") },
                    leadingContent = { Icon(Icons.Outlined.PersonOutline, contentDescription = null) },
                    modifier = Modifier.clickable { onOpen("") },
                )
            }
        }
    }
    if (addingUser) AddUserDialog(store, library, onDismiss = { addingUser = false }, onAdded = { addingUser = false; onOpen(it) })
    if (confirmRemove) AlertDialog(
        onDismissRequest = { confirmRemove = false },
        title = { Text("Remove ${library.name}?") },
        text = { Text("Its saved users and passwords will also be removed from this device.") },
        confirmButton = {
            TextButton(onClick = { store.remove(library.subdomain); confirmRemove = false; onBack() }) {
                Text("Remove", color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Cancel") } },
    )
}

/** Signs in once to check the username and password before saving them. */
@Composable
fun AddUserDialog(store: LibraryStore, library: LibraryInfo, onDismiss: () -> Unit, onAdded: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun signIn() {
        val user = username.trim()
        if (user.isEmpty() || password.isEmpty()) return
        working = true
        error = null
        scope.launch {
            Core.Client(library.subdomain, user, password).use { client ->
                try {
                    client.login(force = true)
                    store.addUser(library.subdomain, user, password)
                    onAdded(user)
                } catch (e: Core.Failure) {
                    error = e.message
                } finally {
                    working = false
                }
            }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sign in to ${library.displayName}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = username, onValueChange = { username = it }, label = { Text("Username or card number") },
                    singleLine = true, enabled = !working,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                )
                OutlinedTextField(
                    value = password, onValueChange = { password = it }, label = { Text("PIN or password") },
                    singleLine = true, enabled = !working,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { signIn() }),
                )
                Text(
                    error ?: "Your password is encrypted on this device and used to sign in again when the library ends your session.",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            Button(onClick = { signIn() }, enabled = !working && username.isNotBlank() && password.isNotEmpty()) {
                if (working) CircularProgressIndicator(Modifier.padding(end = 8.dp).size(16.dp), strokeWidth = 2.dp)
                Text("Sign in")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

