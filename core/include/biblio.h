/*
 * libbiblio: the BiblioCommons patron client shared by the Biblio apps.
 *
 * Every operation is one JSON request and one JSON response, so each app's binding is a
 * few functions. Calls block (they make network requests, paced app-wide to stay gentle
 * with the library sites), so apps call them from a background thread. Clients are safe
 * to use from several threads at once.
 *
 * Request:  {"op": "<name>", ...arguments}
 * Response: {"ok": true, "result": ...}
 *        or {"ok": false, "error": {"kind": "...", "message": "...", "status": 404}}
 *
 * Error kinds: signInRequired, missingCredentials, loginFailed, http, network,
 * unexpected, notALibrary, badRequest. `message` is ready to show to the user.
 *
 * Operations without a client (pass NULL):
 *   subdomainFrom     {input}                    -> "wccls" | null
 *   libraryInfo       {subdomain}                -> LibraryInfo
 *   libraryExists     {subdomain}                -> bool
 *   directoryPage     {url?}                     -> {entries: [DirectoryEntry], next: url | null}
 *   resolveSubdomain  {name, website?}           -> "subdomain" | null
 *   formatName        {code, labels?}            -> "Blu-ray Disc"
 *   sortName          {id, labels?}              -> "Newly acquired"
 *   readableTint      {hex, dark}                -> "#RRGGBB" | null (brand color at 4.5:1 contrast)
 *
 * Operations on a client:
 *   configure         {language?, sampleAccount?} -> true
 *   status            {}                          -> {active, title?, url?, bytes}
 *   login             {force?}                    -> Patron
 *   patron            {}                          -> Patron | null (no network)
 *   search            {query, searchType?, filters?, page?, sort?, format?} -> ListPage
 *   availability      {metadataId}                -> [CopyAvailability]
 *   details           {metadataId}                -> [DetailField]
 *   locations         {}                          -> [Location]
 *   holds | checkouts | history {page?, sort?}    -> ListPage
 *   placeHold         {metadataId, materialType, pickupBranch?} -> true
 *   cancelHolds       {holds: [{id, metadataId}]} -> {refused: [{holdId, reason}]}
 *   accountSettings   {}                          -> {email?, pickup?, language?}
 *   setPickup         {branchId}                  -> true
 *   setLanguage       {code}                      -> true
 *   setBorrowingHistory {enabled}                 -> true
 *   changeEmail       {email}                     -> true
 *   changePassword    {current, new}              -> true (the app then saves the new password)
 *
 * The result shapes (Bib, ListEntry, ListPage, Hold, ...) are documented in docs/core.md.
 */
#ifndef BIBLIO_H
#define BIBLIO_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct biblio_client biblio_client;

/* Memory passed between the app and the core. Results from biblio_call, passwords from the
 * password callback, and transport response buffers are all allocated with biblio_alloc
 * and freed with biblio_free, whichever side created them. */
void *biblio_alloc(size_t len);
void biblio_free(void *ptr);

const char *biblio_version(void);

/* Returns the saved password for (subdomain, username), allocated with biblio_alloc and
 * NUL-terminated, or NULL if none is saved. The core wipes and frees it. */
typedef char *(*biblio_password_fn)(void *ctx, const char *subdomain, const char *username);

/* An empty username makes a guest client, which can only search the catalog. */
biblio_client *biblio_client_new(const char *subdomain, const char *username,
                                 biblio_password_fn password, void *ctx);
void biblio_client_free(biblio_client *client);

/* Runs one operation and returns the JSON response (free with biblio_free). Blocks. */
char *biblio_call(biblio_client *client, const char *request_json);

/* Optional: route HTTP through the app's own stack (system trust store, proxies).
 * The transport sends exactly one request: it must not follow redirects or store cookies
 * (the core does both). Return 0 on success with status, headers and body filled in;
 * nonzero if the request could not be sent. */
typedef struct {
    const char *name;
    const char *value;
} biblio_header;

typedef struct {
    const char *method;
    const char *url;
    const biblio_header *headers;
    size_t header_count;
    const unsigned char *body; /* NULL when there is no body */
    size_t body_len;
} biblio_http_request;

typedef struct {
    int status;
    char *headers; /* "Name: value\r\n" lines, from biblio_alloc; repeat Set-Cookie per cookie */
    size_t headers_len;
    unsigned char *body; /* from biblio_alloc */
    size_t body_len;
} biblio_http_response;

typedef int (*biblio_transport_fn)(void *ctx, const biblio_http_request *request,
                                   biblio_http_response *response);

/* Call once at startup, before creating clients. NULL restores the built-in transport. */
void biblio_set_transport(biblio_transport_fn transport, void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* BIBLIO_H */
