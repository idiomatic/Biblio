package com.rbrian.biblio.core

import kotlinx.serialization.Serializable

/**
 * The data every Biblio app shows, as libbiblio returns it (core/src/models.zig). The JNI shim
 * builds these with their primary constructors, whose parameters follow the core's C structs
 * (android/native/src/jni.zig), so keep the parameter order and types in step.
 */

data class Bib(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val authors: List<String> = emptyList(),
    val format: String = "UNKNOWN",
    val publicationDate: String? = null,
    val edition: String? = null,
    val callNumber: String? = null,
    val summary: String? = null,
    val jacketSmall: String? = null,
    val jacketLarge: String? = null,
    val materialType: String = "PHYSICAL",
    val holdable: Boolean = false,
    val status: String? = null,
    val heldCopies: Int = 0,
    val availableCopies: Int = 0,
    val totalCopies: Int = 0,
    val onOrderCopies: Int = 0,
) {
    /** "2026" from "2026", "20261006" or "03/23/2027". */
    val year: String?
        get() {
            val d = publicationDate ?: return null
            if (d.length == 4) return d
            if (d.length == 8 && d.all(Char::isDigit)) return d.take(4)
            return Regex("""\b(1[5-9]|20)\d\d\b""").find(d)?.value ?: d
        }
}

data class Hold(
    val id: String,
    val metadataId: String,
    val status: String,
    val position: Int? = null,
    val pickupLocation: String? = null,
    val expiryDate: String? = null,
    val pickupByDate: String? = null,
    val suspendEndDate: String? = null,
    val canCancel: Boolean = false,
) {
    val isReady get() = status == "READY_FOR_PICKUP"
}

data class Checkout(
    val id: String,
    val metadataId: String,
    val status: String? = null,
    val dueDate: String? = null,
    val checkoutDate: String? = null,
    val timesRenewed: Int? = null,
)

data class HistoryEntry(
    val id: String,
    val metadataId: String,
    val checkoutDate: String? = null,
    val returnedDate: String? = null,
)

/** The signed-in account's relationship to an item: kind is "onHold" or "checkedOut". */
data class AccountStatus(val kind: String, val ready: Boolean = false, val position: Int? = null, val due: String? = null)

data class ListEntry(
    val id: String,
    val bib: Bib,
    /** "catalog", "hold", "checkout" or "history". */
    val kind: String,
    val serverIndex: Int = 0,
    val hold: Hold? = null,
    val checkout: Checkout? = null,
    val history: HistoryEntry? = null,
    val accountStatus: AccountStatus? = null,
)

data class FacetValue(val value: String, val count: Int)
data class Facet(val id: String, val values: List<FacetValue>)

data class ListPage(
    val entries: List<ListEntry>,
    val page: Int,
    val pages: Int,
    val count: Int,
    val pageSize: Int = 25,
    val facets: List<Facet> = emptyList(),
    val sortOptions: List<String> = emptyList(),
    val appliedSort: String? = null,
)

data class CopyAvailability(
    val id: String,
    val branch: String,
    val status: String,
    val isAvailable: Boolean,
    val collection: String? = null,
    val callNumber: String? = null,
    val dueDate: String? = null,
    val isOnOrder: Boolean = false,
    /** available, onOrder, out, held, transit, repair, missing, withdrawn, claimsReturned, libraryUseOnly, other. */
    val kind: String = "other",
)

data class DetailField(val label: String, val values: List<String>)
data class Location(val id: String, val name: String)

data class Patron(
    val userId: Long,
    val accountId: Long,
    val name: String,
    val email: String? = null,
    val language: String,
    val barcode: String? = null,
    val preferredPickup: String? = null,
    val borrowingHistoryEnabled: Boolean? = null,
)

@Serializable
data class LibraryInfo(
    val subdomain: String,
    val name: String,
    val shortName: String? = null,
    val primaryColor: String? = null,
    val website: String? = null,
    val labels: Map<String, String> = emptyMap(),
    val languages: List<String> = emptyList(),
    val users: List<String> = emptyList(),
) {
    val displayName get() = shortName ?: name

    /** The library's own name for a format code, else the core's English one. */
    fun formatName(code: String): String = runCatching { Core.formatName(code, labels) }.getOrDefault(code.prettified())

    fun sortName(id: String): String = runCatching { Core.sortName(id, labels) }.getOrDefault(id.prettified())
}

/** "NEWLY_ACQUIRED" → "Newly acquired" */
fun String.prettified(): String = replace('_', ' ').lowercase().replaceFirstChar { it.uppercase() }

data class DirectoryEntry(val name: String, val website: String? = null, val region: String? = null, val logo: String? = null)

data class DirectoryPage(val entries: List<DirectoryEntry>, val next: String? = null)

/** A hold the library declined to cancel. */
data class Refusal(val holdId: String, val reason: String)
