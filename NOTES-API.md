# BiblioCommons gateway notes

Discovered from the patron web app (`wccls.bibliocommons.com`) and its JS bundle.

Base: `https://gateway.bibliocommons.com/v2/libraries/{subdomain}`

Auth headers on every authenticated call: `X-Session-Id`, `X-Access-Token`, `Accept: application/json`.

| Purpose | Method / path | Notes |
|---|---|---|
| Log in | `POST /sessions` `{username,password}` | → `auth.sessionId`, `auth.authToken`, `auth.currentUserId`, `entities.users[uid].accounts[0]`, `entities.users[uid].preferences.language`, `userContact.email` |
| Current session | `GET /sessions/current` | |
| Holds | `GET /holds?accountId&page&sort&locale` | page size fixed at 25; `borrowing.holds.items` = hold ids, `entities.holds`, `entities.bibs` |
| Place hold | `POST /holds` `{metadataId,materialType,accountId,enableSingleClickHolds,materialParams:{branchId,errorMessageLocale}}` | |
| Cancel hold | `DELETE /holds` `{accountId,holdIds,metadataIds}` | |
| Checkouts | `GET /checkouts?accountId&page&sort&locale` | |
| Borrowing history | `GET /borrowinghistory?accountId&page&locale` | assumed newest first (the borrowed-before index checks: checkout dates never increase down a page, and new entries equal the growth of `pagination.count`) |
| Borrowing history setting | `PUT /accounts/{accountId}/settings/borrowingHistorySetting` `{enabled}` | current value: `entities.accounts[id].borrowingHistoryEnabled` in the login response |
| Search | `POST /bibs/search` `{query,searchType,page,sort,f_FORMAT,f_on_order,...}` | `catalogSearch.results[].representative`, `entities.bibs[id].{briefInfo,availability,policy}`; `availability.heldCopies` = people waiting |
| New titles | search with `query:"nw:[0 TO 180]", searchType:"bl", sort:"newly_acquired", f_on_order:"true"/"false"` | "Filter by" = `f_FORMAT`, `f_FICTION_TYPE`, `f_AUDIENCE`, `f_LANGUAGE` |
| Availability by location | `GET /bibs/{id}/availability` (public) | `entities.bibItems[*].{branchName,collection,callNumber,dueDate,availability.libraryStatus}` |
| Detail | `GET /catalogbibs/{id}` (public) | `entities.catalogBibs[id].fields[].items[].fieldValues[].primary.values` |
| Locations | `GET /locations?limit=100` (public) | |

Labels: page state JSON (`<script type="application/json">`) → `localization.messages` (`FORMAT.bluray`, `sort.*`), `branding.primaryBrandColor`.

Account settings are Rails forms on `https://{subdomain}.bibliocommons.com` (the gateway login's cookies authenticate them). GET the page, POST its form with the hidden `authenticity_token`:

| Setting | Page | Form action | Fields |
|---|---|---|---|
| Email | `/account/email` | `/account/contact_information` | `user_email`, `user_digital_email` |
| Password | `/account/password` | `/account/change_pin` | `old_password`, `new_password`, `new_password_confirm` (4–64 alphanumeric) |
| Pickup location | `/account/pickup_location` | `/account/preferred_branches` | `first_preference`, `second_preference`, `third_preference`, `sch_toggle` |
| Language | `/account/language` | `/account/user_lang` | `user_lang` (e.g. `en-US`) |

## Library quirks

Format refinements (core/src/formats.zig) record each library seen filing a format under a broader code:

| Library | Files | As | Told by |
|---|---|---|---|
| WCCLS | 4K Ultra HD Blu-ray (`UK`), and 4K + Blu-ray combos | `BLURAY` | "4K", "Ultra HD", or "UHD" in the edition (`briefInfo.edition`) or a bracketed title qualifier |
| WCCLS | 4K + Blu-ray + DVD combos (`UK`) | `DVD_PBLURAY` | the same |

## Library discovery (no account)

| Purpose | Method / path | Notes |
|---|---|---|
| Does the library exist | `GET https://gateway.bibliocommons.com/v2/libraries/{subdomain}/locations?limit=1` | 200 means it does |
| Name, color, languages, labels | `GET https://{subdomain}.bibliocommons.com/v2/search?query=library&searchType=keyword` | the host must stay on `{subdomain}.`; the page state JSON gives `branding` and `localization.messages` |
| Libraries using BiblioCommons | `GET https://www.bibliocommons.com/libraries-we-work-with`, then each page's "Next" link | the partner directory: name, website, region, and a wide logo |
| Library icon | the library website's `rel="icon"` and `apple-touch-icon` links, then `/apple-touch-icon.png` and `/favicon.ico` | the largest square of the first three candidates |
