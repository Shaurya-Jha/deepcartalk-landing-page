import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";

const GRID_MAX_ITEMS = 6;          // show up to 6 items
let GRID_COLUMNS = 3;             // set 2 or 3 (3 -> 3x2, 2 -> 2x3)
const PLACEHOLDER = "/images/placeholder.png"; // update path

// cache for fetched tabs: { tabKey: topicsArray }
const topicsCache = {};

// helpers for media detection
function youtubeThumbnail(url) {
  const m = url && url.match(/(?:youtube\.com\/watch\?v=|youtu\.be\/)([A-Za-z0-9_-]{6,})/);
  return m ? `https://img.youtube.com/vi/${m[1]}/hqdefault.jpg` : null;
}
function isVimeo(url) { return /vimeo\.com\/\d+/.test(url); }
function isVideoFile(url) { return /\.(mp4|webm|ogg|mov)(\?.*)?$/i.test(url); }

// simple emoji helpers + hot threads (minimal)
/** escape HTML for safety */
function escapeHtml(s) {
  return (s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
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

      if (Array.isArray(resp)) {
        resp.forEach(e => {
          const name = e && (e.name || e.shortcode || "");
          const url = e && (e.url || e.file || e.path || e.image);
          const aliases = Array.isArray(e && e.search_aliases) ? e.search_aliases : [];
          registerCanonical(name, url, aliases);
        });
      } else if (resp && typeof resp === "object") {
        Object.keys(resp).forEach(k => {
          const v = resp[k];
          if (Array.isArray(v)) {
            v.forEach(e => {
              const name = e && (e.name || e.shortcode || "");
              const url = e && (e.url || e.file || e.path || e.image);
              const aliases = Array.isArray(e && e.search_aliases) ? e.search_aliases : [];
              registerCanonical(name, url, aliases);
            });
            return;
          }
          if (typeof v === "string") {
            registerCanonical(k, v, []);
            return;
          }
          if (v && typeof v === "object") {
            const url = v.url || v.file || v.path || v.image;
            const aliases = Array.isArray(v.search_aliases) ? v.search_aliases : [];
            registerCanonical(k, url, aliases);
            return;
          }
        });
      }

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

function replaceShortcodesWithImages(escapedText, maps) {
  if (!escapedText || escapedText.indexOf(":") === -1) return escapedText;
  const primaryMap = maps.primaryMap || {};
  const aliasMap = maps.aliasMap || {};

  return escapedText.replace(/:([a-z0-9_+\-]+):/gi, (full, rawName) => {
    const name = String(rawName).toLowerCase();

    const canonicalFromAlias = aliasMap[name];
    if (canonicalFromAlias && primaryMap[canonicalFromAlias] && primaryMap[canonicalFromAlias].url) {
      return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[canonicalFromAlias].url}" style="height:1em;vertical-align:-0.15em">`;
    }
    if (primaryMap[name] && primaryMap[name].url) {
      return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[name].url}" style="height:1em;vertical-align:-0.15em">`;
    }
    const alt1 = name.replace(/_/g, "-");
    const alt2 = name.replace(/-/g, "_");
    if (primaryMap[alt1] && primaryMap[alt1].url) {
      return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[alt1].url}" style="height:1em;vertical-align:-0.15em">`;
    }
    if (primaryMap[alt2] && primaryMap[alt2].url) {
      return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[alt2].url}" style="height:1em;vertical-align:-0.15em">`;
    }
    for (const canonical in primaryMap) {
      if (!primaryMap.hasOwnProperty(canonical)) continue;
      if (aliasMap[name] === canonical && primaryMap[canonical].url) {
        return `<img class="emoji" alt=":${rawName}:" src="${primaryMap[canonical].url}" style="height:1em;vertical-align:-0.15em">`;
      }
    }
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
          const unicode = t.unicode_title;
          const raw = unicode || t.fancy_title || t.title || "";
          let processed;
          if (unicode) {
            processed = escapeHtml(String(unicode));
          } else {
            const escaped = escapeHtml(String(raw));
            processed = replaceShortcodesWithImages(escaped, customMap);
          }
          const url = t.slug ? `/t/${t.slug}/${t.id}` : (t.url || (`/t/${t.id}`));
          return `<li><a href="${url}"><span>${processed}</span><span>►</span></a></li>`;
        }).join("");
      })
      .catch((err) => {
        console.error("[hot-threads] fetch failed", err);
      });
  }

  // --- TOP 5 / CAROUSEL ---
  function loadTop5() {
    // NOTE: avoid JSX in theme initializers. use a simple HTML string instead.
    try {
      api.renderInOutlet("above-main-container", "<div id='homepage-main'></div>");
    } catch (e) {
      if (!document.getElementById("homepage-main")) {
        const container = document.createElement("div");
        container.id = "homepage-main";
        const first = document.body.firstChild;
        document.body.insertBefore(container, first);
      }
    }

    ajax("/top/monthly.json")
      .then((response) => {
        const topics = (response.topic_list?.topics || []).slice(0, 5);
        const topicsWithImages = topics.filter(t => !!t.image_url);
        const main = document.getElementById("homepage-main");
        if (!main) return;

        const carouselItemsHtml = topicsWithImages.map(t => `
          <div class="carousel-item" data-title="${(t.title || "").replace(/"/g, "&quot;")}" data-topic-id="${t.id}">
            <img src="${t.image_url}" alt="${(t.title || "").replace(/"/g, "&quot;")}" loading="lazy">
          </div>
        `).join("");

        main.innerHTML = `
          <style>
            /* responsive layout & styling kept from your version (adjust if needed) */
            .main-container { width: 100%; max-width: 1100px; margin: 20px auto; padding:0 16px; display:grid; grid-template-columns:660px 300px; gap:20px; box-sizing:border-box; }
            .section-box { background:#222; border:1px solid #333; border-radius:10px; overflow:hidden; }
            .box-header { background:#3877e5; color:#fff; padding:8px 15px; font-weight:bold; font-size:1.1rem; border-radius:10px 10px 0 0; }
            .box-content { padding:15px; }
            .carousel { position:relative; overflow:hidden; border-radius:10px; }
            .carousel-track { display:flex; transition:transform .6s ease; will-change:transform; }
            .carousel-item { flex-shrink:0; width:100%; }
            .carousel-item img { width:100%; height:380px; object-fit:cover; display:block; }
            @media (max-width:900px){ .carousel-item img{ height:260px } .main-container{ grid-template-columns:1fr } .news-grid{ grid-template-columns:1fr !important } .view-all{ text-align:left } }
            @media (max-width:480px){ .carousel-item img{ height:180px } .box-header{ font-size:1rem } .news-item .thumb img{ height:100px } .news-item{ min-height:130px } }

            .news-tabs { display:flex; gap:8px; border-bottom:1px solid #555; padding:6px 0; }
            .news-tabs a { flex:1 1 0; text-align:center; padding:10px 8px; color:#ccc; text-decoration:none; font-weight:bold; cursor:pointer; border-radius:6px; background:transparent; transition:background .15s; }
            .news-tabs a.active { background:#555; color:#fff; }

            .news-grid { display:grid; gap:15px; margin-top:15px; grid-template-columns:repeat(var(--cols,3),1fr); }
            .news-item { background:#1b1b1b; padding:10px; border-radius:6px; border:1px solid #333; display:flex; flex-direction:column; align-items:stretch; min-height:160px; }
            .news-item .thumb { position:relative; display:block; width:100%; overflow:hidden; border-radius:4px; }
            .news-item .thumb img { width:100%; height:80px; object-fit:cover; display:block; }
            .play-overlay { position:absolute; left:50%; top:50%; transform:translate(-50%,-50%); background:rgba(0,0,0,0.5); color:#fff; font-weight:700; font-size:20px; padding:8px 12px; border-radius:999px; pointer-events:none; }
            .news-item .title{ color:#ddd; text-decoration:none; font-weight:600; margin:8px 0 6px; display:block; }
            .news-item .meta{ font-size:.85rem; color:#999; }
            .view-all{ text-align:right; margin-top:15px; }
            .view-all a{ color:#3877e5; text-decoration:none; font-size:.9rem; font-weight:bold; }
            .hot-threads ul{ list-style:none; padding:0; margin:0; }
            .hot-threads a{ display:flex; justify-content:space-between; padding:10px 15px; color:#ccc; text-decoration:none; border-radius:6px; }
          </style>

          <div class="main-container">
            <div class="left-column">
              <div class="section-box carousel">
                <div class="carousel-track">
                  ${carouselItemsHtml}
                </div>
                <div style="position:absolute; bottom:10px; left:10px; color:white; background:rgba(0,0,0,0.5); padding:5px; font-weight:bold;">
                  <span id="carousel-title">${topicsWithImages[0] ? (topicsWithImages[0].title || "") : ""}</span>
                </div>
              </div>

              <div class="section-box">
                <div class="box-header">Updates</div>
                <div class="box-content">
                  <div id="category-tabs" class="news-tabs"></div>
                  <div id="news-grid" class="news-grid" style="--cols: ${GRID_COLUMNS};"></div>
                  <div class="view-all"><a id="view-all-link" href="#">View all in category →</a></div>
                </div>
              </div>
            </div>

            <div class="right-column">
              <div class="section-box hot-threads">
                <div class="box-header">Hot Posts</div>
                <div class="box-content"><ul></ul></div>
              </div>
            </div>
          </div>
        `;

        initCarousel();
        initNewsCategories();
        loadHotThreads();
      })
      .catch((err) => {
        console.error("[top 5] fetch failed", err);
      });
  }

  // --- NEWS / CATEGORY TAB LOGIC ---
  function initNewsCategories() {
    const categories = [
      { key: "catA", title: "Travelogues", slug: "travelogues" },
      { key: "catB", title: "Technical Stuff", slug: "technical-stuff" },
      { key: "catC", title: "Owner Reports", slug: "owner-reports" },
    ];

    const tabsContainer = document.getElementById("category-tabs");
    const grid = document.getElementById("news-grid");
    const viewAllLink = document.getElementById("view-all-link");
    if (!tabsContainer || !grid) return;

    tabsContainer.innerHTML = categories.map((c, idx) => `<a data-idx="${idx}" class="${idx === 0 ? "active" : ""}">${c.title}</a>`).join("");

    function fetchCategoryTopics(slug, limit = 9) {
      const endpoints = [
        `/c/${encodeURIComponent(slug)}.json`,
        `/latest.json?category=${encodeURIComponent(slug)}`,
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

    // SINGLE, safe render function
    function renderCategoryGrid(topics, category, options = {}) {
      if (!grid) return;
      const columns = options.columns || GRID_COLUMNS || 3;
      grid.style.setProperty('--cols', columns);

      // normalize topics
      const safeTopics = Array.isArray(topics) ? topics.slice(0, GRID_MAX_ITEMS) : [];

      if (safeTopics.length === 0) {
        grid.innerHTML = `<div style="grid-column:1/-1;color:#aaa">No topics found for "${category?.title || 'category'}".</div>`;
        if (viewAllLink) {
          viewAllLink.href = "#";
          viewAllLink.style.display = "none";
          viewAllLink.setAttribute("aria-hidden", "true");
        }
        return;
      }

      const itemsHtml = safeTopics.map(t => {
        const title = (t.title || "").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        const url = t.slug ? `/t/${t.slug}/${t.id}` : (t.url || (`/t/${t.id}`));
        const postsCount = t.posts_count ?? t.post_count ?? "";
        const poster = (t.details && t.details.last_posted_by) ? t.details.last_posted_by.username : (t.created_by?.username || "");
        const bumped = t.bumped_at || t.created_at || "";

        let mediaSrc = t.image_url || t.image || (t.details && (t.details.small_image_url || t.details.image_url)) || "";
        const candidates = [
          t.custom_thumbnail, t.featured_media,
          ...(t.post_stream && t.post_stream.posts && t.post_stream.posts.length ? [t.post_stream.posts[0].cooked] : []),
          t.excerpt, t.fancy_title, t.link, t.video_url
        ].filter(Boolean);

        for (const c of candidates) {
          if (!mediaSrc && isVideoFile(c)) { mediaSrc = c; break; }
          if (!mediaSrc) {
            const yt = youtubeThumbnail(c);
            if (yt) { mediaSrc = yt; break; }
          }
          if (!mediaSrc && isVimeo(c)) { mediaSrc = PLACEHOLDER; break; }
          if (!mediaSrc && typeof c === 'string') {
            const imgMatch = c.match(/(https?:\/\/\S+\.(?:png|jpe?g|gif)(\?\S*)?)/i);
            if (imgMatch) { mediaSrc = imgMatch[1]; break; }
            const imgTagMatch = c.match(/<img\s+[^>]*src=(?:'|")([^'"]+)(?:'|")/i);
            if (imgTagMatch) { mediaSrc = imgTagMatch[1]; break; }
          }
        }

        if (!mediaSrc) mediaSrc = PLACEHOLDER;
        const mediaIsVideo = /\.(mp4|webm|ogg|mov)(\?.*)?$/i.test(mediaSrc);
        const playOverlay = mediaIsVideo ? `<div class="play-overlay" aria-hidden="true">▶</div>` : "";

        const alt = `Topic: ${t.title || "Untitled"}`;

        return `
          <div class="news-item">
            <a href="${url}" class="thumb" aria-label="${alt}">
              <img loading="lazy" src="${mediaSrc}" alt="${alt}" onerror="this.onerror=null;this.src='${PLACEHOLDER}';">
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
    fetchCategoryTopics(firstCategory.slug).then(topics => renderCategoryGrid(topics, firstCategory)).catch(() => renderCategoryGrid([], firstCategory));

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
        fetchCategoryTopics(cat.slug).then(topics => renderCategoryGrid(topics, cat)).catch(() => renderCategoryGrid([], cat));
      });
    });
  }

  // --- CAROUSEL ---
  function initCarousel() {
    const track = document.querySelector('.carousel-track');
    const items = Array.from(document.querySelectorAll('.carousel-item'));
    const title = document.getElementById('carousel-title');
    if (!track || items.length === 0) return;
    track.style.width = `${items.length * 100}%`;
    items.forEach(item => item.style.width = `${100 / items.length}%`);
    const titles = items.map(item => item.dataset.title || "");
    let currentIndex = 0;
    const intervalTime = 3000;
    function updateCarousel() {
      const shiftPercent = (100 / items.length) * currentIndex;
      track.style.transform = `translateX(-${shiftPercent}%)`;
      if (title && titles.length > 0) title.textContent = titles[currentIndex] || "";
    }
    function nextSlide() {
      currentIndex = (currentIndex + 1) % items.length;
      updateCarousel();
    }
    updateCarousel();
    if (_carouselIntervalId) clearInterval(_carouselIntervalId);
    _carouselIntervalId = setInterval(nextSlide, intervalTime);
  }

  // helpers to mount/unmount safely
  function mountHomepage() {
    if (document.getElementById("homepage-main")) return; // already mounted
    console.info("LANDING-COMP: mounting homepage component");
    loadTop5();
  }

  function unmountHomepage() {
    const el = document.getElementById("homepage-main");
    if (el) {
      const wrapper = el.closest(".section-box") || el;
      wrapper.remove();
      console.info("LANDING-COMP: unmounted homepage component");
    }
    if (_carouselIntervalId) {
      clearInterval(_carouselIntervalId);
      _carouselIntervalId = null;
    }
  }

  // Strict homepage detection: only root path
  function isHomepageRoute(api) {
    try {
      return window.location.pathname === "/";
    } catch (e) {
      console.warn("LANDING-COMP: isHomepageRoute() failed:", e);
      return window.location.pathname === "/";
    }
  }

  // React to route changes: mount/unmount only when we're on "/"
  api.onPageChange(() => {
    const isHome = isHomepageRoute(api);
    console.debug("LANDING-COMP: onPageChange => isHome=", isHome);
    if (isHome) mountHomepage();
    else unmountHomepage();
  });

  // initial check for the first load
  const initialIsHome = isHomepageRoute(api);
  console.debug("LANDING-COMP: initialIsHome=", initialIsHome);
  if (initialIsHome) mountHomepage();

  // END
});
