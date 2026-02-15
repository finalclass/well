// well-live.js — LiveView client
// Handles WebSocket connection, DOM patching, event delegation,
// debounce/throttle, JS hooks, server push, and live navigation

(function () {
  "use strict";

  let ws = null;
  let reconnectDelay = 500;
  const maxReconnectDelay = 10000;
  const liveViews = new Map(); // topic -> { el, endpoint, props }

  // ── Debounce / Throttle ──────────────────────────────────────────

  const debounceTimers = new Map();
  const throttleTimers = new Map();

  function debouncedSend(key, ms, fn) {
    clearTimeout(debounceTimers.get(key));
    debounceTimers.set(key, setTimeout(fn, ms));
  }

  function throttledSend(key, ms, fn) {
    var now = Date.now();
    if (now - (throttleTimers.get(key) || 0) >= ms) {
      throttleTimers.set(key, now);
      fn();
    }
  }

  function maybeSend(el, fn) {
    var debounce = el.closest("[data-lv-debounce]");
    var throttle = el.closest("[data-lv-throttle]");
    if (debounce) {
      var ms = parseInt(debounce.getAttribute("data-lv-debounce"), 10) || 300;
      var key = debounce.getAttribute("id") || debounce.getAttribute("data-lv-change") || "d";
      debouncedSend(key, ms, fn);
    } else if (throttle) {
      var ms2 = parseInt(throttle.getAttribute("data-lv-throttle"), 10) || 300;
      var key2 = throttle.getAttribute("id") || throttle.getAttribute("data-lv-click") || "t";
      throttledSend(key2, ms2, fn);
    } else {
      fn();
    }
  }

  // ── JS Hooks ─────────────────────────────────────────────────────

  var hooks = {};
  var hookInstances = new Map(); // element -> instance

  window.WellLive = { hooks: hooks };

  function mountHooks(container) {
    var els = container.querySelectorAll("[data-lv-hook]");
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (hookInstances.has(el)) continue;
      var name = el.getAttribute("data-lv-hook");
      var hookDef = hooks[name];
      if (!hookDef) continue;
      var topic = findLiveView(el);
      var instance = {
        el: el,
        _topic: topic,
        _handlers: {},
        pushEvent: function (event, payload) {
          if (this._topic) {
            sendMsg(this._topic, ["HookEvent", { event: event, payload: payload }]);
          }
        },
        handleEvent: function (event, cb) {
          if (!this._handlers[event]) this._handlers[event] = [];
          this._handlers[event].push(cb);
        }
      };
      hookInstances.set(el, instance);
      if (hookDef.mounted) hookDef.mounted.call(instance);
    }
  }

  function updateHooks(container) {
    // Destroy hooks for removed elements
    hookInstances.forEach(function (instance, el) {
      if (!container.contains(el)) {
        var name = el.getAttribute("data-lv-hook");
        var hookDef = hooks[name];
        if (hookDef && hookDef.destroyed) hookDef.destroyed.call(instance);
        hookInstances.delete(el);
      }
    });
    // Update existing hooks
    hookInstances.forEach(function (instance, el) {
      if (container.contains(el)) {
        var name = el.getAttribute("data-lv-hook");
        var hookDef = hooks[name];
        if (hookDef && hookDef.updated) hookDef.updated.call(instance);
      }
    });
    // Mount new hooks
    mountHooks(container);
  }

  function dispatchHookEvent(topic, event, payload) {
    hookInstances.forEach(function (instance) {
      if (instance._topic === topic && instance._handlers[event]) {
        instance._handlers[event].forEach(function (cb) { cb(payload); });
      }
    });
  }

  // ── Connection ───────────────────────────────────────────────────

  function connect() {
    var proto = location.protocol === "https:" ? "wss:" : "ws:";
    var url = proto + "//" + location.host + "/live";
    ws = new WebSocket(url);

    ws.onopen = function () {
      reconnectDelay = 500;
      // Join all live views on the page
      liveViews.forEach(function (lv, topic) {
        lv.el.classList.add("lv-loading");
        ws.send(
          JSON.stringify({
            type: "join",
            topic: topic,
            endpoint: lv.endpoint,
            props: lv.props,
          })
        );
      });
    };

    ws.onmessage = function (event) {
      var msg;
      try {
        msg = JSON.parse(event.data);
      } catch (e) {
        return;
      }

      var topic = msg.topic;
      var lv = liveViews.get(topic);

      switch (msg.type) {
        case "full":
        case "restored":
          if (lv) {
            lv.el.innerHTML = msg.html;
            lv.el.classList.remove("lv-loading");
            mountHooks(lv.el);
          }
          break;

        case "patch":
          if (!lv) break;
          // Apply text changes
          if (msg.changes) {
            var keys = Object.keys(msg.changes);
            for (var i = 0; i < keys.length; i++) {
              var id = keys[i];
              var el = lv.el.querySelector('[data-lv="' + id + '"]');
              if (el) {
                el.textContent = msg.changes[id];
              }
            }
          }
          // Apply list operations
          if (msg.list_ops) {
            var listIds = Object.keys(msg.list_ops);
            for (var li = 0; li < listIds.length; li++) {
              var listId = listIds[li];
              var ops = msg.list_ops[listId];
              var container = lv.el.querySelector(
                '[data-lv-each="' + listId + '"]'
              );
              if (!container) continue;

              // Build map of existing keyed children
              var existing = new Map();
              var children = container.children;
              for (var j = 0; j < children.length; j++) {
                var key = children[j].getAttribute("data-lv-key");
                if (key) existing.set(key, children[j]);
              }

              // Process inserts (new or updated items)
              if (ops.inserts) {
                var insertKeys = Object.keys(ops.inserts);
                for (var ij = 0; ij < insertKeys.length; ij++) {
                  var ikey = insertKeys[ij];
                  var html = ops.inserts[ikey];
                  var tmp = document.createElement("div");
                  tmp.innerHTML = html;
                  var newEl = tmp.firstElementChild;
                  if (newEl) {
                    existing.set(ikey, newEl);
                  }
                }
              }

              // Reorder according to ops.order
              if (ops.order) {
                while (container.firstChild) {
                  container.removeChild(container.firstChild);
                }
                for (var oi = 0; oi < ops.order.length; oi++) {
                  var okey = ops.order[oi];
                  var oel = existing.get(okey);
                  if (oel) container.appendChild(oel);
                }
              }
            }
          }
          updateHooks(lv.el);
          break;

        case "event":
          // Server-pushed event to hooks
          if (msg.event) {
            dispatchHookEvent(topic, msg.event, msg.payload || null);
          }
          break;

        case "navigate":
          // Live navigation response
          if (msg.url && msg.html) {
            history.pushState({ wellNav: true }, "", msg.url);
            applyNavigationHtml(msg.html);
          }
          break;
      }
    };

    ws.onclose = function () {
      liveViews.forEach(function (lv) {
        lv.el.classList.add("lv-loading");
      });
      setTimeout(function () {
        reconnectDelay = Math.min(reconnectDelay * 2, maxReconnectDelay);
        connect();
      }, reconnectDelay);
    };

    ws.onerror = function () {
      ws.close();
    };
  }

  function sendMsg(topic, msg) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "msg", topic: topic, msg: msg }));
    }
  }

  // Find the live-view ancestor of an element and return its topic
  function findLiveView(el) {
    var node = el;
    while (node) {
      if (node.tagName === "LIVE-VIEW") {
        var topic =
          node.getAttribute("data-topic") ||
          node.getAttribute("data-liveview");
        return topic;
      }
      node = node.parentElement;
    }
    return null;
  }

  // ── Event delegation — click ─────────────────────────────────────

  document.addEventListener("click", function (e) {
    // Live navigation — intercept clicks on [data-lv-navigate]
    var navTarget = e.target.closest("[data-lv-navigate]");
    if (navTarget) {
      e.preventDefault();
      var url = navTarget.getAttribute("href") || navTarget.getAttribute("data-lv-navigate");
      if (url) navigateTo(url);
      return;
    }

    // Patch navigation — like navigate but replaces URL
    var patchTarget = e.target.closest("[data-lv-patch]");
    if (patchTarget) {
      e.preventDefault();
      var patchUrl = patchTarget.getAttribute("href") || patchTarget.getAttribute("data-lv-patch");
      if (patchUrl) navigateTo(patchUrl, true);
      return;
    }

    var target = e.target.closest("[data-lv-click]");
    if (!target) return;
    var action = target.getAttribute("data-lv-click");
    var topic = findLiveView(target);
    if (topic && action) {
      maybeSend(target, function () {
        sendMsg(topic, [action]);
      });
    }
  });

  // ── Event delegation — submit ────────────────────────────────────

  document.addEventListener("submit", function (e) {
    var target = e.target.closest("[data-lv-submit]");
    if (!target) return;
    e.preventDefault();
    var action = target.getAttribute("data-lv-submit");
    var topic = findLiveView(target);
    if (!topic || !action) return;

    // Collect form data as JSON
    var formData = new FormData(target);
    var data = {};
    formData.forEach(function (value, key) {
      data[key] = value;
    });

    maybeSend(target, function () {
      sendMsg(topic, [action, data]);
    });

    // Clear inputs after submit
    var inputs = target.querySelectorAll(
      'input:not([type="hidden"]):not([type="submit"])'
    );
    inputs.forEach(function (input) {
      input.value = "";
    });
  });

  // ── Event delegation — input change ──────────────────────────────

  document.addEventListener("input", function (e) {
    var target = e.target.closest("[data-lv-change]");
    if (!target) return;
    var action = target.getAttribute("data-lv-change");
    var topic = findLiveView(target);
    if (topic && action) {
      maybeSend(e.target, function () {
        sendMsg(topic, [action, e.target.value]);
      });
    }
  });

  // ── Live Navigation ──────────────────────────────────────────────

  function navigateTo(url, replace) {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      // Fallback: regular navigation
      window.location.href = url;
      return;
    }
    // Leave all current topics
    liveViews.forEach(function (lv, topic) {
      ws.send(JSON.stringify({ type: "leave", topic: topic }));
    });
    ws.send(JSON.stringify({ type: "navigate", url: url, replace: !!replace }));
  }

  function applyNavigationHtml(html) {
    // Destroy all hook instances
    hookInstances.forEach(function (instance, el) {
      var name = el.getAttribute("data-lv-hook");
      var hookDef = hooks[name];
      if (hookDef && hookDef.destroyed) hookDef.destroyed.call(instance);
    });
    hookInstances.clear();

    // Clear old liveview registrations
    liveViews.clear();

    // Parse the HTML and extract <main> content if present
    var tmp = document.createElement("html");
    tmp.innerHTML = html;

    var newMain = tmp.querySelector("main");
    var oldMain = document.querySelector("main");

    if (newMain && oldMain) {
      oldMain.innerHTML = newMain.innerHTML;
      // Also update <title> if present
      var newTitle = tmp.querySelector("title");
      if (newTitle) document.title = newTitle.textContent;
    } else {
      // Replace entire body
      var newBody = tmp.querySelector("body");
      if (newBody) document.body.innerHTML = newBody.innerHTML;
    }

    // Discover and join new LiveViews
    discoverAndJoin();
  }

  function discoverAndJoin() {
    var elements = document.querySelectorAll("live-view");
    if (elements.length === 0) return;

    elements.forEach(function (el) {
      var endpoint = el.getAttribute("data-liveview");
      var topic = el.getAttribute("data-topic") || endpoint;
      var props = {};
      try {
        props = JSON.parse(el.getAttribute("data-props") || "{}");
      } catch (e) {
        // ignore
      }
      liveViews.set(topic, { el: el, endpoint: endpoint, props: props });
    });

    // Join new views
    if (ws && ws.readyState === WebSocket.OPEN) {
      liveViews.forEach(function (lv, topic) {
        lv.el.classList.add("lv-loading");
        ws.send(
          JSON.stringify({
            type: "join",
            topic: topic,
            endpoint: lv.endpoint,
            props: lv.props,
          })
        );
      });
    }
  }

  // Browser back/forward
  window.addEventListener("popstate", function (e) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      // Leave current topics
      liveViews.forEach(function (lv, topic) {
        ws.send(JSON.stringify({ type: "leave", topic: topic }));
      });
      ws.send(JSON.stringify({ type: "navigate", url: location.pathname + location.search }));
    } else {
      window.location.reload();
    }
  });

  // ── Initialize on DOMContentLoaded ───────────────────────────────

  document.addEventListener("DOMContentLoaded", function () {
    var elements = document.querySelectorAll("live-view");
    if (elements.length === 0) return;

    elements.forEach(function (el) {
      var endpoint = el.getAttribute("data-liveview");
      var topic =
        el.getAttribute("data-topic") || endpoint;
      var props = {};
      try {
        props = JSON.parse(el.getAttribute("data-props") || "{}");
      } catch (e) {
        // ignore
      }
      liveViews.set(topic, { el: el, endpoint: endpoint, props: props });
    });

    connect();
  });
})();
