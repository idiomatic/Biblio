// Builds the mock catalogs (video/ and books/) from a live library's public catalog:
// titles, covers (as URLs), formats, and editions. Copies, holds, and checkouts are
// invented here, deterministically. Run: node generate.mjs [subdomain]
// --append adds only the books theme's other formats (`more`) to the existing catalog, leaving
// everything already there, and the accounts, as they are.
// Be gentle: one request at a time, with a pause.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = process.argv.slice(2).find((a) => !a.startsWith("--")) ?? "wccls";
const appending = process.argv.includes("--append");
const gateway = `https://gateway.bibliocommons.com/v2/libraries/${source}`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function search(query, format) {
  for (let attempt = 1; ; attempt++) {
    await sleep(500 * attempt * attempt);
    let j = null;
    try {
      const res = await fetch(`${gateway}/bibs/search`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ query, searchType: "smart", page: 1, locale: "en-US", ...(format && { f_FORMAT: format }) }),
        signal: AbortSignal.timeout(20000),
      });
      j = res.ok ? await res.json() : null;
    } catch {}
    if (j?.catalogSearch) return j.catalogSearch.results.map((r) => j.entities.bibs[r.representative]).filter(Boolean);
    if (attempt >= 5) throw new Error(`search failed: ${query}`);
  }
}

// A small deterministic generator, so reruns produce the same library.
let seed = 20260901;
const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
const pick = (list) => list[Math.floor(rand() * list.length)];

const branches = ["Preservation Central", "Port FreeCommerce", "Milu Station", "Ganaka Pit", "Mihira Branch", "Haven Landing"];
// Downloadable formats, whose copies are licenses, online.
const digital = new Set(["EBOOK", "AB"]);
const slim = (b, kind) => {
  const i = b.briefInfo;
  return {
    metadataId: i.metadataId, title: i.title, subtitle: i.subtitle || "", format: i.format,
    callNumber: i.callNumber, description: i.description, authors: i.authors ?? [],
    publicationDate: i.publicationDate, jacket: i.jacket, edition: i.edition, kind,
    ...(digital.has(i.format) && { materialType: "DIGITAL" }),
  };
};

const video = [
  "Dune", "Dune: Part Two", "Blade Runner 2049", "Arrival", "Interstellar", "The Martian",
  "Inception", "Gravity", "Ex Machina", "Mad Max: Fury Road", "Top Gun: Maverick", "Oppenheimer",
  "Barbie", "The Batman", "Spider-Man: Across the Spider-Verse", "Everything Everywhere All at Once",
  "Parasite", "Knives Out", "Glass Onion", "John Wick", "Jurassic Park", "Back to the Future",
  "Alien", "Aliens", "The Matrix", "Ghostbusters", "Paddington 2", "Coco", "Wall-E", "Moana",
];
const books = [
  "All Systems Red", "Artificial Condition", "Rogue Protocol", "Exit Strategy Martha Wells", "Network Effect",
  "Fugitive Telemetry", "System Collapse", "The Cloud Roads", "Witch King", "Death of the Necromancer",
  "A Memory Called Empire", "Ancillary Justice", "Children of Time", "Project Hail Mary", "Station Eleven",
  "The Long Way to a Small, Angry Planet", "Binti", "The Martian Andy Weir", "Leviathan Wakes", "Red Rising",
  "Neuromancer", "Hyperion Dan Simmons", "Klara and the Sun", "The Dispossessed", "Ender's Game",
];

// The books theme's other formats, as in a library's New Titles (all new arrivals): each search
// and its format.
const more = [
  ["All Systems Red", "EBOOK"], ["Project Hail Mary", "EBOOK"],
  ["Network Effect", "AB"], ["Artificial Condition", "AB"],
  ["Saga Brian K. Vaughan", "GRAPHIC_NOVEL"], ["Paper Girls", "GRAPHIC_NOVEL"],
  ["If You Come to Earth", "PICTURE_BOOK"], ["Mae Among the Stars", "PICTURE_BOOK"],
  ["Interstellar Hans Zimmer", "MUSIC_CD"], ["Dune Hans Zimmer", "MUSIC_CD"],
];

// Book searches add the author; the title a result must start with is given here.
const titleOf = {
  "Saga Brian K. Vaughan": "Saga", "Interstellar Hans Zimmer": "Interstellar", "Dune Hans Zimmer": "Dune",
  "Exit Strategy Martha Wells": "Exit Strategy",
  "The Martian Andy Weir": "The Martian", "Foundation Asimov": "Foundation",
  "Hyperion Dan Simmons": "Hyperion", "Kindred Octavia Butler": "Kindred", "Annihilation VanderMeer": "Annihilation",
  "Recursion Blake Crouch": "Recursion", "Dark Matter Blake Crouch": "Dark Matter",
};

// The serial's soundtrack, a fictional music CD (shown in both themes).
const soundtrack = (id) => ({
  metadataId: id, title: "The Rise and Fall of Sanctuary Moon", subtitle: "Original Series Soundtrack", format: "MUSIC_CD",
  callNumber: "CD TV SANC", description: "Music from all seven seasons, including the theme that plays over a very long fall.",
  authors: ["Various artists"], publicationDate: "2024", edition: "Original soundtrack", kind: "extra", collection: "Adult Music CD",
});

// A fictional serial from the Murderbot books, for the video catalog.
const sanctuary = (id, format, call, edition, collection) => ({
  metadataId: id, title: "The Rise and Fall of Sanctuary Moon", subtitle: "The Complete Series", format,
  callNumber: call, description: "Seven seasons of premium quality content: the crew of the Sanctuary Moon, their rivals, and the long fall of the colony, as watched by a very particular audience.",
  authors: [], publicationDate: "2024", edition, kind: "video", collection,
});

// Formats beyond the main one, for Murderbot titles only (appended, so earlier data stays put).
const extraFormats = ["BOOK_CD", "LPRINT"];

function wanted(theme, bib, formats) {
  const f = bib.briefInfo.format;
  if (formats) return formats.includes(f);
  if (theme === "video") return f === "DVD" || f === "BLURAY";
  return f === "BK";
}

function key(theme, bib) {
  const i = bib.briefInfo;
  const is4k = /4k/i.test(`${i.callNumber} ${i.edition}`);
  if (theme === "books" && i.format !== "BK") return `${i.title.toLowerCase()}|${i.format}`;
  return theme === "video" ? `${i.title.toLowerCase()}|${(i.subtitle || "").toLowerCase()}|${is4k ? "4k" : i.format}` : `${i.title.toLowerCase()}`;
}

const normal = (text) => text.toLowerCase().replace(/[^a-z0-9]/g, "");

// Syndetics answers a missing cover with a small blank image (about 3 KB at this size).
const hasCover = async (bib) => {
  const url = bib.briefInfo.jacket?.medium ?? bib.briefInfo.jacket?.small;
  if (!url) return false;
  for (let attempt = 0; attempt < 3; attempt++) {
    await sleep(300 * (attempt + 1));
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(15000) });
      if (res.ok) return (await res.arrayBuffer()).byteLength > 3500;
    } catch {}
  }
  return false;
};

async function gather(theme, queries, formats) {
  const out = [];
  const seen = new Set();
  for (const q of queries) {
    const wantedTitle = normal((titleOf[q] ?? q).split(":")[0]);
    const wantedSub = normal((titleOf[q] ?? q).split(":")[1] ?? "");
    const results = await search(q, formats?.length === 1 ? formats[0] : undefined);
    let n = 0;
    for (const b of results) {
      const info = b.briefInfo;
      if (!wanted(theme, b, formats) || /[\[\]]|into the/i.test(info.title) || !normal(info.title).startsWith(wantedTitle)) continue;
      const sub = normal(info.subtitle || "");
      if (theme === "video" && sub && !(wantedSub && sub.startsWith(wantedSub))) continue;
      if (q.endsWith("Martha Wells") && !(info.authors ?? []).join(" ").includes("Wells")) continue;
      const k = key(theme, b);
      if (seen.has(k) || !(await hasCover(b))) continue;
      seen.add(k);
      out.push(slim(b, theme));
      if (++n >= (theme === "video" ? 3 : 1)) break;
    }
    console.error(theme, q, n);
  }
  return out;
}

// Each format's collection in the books theme.
const collections = {
  BK: "Adult Fiction", BOOK_CD: "Adult Audiobook CD", LPRINT: "Adult Large Print", MUSIC_CD: "Adult Music CD",
  GRAPHIC_NOVEL: "Adult Graphic Novel", PICTURE_BOOK: "Children's Picture Book", EBOOK: "eBook", AB: "Downloadable Audiobook",
};

// Invents copies by location, held counts, and which titles are new or on order, for the
// catalog's items from `from` on.
function stock(catalog, theme, from = 0) {
  catalog.forEach((b, index) => {
    if (index < from) return;
    const popular = rand() < 0.45;
    const copies = [];
    const total = 1 + Math.floor(rand() * (popular ? 6 : 3));
    for (let c = 0; c < total; c++) {
      const roll = rand();
      const branch = digital.has(b.format) ? "Online" : pick(branches);
      const collection = theme === "video"
        ? (b.format === "DVD" ? "Adult DVD" : b.format === "MUSIC_CD" ? "Adult Music CD"
          : /4k/i.test(`${b.callNumber} ${b.edition}`) ? "Adult 4K Blu-ray" : "Adult Blu-ray")
        : collections[b.format] ?? "Adult Fiction";
      const status = roll < 0.35 ? "AVAILABLE" : roll < 0.8 ? "CHECKED_OUT" : roll < 0.9 ? "IN_TRANSIT" : "HELD";
      copies.push({ branch, collection, call: b.callNumber, status, dueDays: status === "CHECKED_OUT" ? 2 + Math.floor(rand() * 19) : undefined });
    }
    b.copies = copies;
    const out = copies.filter((c) => c.status !== "AVAILABLE").length;
    b.held = popular ? Math.max(0, out - 1) + Math.floor(rand() * 14) : 0;
    b.onOrder = 0;
    b.order = index;
  });
  // A few recent titles are on order only: no copies yet.
  const soon = theme === "video"
    ? ["The Rise and Fall of Sanctuary Moon", "Dune", "Oppenheimer", "Top Gun", "Barbie", "The Batman"]
    : ["System Collapse", "Witch King", "Binti", "Station Eleven", "Klara", "Neuromancer"];
  for (const name of from ? [] : soon) {
    const matches = catalog.filter((b) => b.title.toLowerCase().startsWith(name.toLowerCase()));
    const b = matches.find((x) => /4k/i.test(`${x.callNumber} ${x.edition}`)) ?? matches[matches.length - 1];
    if (!b) continue;
    b.copies = [];
    b.onOrder = 2 + Math.floor(rand() * 5);
    b.held = Math.floor(rand() * 30);
  }
  // A few more are new arrivals on the shelf.
  catalog.forEach((b, i) => { if (i >= from) b.new = i % 7 === 3 || b.onOrder > 0 || b.kind === "more"; });
}

function find(catalog, title, how = () => true) {
  const b = catalog.find((x) => x.title.toLowerCase().startsWith(title.toLowerCase()) && how(x));
  if (!b) throw new Error(`missing ${title}`);
  return b;
}

function account(catalog, theme) {
  const t = (title, how) => find(catalog, title, how).metadataId;
  const a = (name) => catalog.find((b) => b.title.toLowerCase().startsWith(name.toLowerCase()) && b.copies.length)?.metadataId;
  const holdTitles = theme === "video"
    ? ["The Rise and Fall of Sanctuary Moon", "Dune", "Arrival", "Oppenheimer", "Barbie", "Top Gun", "Coco", "Knives Out"]
    : ["Network Effect", "Fugitive Telemetry", "Rogue Protocol", "Exit Strategy", "A Memory Called Empire", "Project Hail Mary", "Witch King", "Binti"];
  const ids = holdTitles.map(a).filter(Boolean);
  const states = [
    { status: "READY_FOR_PICKUP", pickupByDays: 4, position: 0 },
    { status: "READY_FOR_PICKUP", pickupByDays: 6, position: 0 },
    { status: "IN_TRANSIT", position: 1 },
    { status: "NOT_YET_AVAILABLE", position: 3 },
    { status: "NOT_YET_AVAILABLE", position: 7 },
    { status: "NOT_YET_AVAILABLE", position: 12 },
    { status: "NOT_YET_AVAILABLE", position: 2 },
    { status: "NOT_YET_AVAILABLE", position: 5 },
  ];
  const holds = ids.map((bib, i) => ({ bib, pickup: pick(branches), ...states[i] }));
  // Also one on-order title held.
  const onOrder = catalog.find((b) => b.onOrder > 0);
  holds.push({ bib: onOrder.metadataId, pickup: "Preservation Central", status: "NOT_YET_AVAILABLE", position: 9 });

  const used = new Set(ids);
  // One record per title, none held already, so the account reads naturally.
  const heldTitles = new Set(holds.map((h) => catalog.find((b) => b.metadataId === h.bib).title));
  const spare = [];
  for (const b of catalog) {
    if (!b.copies.length || used.has(b.metadataId) || heldTitles.has(b.title)) continue;
    heldTitles.add(b.title);
    spare.push(b);
  }
  const checkouts = spare.slice(0, 6).map((b, i) => ({
    bib: b.metadataId, dueDays: [-2, 2, 5, 9, 14, 19][i], outDays: [23, 19, 16, 12, 7, 2][i], renewed: i % 3,
  }));
  const history = spare.slice(6, 6 + 16).map((b, i) => ({ bib: b.metadataId, outDays: 40 + i * 9, returnedDays: 28 + i * 9 }));
  return { holds, checkouts, history };
}

function write(theme, catalog, acct) {
  const dir = join(here, theme);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "catalog.json"), JSON.stringify(catalog, null, 1) + "\n");
  writeFileSync(join(dir, "account.json"), JSON.stringify(acct, null, 1) + "\n");
}

async function gatherMore() {
  const out = [];
  for (const [q, format] of more) out.push(...(await gather("books", [q], [format])));
  // New arrivals, as in the library's New Titles.
  return out.map((b) => ({ ...b, kind: "more" }));
}

if (appending) {
  const path = join(here, "books", "catalog.json");
  const catalog = JSON.parse(readFileSync(path, "utf8"));
  const have = new Set(catalog.map((b) => b.metadataId));
  const from = catalog.length;
  catalog.push(...(await gatherMore()).filter((b) => !have.has(b.metadataId)));
  stock(catalog, "books", from);
  writeFileSync(path, JSON.stringify(catalog, null, 1) + "\n");
  process.exit(0);
}

for (const [theme, queries] of [["video", video], ["books", books]]) {
  const catalog = await gather(theme, queries);
  if (theme === "video") {
    catalog.unshift(
      sanctuary("S900C0003", "BLURAY", "4K BLU SANC", "4K Ultra HD Blu-ray", "Adult 4K Blu-ray"),
      sanctuary("S900C0002", "BLURAY", "BLU-RAY SANC", "Blu-ray", "Adult Blu-ray"),
      sanctuary("S900C0001", "DVD", "DVD SANC", "Widescreen", "Adult DVD"),
    );
  }
  // In-universe media in other formats go last, after the account is chosen from the main catalog.
  const main = catalog.length;
  if (theme === "books") {
    const murderbot = books.slice(0, 7).filter((q) => !q.includes("Exit Strategy"));
    catalog.push(...(await gather(theme, murderbot, extraFormats)));
  }
  catalog.push(soundtrack(theme === "video" ? "S900C0010" : "S900C0011"));
  if (theme === "books") catalog.push(...(await gatherMore()));
  stock(catalog, theme);
  const acct = account(catalog.slice(0, main), theme);
  // Borrowed before: a title held again, and (books) a held title's audiobook.
  const last = Math.max(...acct.history.map((h) => h.outDays));
  const again = theme === "video" ? [find(catalog, "Arrival", (b) => b.format === "DVD")]
    : [find(catalog, "Network Effect", () => true), find(catalog, "Rogue Protocol", (b) => b.format === "BOOK_CD")];
  again.forEach((b, i) => acct.history.push({ bib: b.metadataId, outDays: last + 40 + i * 30, returnedDays: last + 28 + i * 30 }));
  write(theme, catalog, acct);
}
