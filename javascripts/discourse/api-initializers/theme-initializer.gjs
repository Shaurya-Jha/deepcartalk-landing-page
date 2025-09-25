import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";

const GRID_MAX_ITEMS = 6;          // show up to 6 items
let GRID_COLUMNS = 3;             // set 2 or 3 (3 -> 3x2, 2 -> 2x3)

// --- URL normalization helper (upgrade http -> https / make relative absolute) ---
function normalizeUrl(url) {
  if (!url || typeof url !== "string") return url;
  const s = url.trim();
  // keep data: and blob: URIs as-is
  if (/^(data:|blob:)/i.test(s)) return s;
  // already protocol-relative or https
  if (/^\/\/|^https:\/\//i.test(s)) return s;
  if (/^http:\/\//i.test(s)) return s.replace(/^http:/i, "https:");
  // relative path -> make absolute against current origin
  if (s.indexOf("/") === 0) return `${window.location.origin}${s}`;
  return s;
}

const PLACEHOLDER = "/images/placeholder.png"; // update path
const NORMALIZED_PLACEHOLDER = normalizeUrl(PLACEHOLDER);

// cache for fetched tabs: { tabKey: topicsArray }
const topicsCache = {};

// helpers for media detection
function youtubeThumbnail(url) {
  const m = url && url.match(/(?:youtube\.com\/watch\?v=|youtu\.be\/)([A-Za-z0-9_-]{6,})/);
  return m ? `https://img.youtube.com/vi/${m[1]}/hqdefault.jpg` : null;
}
function isVimeo(url) { return /vimeo\.com\/\d+/.test(url); }
function isVideoFile(url) { return /\.(mp4|webm|ogg|mov)(\?.*)?$/i.test(url); }

// // simple emoji helpers + hot threads (minimal)
// /** escape HTML for safety */
// function escapeHtml(s) {
//   return (s || "")
//     .replace(/&/g, "&amp;")
//     .replace(/</g, "&lt;")
//     .replace(/>/g, "&gt;")
//     .replace(/"/g, "&quot;")
// }

function decodeHtmlEntities(str) {
  // turns "&rsquo;" or "&#8217;" into the real character
  const txt = document.createElement("textarea");
  txt.innerHTML = String(str || "");
  return txt.value;
}

function hasHtmlEntity(str) {
  return /&[A-Za-z0-9#]{2,10};/.test(String(str || ""));
}

// escape but DON'T replace apostrophe (avoid converting ' -> &#39; or unicode ’ -> &rsquo;)
function escapeHtmlKeepApostrophe(s) {
  return (s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

let _primaryEmojiMap = null; // canonical name -> { url }
let _aliasToCanonical = null; // alias -> canonical name

function loadCustomEmojisOnce() {
  if (_primaryEmojiMap && _aliasToCanonical) {
    return Promise.resolve({ primaryMap: _primaryEmojiMap, aliasMap: _aliasToCanonical });
  }

  return ajax("/emojis.json")
    .then(resp => {
      const primaryMap = {};
      const aliasMap = {};

      // Helper to register a canonical entry and its aliases
      function registerCanonical(name, url, aliases) {
        if (!name || !url) return;
        const key = String(name).toLowerCase();
        primaryMap[key] = { url };
        if (Array.isArray(aliases)) {
          aliases.forEach(a => {
            if (!a) return;
            const ak = String(a).toLowerCase();
            aliasMap[ak] = key;
          });
        }
      }

      // Case: root is an array of objects [{name,url,search_aliases}, ...]
      if (Array.isArray(resp)) {
        resp.forEach(e => {
          const name = e && (e.name || e.shortcode || "");
          const url = e && (e.url || e.file || e.path || e.image);
          const aliases = Array.isArray(e && e.search_aliases) ? e.search_aliases : [];
          registerCanonical(name, url, aliases);
        });

      // Case: root is an object (groups -> arrays OR name->string OR name->object)
      } else if (resp && typeof resp === "object") {
        Object.keys(resp).forEach(k => {
          const v = resp[k];

          // group -> [ {name,url,search_aliases}, ... ]
          if (Array.isArray(v)) {
            v.forEach(e => {
              const name = e && (e.name || e.shortcode || "");
              const url = e && (e.url || e.file || e.path || e.image);
              const aliases = Array.isArray(e && e.search_aliases) ? e.search_aliases : [];
              registerCanonical(name, url, aliases);
            });
            return;
          }

          // name -> "/path/to/img"
          if (typeof v === "string") {
            registerCanonical(k, v, []);
            return;
          }

          // name -> object with url and maybe search_aliases
          if (v && typeof v === "object") {
            const url = v.url || v.file || v.path || v.image;
            const aliases = Array.isArray(v.search_aliases) ? v.search_aliases : [];
            registerCanonical(k, url, aliases);
            return;
          }
        });
      }

      // Save caches
      _primaryEmojiMap = primaryMap;
      _aliasToCanonical = aliasMap;

      console.debug("[emoji] primary keys sample:", Object.keys(primaryMap).slice(0,50));
      console.debug("[emoji] alias keys sample:", Object.keys(aliasMap).slice(0,50));

      return { primaryMap, aliasMap };
    })
    .catch(err => {
      console.warn("[emoji] failed to load /emojis.json", err);
      _primaryEmojiMap = {};
      _aliasToCanonical = {};
      return { primaryMap: _primaryEmojiMap, aliasMap: _aliasToCanonical };
    });
}

/** replace :shortcode: with <img ...> using the maps loaded above (input should be escaped HTML) */
function replaceShortcodesWithImages(escapedText, maps) {
  if (!escapedText || escapedText.indexOf(":") === -1) return escapedText;
  const primaryMap = maps.primaryMap || {};
  const aliasMap = maps.aliasMap || {};

  return escapedText.replace(/:([a-z0-9_+\-]+):/gi, (full, rawName) => {
    const name = String(rawName).toLowerCase();

    // 1) aliasMap -> canonical name
    const canonicalFromAlias = aliasMap[name];
    if (canonicalFromAlias && primaryMap[canonicalFromAlias] && primaryMap[canonicalFromAlias].url) {
      return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[canonicalFromAlias].url}" style="height:1em;vertical-align:-0.15em">`;
    }

    // 2) direct primary lookup
    if (primaryMap[name] && primaryMap[name].url) {
      return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[name].url}" style="height:1em;vertical-align:-0.15em">`;
    }

    // 3) underscore/dash variants
    const alt1 = name.replace(/_/g, "-");
    const alt2 = name.replace(/-/g, "_");
    if (primaryMap[alt1] && primaryMap[alt1].url) {
      return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[alt1].url}" style="height:1em;vertical-align:-0.15em">`;
    }
    if (primaryMap[alt2] && primaryMap[alt2].url) {
      return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[alt2].url}" style="height:1em;vertical-align:-0.15em">`;
    }

    // 4) last-resort: linear search in primaryMap for an entry whose aliases include this name
    for (const canonical in primaryMap) {
      if (!primaryMap.hasOwnProperty(canonical)) continue;
      if (aliasMap[name] === canonical && primaryMap[canonical].url) {
        return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[canonical].url}" style="height:1em;vertical-align:-0.15em">`;
      }
    }

    // nothing found — leave shortcode as-is
    return full;
  });
}

export default apiInitializer((api) => {
  let _carouselIntervalId = null;

  // --- HOT THREADS ---
  function loadHotThreads(limit = 10) {
  Promise.all([ loadCustomEmojisOnce(), ajax("/hot.json") ])
    .then(([customMap, resp]) => {
      const topics = (resp.topic_list?.topics || []).slice(0, limit);
      const ul = document.querySelector(".hot-threads .box-content ul");
      if (!ul) return;

      if (topics.length === 0) {
        ul.innerHTML = `<li style="color:#aaa;padding:10px;">No hot threads right now.</li>`;
        return;
      }

      ul.innerHTML = topics.map(t => {
        // Prefer unicode_title (actual emoji chars), then fancy_title, then title
        const unicode = t.unicode_title;
        let raw = unicode ?? t.fancy_title ?? t.title ?? "";

        // If server sent HTML entities like &rsquo; decode them into real characters
        if (hasHtmlEntity(raw)) {
          raw = decodeHtmlEntities(raw);
        }

        // Escape for safety but DO NOT convert apostrophes to entities
        // (keeps ' and curly ’ characters as actual characters)
        const escapedForHtml = escapeHtmlKeepApostrophe(String(raw));

        // Replace shortcodes like :smile: -> <img ...>
        // replaceShortcodesWithImages expects escaped text (so it doesn't allow unescaped HTML)
        const processed = replaceShortcodesWithImages(escapedForHtml, customMap);

        const url = t.slug ? `/t/${t.slug}/${t.id}` : (t.url || `/t/${t.id}`);
        // If URL may contain spaces or unicode, consider encodeURI(url) here

        return `
          <li>
            <a href="${url}">
              <span>${processed}</span>
              <span>►</span>
            </a>
          </li>
        `;
      }).join("");
    })
    .catch((err) => {
      console.error("[hot-threads] fetch failed", err);
    });
}

  // function loadHotThreads(limit = 10) {
  //   // load emojis and hot topics in parallel (we still load emojis for fallback)
  //   Promise.all([ loadCustomEmojisOnce(), ajax("/hot.json") ])
  //     .then(([customMap, resp]) => {
  //       const topics = (resp.topic_list?.topics || []).slice(0, limit);
  //       const ul = document.querySelector(".hot-threads .box-content ul");
  //       if (!ul) return;

  //       if (topics.length === 0) {
  //         ul.innerHTML = `<li style="color:#aaa;padding:10px;">No hot threads right now.</li>`;
  //         return;
  //       }

  //       ul.innerHTML = topics.map(t => {
  //         // prefer unicode_title (server-rendered emoji glyphs), then fancy_title, then title
  //         const unicode = t.unicode_title;
  //         const raw = unicode || t.fancy_title || t.title || "";

  //         // If we have a unicode_title, use it directly (escape for HTML but keep the emoji glyphs).
  //         // If not, fall back to escaping + replacing shortcodes via emoji map.
  //         let processed;
  //         if (unicode) {
  //           // escape (safe) — emoji characters are preserved by escapeHtml
  //           processed = escapeHtml(String(unicode));
  //         } else {
  //           const escaped = escapeHtml(String(raw));
  //           processed = replaceShortcodesWithImages(escaped, customMap);
  //         }

  //         const url = t.slug ? `/t/${t.slug}/${t.id}` : (t.url || (`/t/${t.id}`));
  //         return `
  //           <li>
  //             <a href="${url}">
  //               <span>${processed}</span>
  //               <span>►</span>
  //             </a>
  //           </li>
  //         `;
  //       }).join("");
  //     })
  //     .catch((err) => {
  //       console.error("[hot-threads] fetch failed", err);
  //     });
  // }

  function showHomepageSpinner() {
    // if spinner already present, don't add again
    if (document.getElementById("hc-spinner")) return;
    // ensure #homepage-main exists (create fallback if not)
    let main = document.getElementById("homepage-main");
    if (!main) {
      main = document.createElement("div");
      main.id = "homepage-main";
      document.body.insertBefore(main, document.body.firstChild);
    }

    // insert spinner as first child so it's visible even if later replaced quickly
    const spinnerHtml = `
      <div id="hc-spinner" role="status" aria-live="polite" aria-busy="true" style="display:flex;align-items:center;justify-content:center;padding:28px 16px;">
        <style id="hc-spinner-style">
          #hc-spinner { background: linear-gradient(0deg, rgba(0,0,0,0.55), rgba(0,0,0,0.25)); border-radius:8px; }
          #hc-spinner .hc-spinner { width:48px; height:48px; border-radius:50%; border:5px solid rgba(255,255,255,0.06); border-top-color: rgba(255,255,255,0.85); animation: hc-spin 0.9s linear infinite; margin-right:12px; }
          @keyframes hc-spin { to { transform: rotate(360deg); } }
          #hc-spinner .hc-spinner-msg { color:#e6eefc; font-size:0.95rem; font-weight:600; }
        </style>
        <div style="display:flex;align-items:center;">
          <div class="hc-spinner" aria-hidden="true"></div>
          <div class="hc-spinner-msg">Loading homepage…</div>
        </div>
      </div>
    `;
    // use insertAdjacentHTML to avoid wiping other event listeners (safer than innerHTML = ...)
    main.insertAdjacentHTML("afterbegin", spinnerHtml);
    console.debug("LANDING-COMP: spinner shown (#hc-spinner)");
  }

  function hideHomepageSpinner() {
    const s = document.getElementById("hc-spinner");
    if (s) s.remove();
    const style = document.getElementById("hc-spinner-style");
    if (style) style.remove();
    console.debug("LANDING-COMP: spinner hidden (#hc-spinner)");
  }


  // --- TOP 5 / CAROUSEL (unchanged above this point) ---
  function loadTop5() {
    // keep renderInOutlet as you had; if it causes trouble swap to safe DOM insertion
    try {
      api.renderInOutlet("above-main-container", <template><div id="homepage-main"></div></template>);
    } catch (e) {
      // Fallback if JSX/renderInOutlet isn't allowed in your environment
      if (!document.getElementById("homepage-main")) {
        const container = document.createElement("div");
        container.id = "homepage-main";
        const first = document.body.firstChild;
        document.body.insertBefore(container, first);
      }
    }

    // ajax("/top/monthly.json")
    ajax("/latest.json")
      .then((response) => {

        // remove spinner only when we are about to insert the full markup
        hideHomepageSpinner();
        
        const topics = (response.topic_list?.topics || []).slice(0, 5);
        const topicsWithImages = topics.filter(t => !!t.image_url);
        const main = document.getElementById("homepage-main");
        if (!main) return;

        const carouselItemsHtml = topicsWithImages.map(t => {
          const title = (t.title || "").replace(/"/g, "&quot;");
          const topicUrl = `/t/${t.slug || ""}/${t.id}`; // fallback: `/t/${t.id}`
          const imgSrc = normalizeUrl(t.image_url || t.image || NORMALIZED_PLACEHOLDER);
          // return `
          //   <div class="carousel-item" data-title="${title}" data-topic-id="${t.id}">
          //     <a href="${topicUrl}">
          //       <img src="${imgSrc}" alt="${title}" loading="lazy">
          //       <div style="position:absolute;left:8px;top:8px;">
          //         <div class="hc-spinner hc-inline-spinner" aria-hidden="true"></div>
          //       </div>
          //     </a>
          //   </div>
          // `;
          return `
            <div class="carousel-item" data-title="${title}" data-topic-id="${t.id}">
              <a href="${topicUrl}" style="position:relative;display:block;">
                <img src="${imgSrc}" alt="${title}" loading="lazy" />
                <div class="carousel-inline-spinner" aria-hidden="true" style="position:absolute;left:8px;top:8px;">
                  <div style="width:28px;height:28px;border-radius:50%;border:4px solid rgba(255,255,255,0.06);border-top-color:rgba(255,255,255,0.85);animation:hc-spin .9s linear infinite;"></div>
                </div>
              </a>
            </div>
          `;
        }).join("");

        main.innerHTML = `
          <style>
            /* layout root */
            /* REPLACE your .main-container block with this (no hardcoded max-width) */
            .main-container {
              width: 100%;
              margin: 20px auto;
              padding: 0 16px;
              display: grid;
              /* left is flexible (can shrink), right is bounded by percentage (not hard px) */
              grid-template-columns: minmax(0, 1fr) minmax(220px, 34%);
              gap: 20px;
              box-sizing: border-box;
              overflow: visible;
            }

            /* ensure grid children can shrink below their content if needed */
            .main-container > * {
              min-width: 0; /* critical for preventing grid overflow caused by long content/images */
            }

            /* make images and media fully responsive inside the grid items */
            .main-container img {
              max-width: 100%;
              height: auto;
              display: block;
              object-fit: cover;
            }

            /* medium screens slightly tighter spacing - still no max-width used */
            @media (max-width: 1200px) {
              .main-container {
                grid-template-columns: minmax(0, 1fr) minmax(200px, 40%);
                gap: 16px;
              }
            }

            /* collapse to single column below 900px (your previous rule) */
            @media (max-width: 900px) {
              .main-container {
                grid-template-columns: 1fr;
              }
              .news-grid { grid-template-columns: 1fr !important; }
              .view-all { text-align: left; }
            }


            /* section box common */
            .section-box {
              background-color: #222;
              border: 1px solid #333;
              margin-bottom: 20px;
              border-radius: 10px;
              overflow: hidden;
            }

            .box-header {
              background-color: #3877e5;
              color: white;
              padding: 8px 15px;
              font-weight: bold;
              font-size: 1.1rem;
              border-radius: 10px 10px 0 0;
            }
            .box-content { padding: 15px; }

            /* Carousel */
            .carousel { position: relative; overflow: hidden; border-radius: 10px; }
            .carousel-track {
              display: flex;
              flex-wrap: nowrap;
              transition: transform 0.6s ease;
              will-change: transform;
              /* let the track size naturally; do NOT set width here */
            }
            .carousel-item {
              /* each item occupies the full carousel viewport width */
              flex: 0 0 100%;
              max-width: 100%;
              box-sizing: border-box;
            }

            /* responsive image sizing via aspect-ratio */
            .carousel-item img {
              width: 100%;
              height: auto;
              aspect-ratio: 16/9; /* keeps a consistent visible height without fixed px */
              object-fit: cover;
              display: block;
            }

            /* smaller carousel on narrow screens */
            @media (max-width: 480px) {
              .carousel-item img { height: 180px; }
            }

            /* tabs */
            .news-tabs { display: flex; gap: 8px; background-color: transparent; border-bottom: 1px solid #555; padding: 6px 0; }
            .news-tabs a {
              flex: 1 1 0;
              text-align: center;
              padding: 10px 8px;
              color: #ccc;
              text-decoration: none;
              font-weight: bold;
              cursor: pointer;
              border-radius: 6px;
              background: rgba(0,0,0,0);
              transition: background .15s;
            }
            .news-tabs a.active { background-color: #555; color: #fff; }

            /* news grid uses CSS variable --cols; fallback to 3 */
            .news-grid {
              display: grid;
              gap: 15px;
              margin-top: 15px;
              grid-template-columns: repeat(var(--cols, 3), 1fr);
            }

            /* each card */
            .news-item {
              background: #1b1b1b;
              padding: 10px;
              border-radius: 6px;
              border: 1px solid #333;
              display: flex;
              flex-direction: column;
              align-items: stretch;
              min-height: 160px;
            }

            .news-item .thumb {
              position: relative;
              display: block;
              width: 100%;
              overflow: hidden;
              border-radius: 4px;
            }
            .news-item .thumb img {
              width: 100%;
              height: 80px;
              object-fit: cover;
              display: block;
            }

            .news-item .play-overlay {
              position: absolute;
              left: 50%;
              top: 50%;
              transform: translate(-50%, -50%);
              background: rgba(0,0,0,0.5);
              color: #fff;
              font-weight: 700;
              font-size: 20px;
              padding: 8px 12px;
              border-radius: 999px;
              pointer-events: none;
            }

            .news-item .title { color: #ddd; text-decoration: none; font-weight: 600; margin: 8px 0 6px; display:block; }
            .news-item .meta  { font-size: 0.85rem; color: #999; }

            .view-all { text-align: right; margin-top: 15px; }
            .view-all a { color: #3877e5; text-decoration: none; font-size: 0.9rem; font-weight: bold; }

            .hot-threads ul, .got-bhp ul { list-style: none; padding: 0; margin: 0; }
            .hot-threads a { display: flex; justify-content: space-between; padding: 10px 15px; color: #ccc; text-decoration: none; border-radius: 6px; }

            /* Responsive: collapse to single column on small screens */
            /* Ultra small screens improvements */
            @media (max-width: 480px) {
              .box-header { font-size: 1rem; padding: 8px 10px; }
              .news-item .thumb img { height: 100px; }
              .news-item { min-height: 130px; }
            }
          </style>

          <div class="main-container">
            <div class="left-column">
              <div class="section-box carousel">
                <div class="carousel-track">
                  ${carouselItemsHtml}
                </div>
                <div style="position: absolute; bottom: 10px; left: 10px; color: white; background: rgba(0,0,0,0.5); padding: 5px; font-weight: bold;">
                  <span id="carousel-title">${topicsWithImages[0]?.title || ""}</span>
                </div>
              </div>

              <div class="section-box">
                <div class="box-header">Updates</div>
                <div class="box-content">
                  <div id="category-tabs" class="news-tabs">
                    <!-- tabs inserted here -->
                  </div>

                  <div id="news-grid" class="news-grid" style="--cols: ${GRID_COLUMNS};">
                    <!-- category topics will render here -->
                  </div>

                  <div class="view-all"><a id="view-all-link" href="#">View all in category →</a></div>
                </div>
              </div>
            </div>

            <div class="right-column">
              <div class="section-box hot-threads">
                <div class="box-header">Hot Posts</div>
                <div class="box-content">
                  <ul></ul>
                </div>
              </div>
            </div>
          </div>
        `;

        // After DOM injected, init news area
        initCarousel();
        initNewsCategories();
        loadHotThreads(); // call here, after markup exists
      })
      .catch((err) => {
        console.error("[top 5] fetch failed", err);

        // keep spinner for a short time then show error (so user will see something)
        setTimeout(() => {
          hideHomepageSpinner();
          const main = document.getElementById("homepage-main");
          if (main) main.innerHTML = `<div style="padding:20px;color:#aaa;">Failed to load homepage content.</div>`;
        }, 300);
      });
  }

  // --- NEWS / CATEGORY TAB LOGIC ---
  function initNewsCategories() {
    const categories = [
      { key: "catA", title: "Owner reports", slug: "owner-reports" },
      { key: "catB", title: "Travelogues", slug: "travelogues" },
      { key: "catC", title: "Technical stuff", slug: "technical-stuff" },
    ];

    const tabsContainer = document.getElementById("category-tabs");
    const grid = document.getElementById("news-grid");
    const viewAllLink = document.getElementById("view-all-link");
    if (!tabsContainer || !grid) return;

    // render tabs
    tabsContainer.innerHTML = categories
      .map((c, idx) => `<a data-idx="${idx}" class="${idx === 0 ? "active" : ""}">${c.title}</a>`)
      .join("");

    // try multiple endpoints until we get topics (returns array)
    function fetchCategoryTopics(slug, limit = 12) {
      const endpoints = [
        `/c/${encodeURIComponent(slug)}.json`,
        // `/c/${encodeURIComponent(slug)}/l/latest.json`,
        // `/latest.json?category=${encodeURIComponent(slug)}`
      ];

      let chain = Promise.reject();
      endpoints.forEach(ep => {
        chain = chain.catch(() => ajax(ep).then(resp => {
          if (resp.topic_list?.topics) return resp.topic_list.topics.slice(0, limit);
          if (Array.isArray(resp.topic_list)) return resp.topic_list.slice(0, limit);
          if (resp.topics) return resp.topics.slice(0, limit);
          if (resp.category && resp.category.topic_list) return resp.category.topic_list.slice(0, limit);
          return Promise.reject(new Error("no-topics"));
        }));
      });

      return chain.catch(() => Promise.resolve([]));
    }

    // helper: detect if a topic has a usable image URL (matches logic used elsewhere)
    function topicHasImage(t) {
      if (!t) return false;
      if (t.image_url || t.image) return true;
      if (t.details && (t.details.small_image_url || t.details.image_url)) return true;

      const candidates = [
        t.excerpt,
        t.fancy_title,
        t.featured_media,
        t.custom_thumbnail,
        t.link,
        ...(t.post_stream && t.post_stream.posts && t.post_stream.posts.length ? [t.post_stream.posts[0].cooked] : [])
      ].filter(Boolean);

      for (const c of candidates) {
        if (typeof c !== "string") continue;
        // obvious image url
        if (/(https?:\/\/\S+\.(?:png|jpe?g|gif)(\?\S*)?)/i.test(c)) return true;
        // img tag in cooked html
        if (/<img\s+[^>]*src=/i.test(c)) return true;
        // YouTube thumbnail available
        if (youtubeThumbnail(c)) return true;
        // Vimeo (we treat as having media, even if placeholder)
        if (isVimeo(c)) return true;
      }
      return false;
    }

    // single renderer that shows only topics with images
    function renderCategoryGrid(topics, category, options = {}) {
      if (!grid) return;
      const columns = options.columns || GRID_COLUMNS || 3;
      grid.style.setProperty('--cols', columns);

      const arr = Array.isArray(topics) ? topics : [];
      // filter to only topics that have images
      const withImages = arr.filter(topicHasImage).slice(0, GRID_MAX_ITEMS);

      if (withImages.length === 0) {
        grid.innerHTML = `<div style="grid-column: 1 / -1; color: #aaa">No topics found for "${category?.title || 'category'}".</div>`;
        if (viewAllLink) {
          viewAllLink.href = "#";
          viewAllLink.style.display = "none";
          viewAllLink.setAttribute("aria-hidden", "true");
        }
        return;
      }

      const itemsHtml = withImages.map(t => {
        const title = (t.title || "").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        const url = t.slug ? `/t/${t.slug}/${t.id}` : (t.url || (`/t/${t.id}`));
        const postsCount = t.posts_count ?? t.post_count ?? "";
        const poster = (t.details && t.details.last_posted_by) ? t.details.last_posted_by.username : (t.created_by?.username || "");
        const bumped = t.bumped_at || t.created_at || "";

        // extract media URL (same approach as earlier in your file)
        let mediaSrc = t.image_url || t.image || (t.details && (t.details.small_image_url || t.details.image_url)) || "";
        const candidates = [
          t.custom_thumbnail,
          t.featured_media,
          ...(t.post_stream && t.post_stream.posts && t.post_stream.posts.length ? [t.post_stream.posts[0].cooked] : []),
          t.excerpt,
          t.fancy_title,
          t.link,
          t.video_url
        ].filter(Boolean);

        for (const c of candidates) {
          if (!mediaSrc && typeof c === "string") {
            const imgMatch = c.match(/(https?:\/\/\S+\.(?:png|jpe?g|gif)(\?\S*)?)/i);
            if (imgMatch) { mediaSrc = imgMatch[1]; break; }
            const imgTagMatch = c.match(/<img\s+[^>]*src=(?:'|")([^'"]+)(?:'|")/i);
            if (imgTagMatch) { mediaSrc = imgTagMatch[1]; break; }
            const yt = youtubeThumbnail(c);
            if (yt) { mediaSrc = yt; break; }
            if (isVimeo(c)) { mediaSrc = NORMALIZED_PLACEHOLDER; break; }
          }
        }

        if (!mediaSrc) mediaSrc = NORMALIZED_PLACEHOLDER;
        else mediaSrc = normalizeUrl(mediaSrc);

        const mediaIsVideo = isVideoFile(mediaSrc);
        const playOverlay = mediaIsVideo ? `<div class="play-overlay" aria-hidden="true">▶</div>` : "";
        const alt = `Topic: ${t.title || "Untitled"}`;

        return `
          <div class="news-item">
            <a href="${url}" class="thumb" aria-label="${alt}">
              <img loading="lazy" src="${mediaSrc}" alt="${alt}" onerror="this.onerror=null;this.src='${NORMALIZED_PLACEHOLDER}';">
              ${playOverlay}
            </a>
            <a href="${url}" class="title">${title}</a>
            <div class="meta">${poster ? poster + " · " : ""}${postsCount ? postsCount + " posts · " : ""}${bumped ? new Date(bumped).toLocaleDateString() : ""}</div>
          </div>
        `;
      }).join("");

      grid.innerHTML = itemsHtml;

      if (viewAllLink && category && category.slug) {
        viewAllLink.href = `/c/${encodeURIComponent(category.slug)}`;
        viewAllLink.style.display = "";
        viewAllLink.removeAttribute("aria-hidden");
      }
    }

    // initial load for first tab
    const firstCategory = categories[0];
    fetchCategoryTopics(firstCategory.slug)
      .then(topics => renderCategoryGrid(topics, firstCategory))
      .catch(() => renderCategoryGrid([], firstCategory));

    // tab clicks
    Array.from(tabsContainer.querySelectorAll("a")).forEach(a => {
      a.addEventListener("click", (ev) => {
        ev.preventDefault();
        const idx = parseInt(a.dataset.idx, 10);
        if (isNaN(idx)) return;
        Array.from(tabsContainer.querySelectorAll("a")).forEach(x => x.classList.remove("active"));
        a.classList.add("active");

        const cat = categories[idx];
        grid.innerHTML = `<div style="grid-column:1/-1;color:#999">Loading ${cat.title}…</div>`;
        // optimistic link update
        if (viewAllLink && cat?.slug) {
          viewAllLink.href = `/c/${encodeURIComponent(cat.slug)}`;
          viewAllLink.style.display = "";
          viewAllLink.removeAttribute("aria-hidden");
        }
        fetchCategoryTopics(cat.slug).then(topics => renderCategoryGrid(topics, cat)).catch(() => renderCategoryGrid([], cat));
      });
    });
  }

  // --- CAROUSEL INIT ---
  function initCarousel() {
    const track = document.querySelector('.carousel-track');
    const items = Array.from(document.querySelectorAll('.carousel-item'));
    const title = document.getElementById('carousel-title');
    if (!track || items.length === 0) return;

    // ensure items use the CSS flex sizing; remove any inline width set earlier
    items.forEach(item => {
      item.style.width = ""; // clear any previous inline width
      item.style.flex = "0 0 100%";
    });
    track.style.width = ""; // clear previous inline width if present

    const titles = items.map(item => item.dataset.title || "");

    let currentIndex = 0;
    const intervalTime = 3000;
    let observer = null;
    let resizeObserver = null;

    function updateCarouselVisual() {
      // translate by percentage of viewport (each item = 100%)
      const shiftPercent = currentIndex * 100;
      track.style.transform = `translateX(-${shiftPercent}%)`;
      if (title && titles.length > 0) title.textContent = titles[currentIndex] || "";
    }

    function nextSlide() {
      currentIndex = (currentIndex + 1) % items.length;
      updateCarouselVisual();
    }

    // clear previous interval if any
    if (_carouselIntervalId) clearInterval(_carouselIntervalId);
    _carouselIntervalId = setInterval(nextSlide, intervalTime);

    // ensure transform is correct on init
    updateCarouselVisual();

    // Recalculate visual transform on resize (keeps the current slide centered if container width changes)
    if (window.ResizeObserver) {
      // use ResizeObserver on the carousel container to re-apply the same percentage transform
      try {
        const carouselEl = document.querySelector('.carousel');
        resizeObserver = new ResizeObserver(() => {
          // reapply transform (percentage-based, so this keeps correct slide)
          updateCarouselVisual();
        });
        if (carouselEl) resizeObserver.observe(carouselEl);
      } catch (e) {
        // ignore RO errors
      }
    } else {
      // fallback: window resize event
      window.addEventListener('resize', updateCarouselVisual);
    }

    // optional: allow clicking items to jump to index (if you want)
    items.forEach((item, idx) => {
      item.addEventListener('click', (ev) => {
        // example behavior: go to clicked slide
        currentIndex = idx;
        updateCarouselVisual();
      });
    });

    // cleanup helper if you ever want to stop the carousel
    // (kept local — not automatically invoked here)
    function destroy() {
      if (_carouselIntervalId) { clearInterval(_carouselIntervalId); _carouselIntervalId = null; }
      if (resizeObserver && resizeObserver.disconnect) resizeObserver.disconnect();
      window.removeEventListener('resize', updateCarouselVisual);
    }

    // store destroy on track for potential later use (optional)
    track.__carouselDestroy = destroy;
  }

  // home-route detection (keeps your robust checks)
  function isHomepageRoute(api) {
    try {
      const router = api.container.lookup("service:router");
      const siteSettings = api.container.lookup("service:site-settings");
      const routeName = router?.currentRouteName || "";
      const currentURL = router?.currentURL || window.location.pathname || "";
      const firstTopMenu = (siteSettings?.top_menu || "").split("|")[0]?.trim() || "";
      const pathIsRoot = window.location.pathname === "/";
      const routeMatchesFirstTop = firstTopMenu ? routeName === `discovery.${firstTopMenu}` : false;
      const routeStartsWithDiscovery = routeName && routeName.indexOf("discovery") === 0;
      const hasDiscoveryDom = !!document.querySelector(".discovery-index, .listings, .navigation");
      console.debug("LANDING-COMP: routeName=", routeName, " currentURL=", currentURL, " pathIsRoot=", pathIsRoot,
        " firstTopMenu=", firstTopMenu, " routeMatchesFirstTop=", routeMatchesFirstTop,
        " routeStartsWithDiscovery=", routeStartsWithDiscovery, " hasDiscoveryDom=", hasDiscoveryDom);
      return pathIsRoot || routeMatchesFirstTop || routeStartsWithDiscovery || hasDiscoveryDom;
    } catch (e) {
      console.warn("LANDING-COMP: isHomepageRoute()failed:", e);
      return window.location.pathname === "/";
    }
  }


  // ------- STRONGER outlet-aware mount/unmount with verbose diagnostics -------

let _homepageMounted = false;
let _renderInProgress = false;
let _routeListenerRegistered = false;

/** health check for homepage-main node */
function homepageElementIsHealthy() {
  const el = document.getElementById("homepage-main");
  if (!el) return false;
  if (!document.body.contains(el)) return false;
  if (!el.innerHTML || el.innerHTML.trim().length < 10) return false;
  return true;
}

/**
 * Wait up to `timeoutMs` for *any* selector from the comma-separated selector list to appear.
 * Returns the element found and the selector that matched, or null if timeout.
 */
function waitForAnySelector(selectorList, timeoutMs = 3000) {
  const selectors = String(selectorList || "").split(",").map(s => s.trim()).filter(Boolean);
  return new Promise((resolve) => {
    // quick check
    for (const sel of selectors) {
      const ex = document.querySelector(sel);
      if (ex) return resolve({ el: ex, sel });
    }

    let resolved = false;
    let observer = null;
    let tid = null;

    function checkAndResolve() {
      if (resolved) return;
      for (const sel of selectors) {
        const ex = document.querySelector(sel);
        if (ex) {
          resolved = true;
          if (observer) observer.disconnect();
          if (tid) clearTimeout(tid);
          return resolve({ el: ex, sel });
        }
      }
    }

    observer = new MutationObserver(checkAndResolve);
    observer.observe(document.documentElement || document.body, { childList: true, subtree: true });

    tid = setTimeout(() => {
      if (resolved) return;
      resolved = true;
      if (observer) observer.disconnect();
      resolve(null);
    }, timeoutMs);
  });
}

/** Remove homepage and clear carousel state */
function unmountHomepage() {
  _homepageMounted = false;
  _renderInProgress = false;

  try {
    const el = document.getElementById("homepage-main");
    if (el && document.body.contains(el)) {
      el.remove();
      console.info("LANDING-COMP: removed #homepage-main");
    }
  } catch (e) {
    console.warn("LANDING-COMP: unmountHomepage error", e);
  }

  if (_carouselIntervalId) {
    clearInterval(_carouselIntervalId);
    _carouselIntervalId = null;
  }
  const track = document.querySelector('.carousel-track');
  if (track && typeof track.__carouselDestroy === "function") {
    try { track.__carouselDestroy(); } catch (e) { /* ignore */ }
    track.__carouselDestroy = null;
  }
}

/**
 * Try rendering into a list of outlet NAMES and pick the one that results in #homepage-main
 * being placed inside one of the desired parent selectors (e.g. #main-outlet, .wrap).
 *
 * - outletNames: list of outlet names to try (Ember names like "main", "application", or your theme's)
 * - desiredParentSelectors: where you want #homepage-main to live (page outlet)
 */
async function mountHomepageTryOutletNames({
  outletNames = ["above-main-container", "main", "application", "main-outlet", "site", "above-site-header"],
  desiredParentSelectors = ["#main-outlet", ".wrap", ".container"],
  perAttemptTimeout = 50
} = {}) {
  // guard
  if (_renderInProgress) {
    console.debug("LANDING-COMP: mount in progress — skipping new mount");
    return;
  }
  _renderInProgress = true;

  // remove any previous instance
  try { 
    const prev = document.getElementById("homepage-main");
    if (prev && prev.parentNode) prev.remove();
  } catch (e) { /* ignore */ }

  // helper: check whether homepage is inside a desired parent
  function homepageInsideDesiredParent() {
    const home = document.getElementById("homepage-main");
    if (!home) return null;
    for (const sel of desiredParentSelectors) {
      const parent = document.querySelector(sel);
      if (parent && parent.contains(home)) return { home, parent, matchedSelector: sel };
    }
    return null;
  }

  // Attempt each outlet name once
  for (const outletName of outletNames) {
    try {
      console.debug(`LANDING-COMP: trying api.renderInOutlet("${outletName}")`);
      // remove any previous instance before attempting
      try {
        const existing = document.getElementById("homepage-main");
        if (existing && existing.parentNode) existing.remove();
      } catch (e) { /* ignore */ }

      // call renderInOutlet
      try {
        api.renderInOutlet(outletName, <template><div id="homepage-main"></div></template>);
      } catch (eRender) {
        console.debug(`LANDING-COMP: renderInOutlet("${outletName}") threw:`, eRender && eRender.message);
      }

      // small tick to allow Ember to attach the node
      await new Promise(r => setTimeout(r, perAttemptTimeout));

      // check if Ember placed homepage-main
      const created = document.getElementById("homepage-main");
      if (!created) {
        console.debug(`LANDING-COMP: renderInOutlet("${outletName}") did not create #homepage-main (or was removed)`);
        continue;
      }

      // check if placed inside desired parent
      const inside = homepageInsideDesiredParent();
      if (inside) {
        console.info(`LANDING-COMP: renderInOutlet("${outletName}") placed homepage inside desired parent (${inside.matchedSelector}).`);
        _homepageMounted = true;
        _renderInProgress = false;
        return { success: true, outletName, matchedSelector: inside.matchedSelector };
      }

      // Not in desired parent — log the parent Ember used for visibility
      console.warn(`LANDING-COMP: renderInOutlet("${outletName}") placed homepage in unexpected parent:`, created.parentNode);
      // remove the misplaced node before next attempt to avoid duplicates
      try { created.remove(); } catch (e) { /* ignore */ }
    } catch (eOuter) {
      console.error("LANDING-COMP: error during outlet-name attempt", eOuter);
    }
  }

  // If we reach here, none of the outletNames placed homepage into a desired parent.
  // As a last resort create a manual container inside the first desired parent (deterministic, single insertion).
  try {
    // remove any leftover
    const previous = document.getElementById("homepage-main");
    if (previous && previous.parentNode) previous.remove();

    // pick the first desired parent that exists
    let parent = null;
    for (const sel of desiredParentSelectors) {
      const p = document.querySelector(sel);
      if (p) { parent = p; break; }
    }
    if (!parent) parent = document.body;

    const container = document.createElement("div");
    container.id = "homepage-main";
    // insert at top of parent but after header if possible
    const header = parent.querySelector("header, .header");
    if (header && header.nextSibling) header.parentNode.insertBefore(container, header.nextSibling);
    else parent.insertBefore(container, parent.firstChild);

    console.warn("LANDING-COMP: fallback manual insert of #homepage-main into", parent);
    _homepageMounted = true;
    _renderInProgress = false;
    return { success: true, fallback: true, parentSelector: parent.tagName + (parent.id ? `#${parent.id}` : "") };
  } catch (eFinal) {
    console.error("LANDING-COMP: final fallback insert failed", eFinal);
    _renderInProgress = false;
    return { success: false, error: eFinal };
  }
}


async function mountHomepage() {
  if (homepageElementIsHealthy()) { _homepageMounted = true; return; }

  const res = await mountHomepageTryOutletNames({
    outletNames: ["above-main-container", "main", "application", "main-outlet"],
    desiredParentSelectors: ["#main-outlet", ".wrap", ".container"],
    perAttemptTimeout: 60
  });

  if (res && res.success) {
    // populate only after container actually exists
    if (document.getElementById("homepage-main")) {
      try { loadTop5(); } catch (e) { console.error("loadTop5() threw", e); }
    }
  } else {
    console.error("LANDING-COMP: mountHomepage failed to bind to an outlet", res);
  }
}


/** ensure a single route listener and call mount/unmount accordingly */
function ensureRouteListener() {
  if (_routeListenerRegistered) return;
  _routeListenerRegistered = true;

  try {
    const router = api.container.lookup("service:router");
    if (router && typeof router.on === "function") {
      router.on("routeDidChange", () => {
        requestAnimationFrame(() => {
          const isHome = isHomepageRoute(api);
          console.debug("LANDING-COMP: routeDidChange -> isHome=", isHome);
          if (isHome) {
            if (!homepageElementIsHealthy()) requestAnimationFrame(() => mountHomepage());
            else _homepageMounted = true;
          } else {
            unmountHomepage();
          }
        });
      });
      return;
    }
  } catch (e) {
    // fallback to api.onPageChange below
  }

  api.onPageChange(() => {
    setTimeout(() => requestAnimationFrame(() => {
      const isHome = isHomepageRoute(api);
      console.debug("LANDING-COMP: onPageChange -> isHome=", isHome);
      if (isHome) {
        if (!homepageElementIsHealthy()) mountHomepage();
        else _homepageMounted = true;
      } else {
        unmountHomepage();
      }
    }), 0);
  });
}

// initial registration + initial check
ensureRouteListener();
requestAnimationFrame(() => {
  const initialIsHome = isHomepageRoute(api);
  console.debug("LANDING-COMP: initialIsHome=", initialIsHome);
  if (initialIsHome) {
    if (!homepageElementIsHealthy()) mountHomepage();
    else _homepageMounted = true;
  }
});

  // END
});
