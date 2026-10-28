package com.rbrian.biblio

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import com.rbrian.biblio.data.LibraryStore
import com.rbrian.biblio.ui.BiblioTheme
import com.rbrian.biblio.ui.LibrariesScreen
import com.rbrian.biblio.ui.LibraryScreen
import com.rbrian.biblio.ui.SessionScreen
import com.rbrian.biblio.ui.Session

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
 * the account screen's menu switches back here.
 */
@Composable
fun BiblioApp(store: LibraryStore) {
    var library by rememberSaveable { mutableStateOf<String?>(null) }
    var user by rememberSaveable { mutableStateOf<String?>(null) }
    val session = remember(library, user) {
        val lib = library?.let(store::library)
        if (lib != null && user != null) Session(lib, user!!, store) else null
    }

    when {
        session != null -> {
            BackHandler { user = null }
            SessionScreen(session, onSwitch = { user = null })
        }
        library != null && store.library(library!!) != null -> {
            BackHandler { library = null }
            LibraryScreen(
                store = store,
                library = store.library(library!!)!!,
                onBack = { library = null },
                onOpen = { user = it },
            )
        }
        else -> LibrariesScreen(store, onOpen = { library = it })
    }
}
