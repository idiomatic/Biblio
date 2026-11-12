/*
 * libbiblio: the BiblioCommons patron client shared by the Biblio apps.
 *
 * Every operation is a C function taking C arguments and returning C structs, such as
 * biblio_search(client, &query, &page, &err). Calls block (they may make several network
 * requests, paced app-wide to stay gentle with library sites), so make them off the UI
 * thread. Clients are safe to use from several threads at once. The full guide is
 * core/README.md.
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

/* Throttling and failures the servers have shown (HTTP 429 or any 5xx) since launch, as JSON for
 * diagnostics: {"total":N,"recent":[{"at":unix_s,"status":429,"method":"GET","host":…,"path":…,"retryAfter":s|-1,"inFlight":n}]},
 * oldest first, the latest 16. Ids in paths are masked and nothing names an account.
 * Free with biblio_free. */
char *biblio_incidents(void);

typedef struct biblio_client biblio_client;

/* Returns the saved password for (subdomain, username), allocated with biblio_alloc and
 * NUL-terminated, or NULL if none is saved. The core wipes and frees it, and wipes its own
 * copies once it has signed in. */
typedef char *(*biblio_password_fn)(void *ctx, const char *subdomain, const char *username);

/* An empty username makes a guest client, which can only use the catalog. password may be
 * NULL for a client that never signs in. */
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

/* Call at startup, before creating clients; clients keep the transport they were made with.
 * NULL restores the built-in transport. */
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
    BIBLIO_UNEXPECTED,         /* the library refused (e.g. a hold) or a page could not be read */
    BIBLIO_NOT_A_LIBRARY,      /* no BiblioCommons catalog at that subdomain */
    BIBLIO_BAD_REQUEST,        /* a missing argument or client: a bug in the caller */
    BIBLIO_OUT_OF_MEMORY,
    BIBLIO_HOLD_LIMIT,         /* the library refused a hold: the account has as many as it allows */
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
    const char *library_format; /* the library's own code; format may refine it (4K filed as Blu-ray) */
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
    int64_t edition_index; /* the Edition field's index in items, or -1 */
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
    const char *first_name; /* the library's contact first name; NULL if none */
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
/* The format codes with built-in names, for format pickers. Static; don't free. No network. */
const char *const *biblio_format_codes(size_t *count);
typedef enum {
    BIBLIO_CODABAR = 0, /* most North American library cards */
    BIBLIO_CODE128,     /* for scanners that skip Codabar */
} biblio_symbology;
/* Bar and space widths in narrow units, bar first; NULL if the value can't be encoded.
 * Draw with a 10-unit quiet zone each side. No network. */
double *biblio_barcode(const char *value, biblio_symbology symbology, size_t *count);
/* A scanned card number without Codabar A-D start and stop characters; NULL if empty or not printable ASCII. */
char *biblio_card_normalize(const char *scanned);
/* Where a hold's status (biblio_hold_t.status) falls, in the status sort's order; the value
 * biblio_list_item.status_rank takes. No network. */
typedef enum {
    BIBLIO_HOLD_READY = 0,  /* ready for pickup */
    BIBLIO_HOLD_IN_TRANSIT,
    BIBLIO_HOLD_WAITING,    /* not yet available, or a status the core doesn't know */
    BIBLIO_HOLD_PAUSED,
} biblio_hold_rank;
biblio_hold_rank biblio_hold_status_rank(const char *status);
/* "Ready for pickup", "In transit", "On hold", or "Paused". Static; don't free. No network. */
const char *biblio_hold_status_name(const char *status);
/* The year a publication date names ("c2019." gives "2019"), else the date as given; NULL if
 * date is NULL. Free with biblio_free. No network. */
char *biblio_year(const char *date);
/* Image bytes through the shared throttle, for apps without an image loader. */
biblio_result biblio_fetch_image(const char *url, unsigned char **bytes, size_t *len, biblio_error *err);

typedef enum {
    BIBLIO_ICON_NONE = 0,
    BIBLIO_ICON_SQUARE, /* fills a square tile */
    BIBLIO_ICON_LOGO,   /* a wide logo with white margins: trim with biblio_logo_bounds, draw fitted on white */
} biblio_icon_kind;
/* A library's icon: its website's largest square icon (at least 64 px), else the directory
 * logo, else a small favicon. website NULL reads it from subdomain's catalog; logo may be NULL.
 * The image bytes (PNG, ICO, GIF, BMP or JPEG) go in *bytes, freed with biblio_free; NONE
 * leaves them NULL. Apps cache the result. */
biblio_icon_kind biblio_library_icon(const char *website, const char *subdomain, const char *logo,
                                     unsigned char **bytes, size_t *len);
/* The part of a decoded logo that isn't white margin, padded, as x, y, width, height. Pixels
 * are rows stride bytes apart of channels bytes: 3 colors in any order, then alpha if 4.
 * false if the logo is blank. No network. */
bool biblio_logo_bounds(const unsigned char *pixels, size_t width, size_t height, size_t stride,
                        size_t channels, size_t bounds[4]);

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
/* material_type NULL means "PHYSICAL"; pickup_branch NULL uses the preferred branch. A refusal
 * because the account has as many holds as the library allows is BIBLIO_HOLD_LIMIT. */
biblio_result biblio_place_hold(biblio_client *client, const char *metadata_id, const char *material_type,
                                const char *pickup_branch, biblio_error *err);
/* *refused lists the holds the library declined to cancel (often none). */
/* holds may be NULL when count is 0. */
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

/* ---------------------------------------------------------------------------------------
 * Item lists
 *
 * A paged list's state: which pages to fetch, and the rows to show after sorting and
 * filtering. No network: the app fetches each page the list asks for (from biblio_list_request,
 * biblio_list_item_appeared, biblio_list_take_visible_requests or
 * biblio_list_next_background_page) and hands the result back with biblio_list_apply_page
 * (or biblio_list_apply), or biblio_list_fail. Use a list from one thread. Rows, ids and
 * format counts stay valid until the next call that changes the list. now_ms is any
 * monotonic clock in milliseconds. Lists abort if memory runs out.
 * ------------------------------------------------------------------------------------- */

typedef struct biblio_list biblio_list;

typedef enum {
    BIBLIO_LIST_SEARCH = 0,
    BIBLIO_LIST_HOLDS,
    BIBLIO_LIST_CHECKOUTS,
    BIBLIO_LIST_HISTORY,
} biblio_list_kind;

/* SERVER keeps the server's order; the others sort fetched items and need every page. */
typedef enum {
    BIBLIO_LIST_SORT_SERVER = 0,
    BIBLIO_LIST_SORT_PEOPLE_WAITING,
    BIBLIO_LIST_SORT_TITLE,
    BIBLIO_LIST_SORT_DUE_DATE, /* soonest first, no date last; checkouts */
    BIBLIO_LIST_SORT_STATUS,   /* ready, in transit, not yet available, paused; holds */
    BIBLIO_LIST_SORT_SERVER_TITLE, /* a server title sort, merged by title across logins */
    BIBLIO_LIST_SORT_AUTHOR,   /* a server author sort, merged by author across logins */
} biblio_list_sort;

typedef enum {
    BIBLIO_HOLD_FILTER_NONE = 0,
    BIBLIO_HOLD_FILTER_READY,
    BIBLIO_HOLD_FILTER_NOT_READY,
    BIBLIO_HOLD_FILTER_ON_ORDER,
} biblio_hold_filter;

/* What the list needs to know about an entry, for biblio_list_apply. */
typedef struct {
    const char *id;
    const char *title;
    const char *format;
    int64_t held_copies;
    int64_t server_index;
    bool is_hold;
    bool ready;    /* a hold ready for pickup */
    bool on_order; /* waiting on copies the library hasn't received */
    int64_t due_day; /* a checkout's due date as days since 1970-01-01; 0 for none */
    uint8_t status_rank; /* a hold's place in the status sort: 0 ready, 1 in transit, 2 not yet available, 3 paused */
    const char *author; /* the first author; "" for none */
} biblio_list_item;

/* A fetched item at a server position, or a placeholder (id NULL) for one not yet fetched. */
typedef struct {
    int64_t position;
    const char *id;
} biblio_list_row;

typedef struct {
    const char *format;
    int64_t count;
} biblio_format_count;

typedef struct {
    int64_t total;
    int64_t pages;
    bool loaded;
    bool has_more;
    bool loading;
    bool refreshing; /* stale rows shown until page 1 replaces them */
    bool background; /* fetching the remaining pages for a client sort or local filter */
    uint64_t generation;
} biblio_list_state_t;

biblio_list *biblio_list_new(biblio_list_kind kind);
void biblio_list_free(biblio_list *list);
biblio_list_state_t biblio_list_state(const biblio_list *list);

/* Starts again from page 1, which it requests; returns the generation to apply results with.
 * keep_content leaves the rows, stale, until page 1 replaces them all at once. */
uint64_t biblio_list_reload(biblio_list *list, bool keep_content);
/* Marks the rows stale before such a reload (e.g. while signing in afresh). */
void biblio_list_begin_refresh(biblio_list *list);
/* Empties the list without requesting anything (an empty search). */
void biblio_list_clear(biblio_list *list);
/* True if the app should fetch this page now (it is then in flight). */
bool biblio_list_request(biblio_list *list, int64_t page);
/* False if the list was reloaded since the page was requested, or it wasn't requested. items
 * may be NULL when count is 0. */
bool biblio_list_apply_page(biblio_list *list, uint64_t generation, int64_t page,
                            const biblio_list_page_t *result, int64_t now_ms);
bool biblio_list_apply(biblio_list *list, uint64_t generation, int64_t page, const biblio_list_item *items,
                       size_t count, int64_t total, int64_t page_size, int64_t now_ms);
bool biblio_list_fail(biblio_list *list, uint64_t generation, int64_t page);
bool biblio_list_is_stale(const biblio_list *list, int64_t now_ms);

/* Scrolling. An item in view returns a page to prefetch, or 0. Visible placeholders' pages are
 * requested once they have stayed on screen briefly (about 300 ms). */
int64_t biblio_list_item_appeared(biblio_list *list, int64_t position);
void biblio_list_placeholder_appeared(biblio_list *list, int64_t position);
void biblio_list_placeholder_disappeared(biblio_list *list, int64_t position);
size_t biblio_list_take_visible_requests(biblio_list *list, int64_t *pages, size_t capacity);

/* Background fetching, one page at a time, after page 1 when biblio_list_wants_all_pages and
 * after a sort or filter change when biblio_list_needs_all_pages. next returns 0 when done. */
bool biblio_list_needs_all_pages(const biblio_list *list);
bool biblio_list_wants_all_pages(const biblio_list *list);
bool biblio_list_begin_background(biblio_list *list);
int64_t biblio_list_next_background_page(biblio_list *list);
void biblio_list_end_background(biblio_list *list);

void biblio_list_set_sort(biblio_list *list, biblio_list_sort sort);
/* The format filter, applied locally on account lists (and on searches for a refined format,
 * which the server can't filter); NULL for all. */
void biblio_list_set_format(biblio_list *list, const char *format);
void biblio_list_set_hold_filter(biblio_list *list, biblio_hold_filter filter);
/* Returns how many items were removed; ids may be NULL when count is 0. Later items move up, as on
 * the server, so a fetched page that now ends in unfetched items shows placeholders and can be
 * requested again. */
size_t biblio_list_remove(biblio_list *list, const char *const *ids, size_t count);
int64_t biblio_list_hold_count(const biblio_list *list, biblio_hold_filter filter);

const biblio_list_row *biblio_list_rows(const biblio_list *list, size_t *count);
/* Item ids in server order. */
const char *const *biblio_list_ids(const biblio_list *list, size_t *count);
/* The items' formats, most common first. */
const biblio_format_count *biblio_list_formats(const biblio_list *list, size_t *count);

/* ---------------------------------------------------------------------------------------
 * Merged lists
 *
 * Interlaces the lists of several logins of one library (the cards of a combined window).
 * Each list stays the app's: it pages, goes stale (15 minutes), and refetches on its own, and
 * a row's login says which list's page to fetch for its placeholder. The merge only orders
 * what the lists hold. Free it before the lists.
 * ------------------------------------------------------------------------------------- */

typedef struct biblio_merge biblio_merge;

/* A list row, tagged with the index of its login's list. Ids are unique only within a login. */
typedef struct {
    uint32_t login;
    int64_t position;
    const char *id;
} biblio_merged_row;

/* Borrows the lists, at most 64, which must outlive the merge. */
biblio_merge *biblio_merge_new(biblio_list *const *lists, size_t count);
void biblio_merge_free(biblio_merge *merge);
/* SERVER interleaves by server position, the login breaking ties; the others sort across
 * logins with the login as the secondary key. DUE_DATE merges checkouts by true due date (the
 * lists keep the server's due-date order). Fetched items come before placeholders. */
void biblio_merge_set_sort(biblio_merge *merge, biblio_list_sort sort);
/* Which logins show, one bit each (bit 0: the first list). All by default. */
void biblio_merge_set_cards(biblio_merge *merge, uint64_t mask);
/* Set on every list, because their counts and background fetching depend on them. */
void biblio_merge_set_format(biblio_merge *merge, const char *format);
void biblio_merge_set_hold_filter(biblio_merge *merge, biblio_hold_filter filter);
/* Totals over the shown logins. */
int64_t biblio_merge_total(const biblio_merge *merge);
int64_t biblio_merge_hold_count(const biblio_merge *merge, biblio_hold_filter filter);
/* Valid until the next call that changes a list or the merge. */
const biblio_merged_row *biblio_merge_rows(biblio_merge *merge, size_t *count);

/* ---------------------------------------------------------------------------------------
 * Borrowed before
 *
 * One login's borrowing history as an index of what the patron borrowed. No network: a sync
 * asks for history pages (biblio_history with sort NULL), the app fetches each and hands it
 * back, and the call returns the next page, 0 when done:
 *
 *     for (int64_t p = biblio_borrowed_index_begin_sync(ix); p > 0;)
 *         p = fetched ? biblio_borrowed_index_apply_page(ix, p, page)
 *                     : (biblio_borrowed_index_fail(ix), 0);
 *
 * The first sync fetches every page and resumes where it stopped; later ones fetch from page 1
 * until a known entry, and refetch everything (noted in biblio_incidents) if history doesn't
 * read as newest first or shrank. The app keeps the exported bytes (they are private: store
 * them protected), deletes them on sign-out, and clears the index when the library's
 * borrowing history is off. Use an index from one thread.
 * ------------------------------------------------------------------------------------- */

typedef struct biblio_borrowed_index biblio_borrowed_index;

typedef enum {
    BIBLIO_BORROWED_NONE = 0,
    BIBLIO_BORROWED_SAME,         /* this record, or this work in the same format */
    BIBLIO_BORROWED_OTHER_FORMAT, /* this work in another format */
} biblio_borrowed_match;

typedef struct {
    biblio_borrowed_match match;
    const char *format;        /* the borrowed format code */
    int64_t count;             /* times borrowed (in that format) */
    const char *last_checkout; /* YYYY-MM-DD of the latest; NULL if unknown */
    const char *last_returned;
} biblio_borrowed_t;

typedef struct {
    int64_t fetched; /* entries indexed */
    int64_t total;   /* the history's size, as last reported */
    bool complete;   /* every page fetched once; the "Not Borrowed" filter is offered */
    bool syncing;
} biblio_borrowed_progress_t;

biblio_borrowed_index *biblio_borrowed_index_new(void);
void biblio_borrowed_index_free(biblio_borrowed_index *index);
/* false (leaving the index empty) if unreadable or from another version: sync afresh. */
bool biblio_borrowed_index_import(biblio_borrowed_index *index, const unsigned char *bytes, size_t len);
/* Free with biblio_free; NULL if out of memory. */
unsigned char *biblio_borrowed_index_export(const biblio_borrowed_index *index, size_t *len);
void biblio_borrowed_index_clear(biblio_borrowed_index *index);
/* The first page to fetch, or 0 if a sync is running. */
int64_t biblio_borrowed_index_begin_sync(biblio_borrowed_index *index);
/* Forgets the index and fetches it all again (Refresh Borrowing History): page 1, or 0 when a
 * running sync carries on from page 1 instead. */
int64_t biblio_borrowed_index_rebuild(biblio_borrowed_index *index);
/* The next page to fetch, or 0 when the sync is done. */
int64_t biblio_borrowed_index_apply_page(biblio_borrowed_index *index, int64_t page, const biblio_list_page_t *result);
void biblio_borrowed_index_fail(biblio_borrowed_index *index);
biblio_borrowed_progress_t biblio_borrowed_index_progress(const biblio_borrowed_index *index);
/* Changes whenever matches may have. */
uint64_t biblio_borrowed_index_generation(const biblio_borrowed_index *index);
/* Pass the bib's id, format, title, and first author (NULL for none). Strings stay valid until
 * the index is cleared, rebuilt, or imported. */
biblio_borrowed_t biblio_borrowed(const biblio_borrowed_index *index, const char *metadata_id,
                                  const char *format, const char *title, const char *author);
/* "Not Borrowed": shows only works none of the indexes borrowed in the item's format; count 0
 * turns it off. The indexes must outlive the setting; set it again after they change. Searches
 * then need every page (biblio_list_needs_all_pages). */
void biblio_list_set_not_borrowed(biblio_list *list, const biblio_borrowed_index *const *indexes, size_t count);
void biblio_merge_set_not_borrowed(biblio_merge *merge, const biblio_borrowed_index *const *indexes, size_t count);
/* A refined format (4K Ultra HD Blu-ray where the library files it as Blu-ray). Searches ask the
 * server for its base and filter locally, so pass it to biblio_list_set_format on search lists
 * too; the FORMAT facet lists it after its base with count -1 (unknown). No network. */
bool biblio_format_is_refined(const char *code);

#ifdef __cplusplus
}
#endif

#endif /* BIBLIO_H */
