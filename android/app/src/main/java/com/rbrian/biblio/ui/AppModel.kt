package com.rbrian.biblio.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.rbrian.biblio.core.LibraryInfo
import com.rbrian.biblio.data.LibraryStore

/**
 * Holds the open [Session] across configuration changes: rotating the screen keeps its client,
 * lists, and signed-in state rather than signing in again, and leaving or finishing the app closes it.
 */
class AppModel(application: Application) : AndroidViewModel(application) {
    private var session: Session? = null

    /** The session for this library and user (empty for a guest), opened if it isn't the current one. */
    fun sessionFor(library: LibraryInfo, user: String, store: LibraryStore): Session {
        session?.let { if (it.library.subdomain == library.subdomain && it.username == user) return it }
        close()
        return Session(library, user, store, getApplication()).also { session = it }
    }

    /** A guest session signs in as [user]: the new session takes over its search and selection. */
    fun signIn(guest: Session, user: String, store: LibraryStore) {
        val successor = Session(guest.library, user, store, getApplication())
        successor.inherit(guest)
        guest.close()
        session = successor
    }

    fun close() {
        session?.close()
        session = null
    }

    override fun onCleared() = close()
}
