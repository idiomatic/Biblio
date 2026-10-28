/*
 * libbiblio: the BiblioCommons patron client shared by the Biblio apps.
 *
 * Every operation is a C function taking C arguments and returning C structs, such as
 * biblio_search(client, &query, &page, &err). Calls block (they may make several network
 * requests, paced app-wide to stay gentle with library sites), so make them off the UI
 * thread. Clients are safe to use from several threads at once. The full guide is
 * docs/core.md.
 */
#ifndef BIBLIO_H
#define BIBLIO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------------------
 * Memory, clients and transport
 * ------------------------------------------------------------------------------------- */

/* Memory that crosses the boundary: strings and arrays the core returns, passwords from the
 * password callback, and transport response buffers. Whichever side frees it uses
 * biblio_free. Result structs have their own biblio_<type>_free instead. */
void *biblio_alloc(size_t len);
void biblio_free(void *ptr);

const char *biblio_version(void);

typedef struct biblio_client biblio_client;

/* Returns the saved password for (subdomain, username), allocated with biblio_alloc and
 * NUL-terminated, or NULL if none is saved. The core wipes and frees it. */
typedef char *(*biblio_password_fn)(void *ctx, const char *subdomain, const char *username);

/* An empty username makes a guest client, which can only use the catalog. */
biblio_client *biblio_client_new(const char *subdomain, const char *username,
                                 biblio_password_fn password, void *ctx);
/* No call on the client may still be running. */
void biblio_client_free(biblio_client *client);

/* Optional: route HTTP through the app's own stack (system trust store, proxies). The
 * transport sends exactly one request: it must not follow redirects or store cookies (the
 * core does both). Return 0 with status, headers and body filled in, or nonzero if the
 * request could not be sent. */
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
    char *headers; /* "Name: value\r\n" lines, from biblio_alloc; one Set-Cookie line per cookie */
    size_t headers_len;
    unsigned char *body; /* from biblio_alloc */
    size_t body_len;
} biblio_http_response;

typedef int (*biblio_transport_fn)(void *ctx, const biblio_http_request *request,
                                   biblio_http_response *response);

/* Call once at startup, before creating clients. NULL restores the built-in transport. */
void biblio_set_transport(biblio_transport_fn transport, void *ctx);

/* ---------------------------------------------------------------------------------------
 * Operations
 *
 * Functions that can fail return a biblio_result (BIBLIO_OK is 0). On failure, if `err` is
 * not NULL, it receives the kind, the HTTP status (for BIBLIO_HTTP) and a message for
 * people; release it with biblio_error_clear. Results come back through an out-parameter
 * as one allocation, strings and arrays included, freed with that type's
 * biblio_<type>_free. Pass NULL for an out-parameter to discard the result.
 *
 * Optional strings are NULL when absent. Optional numbers and booleans have a has_<name>
 * flag. Arrays are a pointer plus <name>_count.
 * ------------------------------------------------------------------------------------- */

typedef enum {
    BIBLIO_OK = 0,
    BIBLIO_SIGN_IN_REQUIRED,   /* an account operation on a guest client */
    BIBLIO_MISSING_CREDENTIALS,/* the password callback returned NULL */
    BIBLIO_LOGIN_FAILED,       /* the library rejected the username or password */
    BIBLIO_HTTP,               /* the gateway or website returned an error status */
    BIBLIO_NETWORK,            /* the library could not be reached */
    BIBLIO_UNEXPECTED,         /* the library refused (e.g. hold limit) or a page could not be read */
    BIBLIO_NOT_A_LIBRARY,      /* no BiblioCommons catalog at that subdomain */
    BIBLIO_BAD_REQUEST,        /* a missing argument or client: a bug in the caller */
    BIBLIO_OUT_OF_MEMORY,
} biblio_result;

typedef struct {
    biblio_result kind;
    int status;    /* HTTP status for BIBLIO_HTTP, else 0 */
    char *message; /* for people; NULL when there is no error */
} biblio_error;

void biblio_error_clear(biblio_error *err);

typedef struct {
    const char *key;
    const char *value;
} biblio_pair;

/* A catalog record. */
typedef struct {
    const char *id;
    const char *title;
    const char *subtitle;
    const char *const *authors;
    size_t authors_count;
    const char *format; /* a format code; see biblio_format_name */
    const char *publication_date;
    const char *edition;
    const char *call_number;
    const char *summary;
    const char *jacket_small;
    const char *jacket_large;
    const char *material_type; /* pass to biblio_place_hold */
    bool holdable;
    const char *status; /* AVAILABLE, UNAVAILABLE, ON_ORDER, ... */
    int64_t held_copies; /* people waiting */
    int64_t available_copies;
    int64_t total_copies;
    int64_t on_order_copies;
} biblio_bib_t;

typedef struct {
    const char *id;
    const char *metadata_id;
    const char *status; /* READY_FOR_PICKUP, NOT_YET_AVAILABLE, IN_TRANSIT, ... */
    bool has_position;
    int64_t position;
    const char *pickup_location;
    const char *expiry_date;
    const char *pickup_by_date;
    const char *suspend_end_date;
    bool can_cancel;
} biblio_hold_t;

typedef struct {
    const char *id;
    const char *metadata_id;
    const char *status;
    const char *due_date;
    const char *checkout_date;
    bool has_times_renewed;
    int64_t times_renewed;
} biblio_checkout_t;

typedef struct {
    const char *id;
    const char *metadata_id;
    const char *checkout_date;
    const char *returned_date;
} biblio_history_entry_t;

typedef struct {
    const char *kind; /* "onHold" or "checkedOut" */
    bool ready;
    bool has_position;
    int64_t position;
    const char *due;
} biblio_account_status_t;

typedef struct {
    const char *id;
    biblio_bib_t bib;
    const char *kind; /* "catalog", "hold", "checkout" or "history" */
    int64_t server_index;
    const biblio_hold_t *hold;                     /* NULL unless held */
    const biblio_checkout_t *checkout;             /* NULL unless a checkout */
    const biblio_history_entry_t *history;         /* NULL unless history */
    const biblio_account_status_t *account_status; /* NULL if the account has no relationship */
} biblio_list_entry_t;

typedef struct {
    const char *value;
    int64_t count;
} biblio_facet_value_t;

typedef struct {
    const char *id; /* e.g. "FORMAT" */
    const biblio_facet_value_t *values;
    size_t values_count;
} biblio_facet_t;

typedef struct {
    void *owner;
    const biblio_list_entry_t *entries;
    size_t entries_count;
    int64_t page; /* 1-based */
    int64_t pages;
    int64_t count; /* across all pages */
    int64_t page_size;
    const biblio_facet_t *facets; /* search only */
    size_t facets_count;
    const char *const *sort_options;
    size_t sort_options_count;
    const char *applied_sort;
} biblio_list_page_t;

typedef struct {
    const char *id;
    const char *branch;
    const char *status; /* the library's own wording */
    bool is_available;
    const char *collection;
    const char *call_number;
    const char *due_date;
    bool is_on_order;
    /* available, onOrder, out, held, transit, repair, missing, withdrawn, claimsReturned,
     * libraryUseOnly or other */
    const char *kind;
} biblio_copy_t;

typedef struct {
    void *owner;
    const biblio_copy_t *items;
    size_t items_count;
} biblio_copy_list_t;

typedef struct {
    const char *label;
    const char *const *values;
    size_t values_count;
} biblio_detail_field_t;

typedef struct {
    void *owner;
    const biblio_detail_field_t *items;
    size_t items_count;
} biblio_detail_list_t;

typedef struct {
    const char *id;
    const char *name;
} biblio_location_t;

typedef struct {
    void *owner;
    const biblio_location_t *items;
    size_t items_count;
} biblio_location_list_t;

typedef struct {
    void *owner;
    int64_t user_id;
    int64_t account_id;
    const char *name;
    const char *email;
    const char *language;
    const char *barcode;
    const char *preferred_pickup;
    bool has_borrowing_history_enabled; /* false when the library doesn't say */
    bool borrowing_history_enabled;
} biblio_patron_t;

typedef struct {
    void *owner;
    const char *subdomain;
    const char *name;
    const char *short_name;
    const char *primary_color; /* "#RRGGBB" */
    const char *website;
    const biblio_pair *labels; /* FORMAT.*, AUDIENCE.*, LANGUAGE.*, LANGUAGE_NAME.*, sort.* */
    size_t labels_count;
    const char *const *languages;
    size_t languages_count;
    const char *const *users; /* always empty from the core; the app keeps users */
    size_t users_count;
} biblio_library_info_t;

typedef struct {
    const char *name;
    const char *website;
    const char *region;
    const char *logo;
} biblio_directory_entry_t;

typedef struct {
    void *owner;
    const biblio_directory_entry_t *entries;
    size_t entries_count;
    const char *next; /* the next page's URL, or NULL */
} biblio_directory_page_t;

typedef struct {
    const char *hold_id;
    const char *reason;
} biblio_refusal_t;

typedef struct {
    void *owner;
    const biblio_refusal_t *items;
    size_t items_count;
} biblio_refusal_list_t;

typedef struct {
    void *owner;
    const char *email;
    const char *pickup;
    const char *language;
} biblio_account_settings_t;

typedef struct {
    void *owner;
    uint32_t active; /* requests in flight */
    const char *title;
    const char *url;
    uint64_t bytes;
} biblio_fetch_status_t;

typedef struct {
    const char *query;
    const char *search_type; /* "smart" (NULL) or "bl" for field-qualified queries */
    const biblio_pair *filters; /* extra form fields such as f_AUDIENCE=adult; may be NULL */
    size_t filter_count;
    int64_t page; /* 1-based; 0 means 1 */
    const char *sort;
    const char *format;
} biblio_search_query;

typedef struct {
    const char *id;
    const char *metadata_id;
} biblio_hold_ref;

/* Freeing results. Each accepts NULL. */
void biblio_library_info_free(biblio_library_info_t *);
void biblio_directory_page_free(biblio_directory_page_t *);
void biblio_fetch_status_free(biblio_fetch_status_t *);
void biblio_patron_free(biblio_patron_t *);
void biblio_list_page_free(biblio_list_page_t *);
void biblio_copy_list_free(biblio_copy_list_t *);
void biblio_detail_list_free(biblio_detail_list_t *);
void biblio_location_list_free(biblio_location_list_t *);
void biblio_refusal_list_free(biblio_refusal_list_t *);
void biblio_account_settings_free(biblio_account_settings_t *);

/* Library operations: no client. Returned strings and arrays are freed with biblio_free. */

/* "wccls" from "WCCLS", "https://smpl.bibliocommons.com/", ...; NULL if not a subdomain. No network. */
char *biblio_subdomain_from(const char *input);
biblio_result biblio_library_info(const char *subdomain, biblio_library_info_t **out, biblio_error *err);
bool biblio_library_exists(const char *subdomain);
/* url NULL for the first page, then each page's next until it is NULL. */
biblio_result biblio_directory_page(const char *url, biblio_directory_page_t **out, biblio_error *err);
/* Guesses and confirms a directory entry's subdomain; NULL if none. */
char *biblio_resolve_subdomain(const char *name, const char *website);
/* Display names, preferring the library's labels (may be NULL). No network. */
char *biblio_format_name(const char *code, const biblio_pair *labels, size_t label_count);
char *biblio_sort_name(const char *id, const biblio_pair *labels, size_t label_count);
/* The brand color adjusted to 4.5:1 contrast with a light or dark bar; NULL if not a color. No network. */
char *biblio_readable_tint(const char *hex, bool dark);
/* Codabar bar and space widths in narrow units, bar first (wide = 2.5); NULL if the value
 * can't be encoded. Draw with a 10-unit quiet zone each side. No network. */
double *biblio_codabar(const char *value, size_t *count);
/* Image bytes through the shared throttle, for apps without an image loader. */
biblio_result biblio_fetch_image(const char *url, unsigned char **bytes, size_t *len, biblio_error *err);

/* Client operations. */

/* language NULL leaves it unchanged; sample_account < 0 leaves it unchanged. No network. */
void biblio_configure(biblio_client *client, const char *language, int sample_account);
/* The client's latest request, for a status bar. No network. */
biblio_result biblio_status(biblio_client *client, biblio_fetch_status_t **out, biblio_error *err);
/* Signs in if needed (always, with force) and returns the patron. */
biblio_result biblio_login(biblio_client *client, bool force, biblio_patron_t **out, biblio_error *err);
/* The patron from the last sign-in, or *out = NULL. No network. */
biblio_result biblio_patron(biblio_client *client, biblio_patron_t **out, biblio_error *err);
biblio_result biblio_search(biblio_client *client, const biblio_search_query *query,
                            biblio_list_page_t **out, biblio_error *err);
biblio_result biblio_availability(biblio_client *client, const char *metadata_id,
                                  biblio_copy_list_t **out, biblio_error *err);
biblio_result biblio_details(biblio_client *client, const char *metadata_id,
                             biblio_detail_list_t **out, biblio_error *err);
biblio_result biblio_locations(biblio_client *client, biblio_location_list_t **out, biblio_error *err);
/* page is 1-based (0 means 1); sort may be NULL. */
biblio_result biblio_holds(biblio_client *client, int64_t page, const char *sort,
                           biblio_list_page_t **out, biblio_error *err);
biblio_result biblio_checkouts(biblio_client *client, int64_t page, const char *sort,
                               biblio_list_page_t **out, biblio_error *err);
biblio_result biblio_history(biblio_client *client, int64_t page, const char *sort,
                             biblio_list_page_t **out, biblio_error *err);
/* material_type NULL means "PHYSICAL"; pickup_branch NULL uses the preferred branch. */
biblio_result biblio_place_hold(biblio_client *client, const char *metadata_id, const char *material_type,
                                const char *pickup_branch, biblio_error *err);
/* *refused lists the holds the library declined to cancel (often none). */
biblio_result biblio_cancel_holds(biblio_client *client, const biblio_hold_ref *holds, size_t count,
                                  biblio_refusal_list_t **refused, biblio_error *err);
biblio_result biblio_account_settings(biblio_client *client, biblio_account_settings_t **out, biblio_error *err);
biblio_result biblio_set_pickup(biblio_client *client, const char *branch_id, biblio_error *err);
biblio_result biblio_set_language(biblio_client *client, const char *code, biblio_error *err);
biblio_result biblio_set_borrowing_history(biblio_client *client, bool enabled, biblio_error *err);
biblio_result biblio_change_email(biblio_client *client, const char *email, biblio_error *err);
/* The app must then save the new password. */
biblio_result biblio_change_password(biblio_client *client, const char *current, const char *new_password,
                                     biblio_error *err);

#ifdef __cplusplus
}
#endif

#endif /* BIBLIO_H */
