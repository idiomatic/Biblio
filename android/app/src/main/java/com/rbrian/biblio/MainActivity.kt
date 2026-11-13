package com.rbrian.biblio

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.viewmodel.compose.viewModel
import com.rbrian.biblio.data.LibraryStore
import com.rbrian.biblio.ui.AppModel
import com.rbrian.biblio.ui.BiblioTheme
import com.rbrian.biblio.ui.LibrariesScreen
import com.rbrian.biblio.ui.LibraryScreen
import com.rbrian.biblio.ui.SessionScreen

class MainActivity : ComponentActivity() {
    private val store by lazy { LibraryStore(applicationContext) }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            BiblioTheme {
                BiblioApp(store)
            }
        }
    }
}

/**
 * Libraries → one library's users → that account. Android shows one account at a time;
 * the account screen's menu switches back here. The open session lives in [AppModel].
 */
@Composable
fun BiblioApp(store: LibraryStore) {
    val model = viewModel<AppModel>()
    var library by rememberSaveable { mutableStateOf<String?>(null) }
    var user by rememberSaveable { mutableStateOf<String?>(null) }
    val info = library?.let(store::library)
    val session = if (info != null && user != null) model.sessionFor(info, user!!, store) else null
    LaunchedEffect(session == null) { if (session == null) model.close() }

    when {
        session != null -> {
            BackHandler { user = null }
            SessionScreen(
                session, store,
                onSwitch = { user = null },
                onSignIn = { signedInUser -> model.signIn(session, signedInUser, store); user = signedInUser },
            )
        }
        info != null -> {
            BackHandler { library = null }
            LibraryScreen(
                store = store,
                library = info,
                onBack = { library = null },
                onOpen = { user = it },
            )
        }
        else -> LibrariesScreen(store, onOpen = { library = it })
    }
}
