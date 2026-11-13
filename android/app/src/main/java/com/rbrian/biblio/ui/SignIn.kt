package com.rbrian.biblio.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.rbrian.biblio.R
import com.rbrian.biblio.core.LibraryInfo
import com.rbrian.biblio.data.LibraryStore
import kotlinx.coroutines.launch

/**
 * A guest placing a hold (or asking to sign in): the library's saved users and "Add User…". The
 * window keeps its search, section, and selection when one signs in. With no saved user it goes
 * straight to the sign-in form.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GuestSignInSheet(store: LibraryStore, library: LibraryInfo, onDismiss: () -> Unit, onSignedIn: (String) -> Unit) {
    var adding by remember { mutableStateOf(false) }
    // The library as saved, so a user added here shows without leaving.
    val users = store.library(library.subdomain)?.users.orEmpty()
    if (adding || users.isEmpty()) {
        AddUserDialog(store, library, onDismiss = { adding = false; if (users.isEmpty()) onDismiss() }, onAdded = onSignedIn)
        return
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(bottom = 24.dp)) {
            Text(stringResource(R.string.sign_in_to, library.displayName), style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp))
            for (user in users) ListItem(
                headlineContent = { Text(user) },
                leadingContent = { Icon(Icons.Filled.AccountCircle, null) },
                modifier = Modifier.clickable { onSignedIn(user) },
            )
            ListItem(
                headlineContent = { Text(stringResource(R.string.add_user_ellipsis)) },
                leadingContent = { Icon(Icons.Filled.PersonAdd, null) },
                modifier = Modifier.clickable { adding = true },
            )
        }
    }
}

/** The saved password couldn't be read (as after restoring to another device): type it again to keep the user. */
@Composable
fun ReenterPasswordDialog(session: Session, onSwitch: () -> Unit) {
    val scope = rememberCoroutineScope()
    var password by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun submit() {
        if (password.isEmpty() || working) return
        working = true
        error = null
        scope.launch {
            error = session.reenterPassword(password)
            working = false
        }
    }

    AlertDialog(
        onDismissRequest = onSwitch,
        title = { Text(stringResource(R.string.enter_password_again)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.imePadding()) {
                Text(stringResource(R.string.password_unreadable_for, session.username))
                OutlinedTextField(
                    value = password, onValueChange = { password = it }, label = { Text(stringResource(R.string.pin_or_password)) },
                    singleLine = true, enabled = !working, visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { Button(onClick = { submit() }, enabled = !working && password.isNotEmpty()) { Text(stringResource(R.string.sign_in)) } },
        dismissButton = { TextButton(onClick = onSwitch) { Text(stringResource(R.string.cancel)) } },
    )
}
