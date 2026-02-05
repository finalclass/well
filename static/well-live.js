// well-live.js — LiveView client
// Handles WebSocket connection, DOM patching, and event delegation

(function () {
  "use strict";

  let ws = null;
  let reconnectDelay = 500;
  const maxReconnectDelay = 10000;
  const liveViews = new Map(); // topic -> { el, endpoint, props }

  function connect() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = proto + "//" + location.host + "/live";
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
      let msg;
      try {
        msg = JSON.parse(event.data);
      } catch (e) {
        return;
      }

      const topic = msg.topic;
      const lv = liveViews.get(topic);
      if (!lv) return;

      switch (msg.type) {
        case "full":
        case "restored":
          lv.el.innerHTML = msg.html;
          lv.el.classList.remove("lv-loading");
          break;

        case "patch":
          // Apply text changes
          if (msg.changes) {
            const keys = Object.keys(msg.changes);
            for (let i = 0; i < keys.length; i++) {
              const id = keys[i];
              const el = lv.el.querySelector('[data-lv="' + id + '"]');
              if (el) {
                el.textContent = msg.changes[id];
              }
            }
          }
          // Apply list operations
          if (msg.list_ops) {
            const listIds = Object.keys(msg.list_ops);
            for (let i = 0; i < listIds.length; i++) {
              const listId = listIds[i];
              const ops = msg.list_ops[listId];
              const container = lv.el.querySelector(
                '[data-lv-each="' + listId + '"]'
              );
              if (!container) continue;

              // Build map of existing keyed children
              const existing = new Map();
              const children = container.children;
              for (let j = 0; j < children.length; j++) {
                const key = children[j].getAttribute("data-lv-key");
                if (key) existing.set(key, children[j]);
              }

              // Process inserts (new or updated items)
              if (ops.inserts) {
                const insertKeys = Object.keys(ops.inserts);
                for (let j = 0; j < insertKeys.length; j++) {
                  const key = insertKeys[j];
                  const html = ops.inserts[key];
                  const tmp = document.createElement("div");
                  tmp.innerHTML = html;
                  const newEl = tmp.firstElementChild;
                  if (newEl) {
                    existing.set(key, newEl);
                  }
                }
              }

              // Reorder according to ops.order
              if (ops.order) {
                // Clear container
                while (container.firstChild) {
                  container.removeChild(container.firstChild);
                }
                // Append in order
                for (let j = 0; j < ops.order.length; j++) {
                  const key = ops.order[j];
                  const el = existing.get(key);
                  if (el) container.appendChild(el);
                }
              }
            }
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
    let node = el;
    while (node) {
      if (node.tagName === "LIVE-VIEW") {
        const topic =
          node.getAttribute("data-topic") ||
          node.getAttribute("data-liveview");
        return topic;
      }
      node = node.parentElement;
    }
    return null;
  }

  // Event delegation — click
  document.addEventListener("click", function (e) {
    const target = e.target.closest("[data-lv-click]");
    if (!target) return;
    const action = target.getAttribute("data-lv-click");
    const topic = findLiveView(target);
    if (topic && action) {
      sendMsg(topic, [action]);
    }
  });

  // Event delegation — submit
  document.addEventListener("submit", function (e) {
    const target = e.target.closest("[data-lv-submit]");
    if (!target) return;
    e.preventDefault();
    const action = target.getAttribute("data-lv-submit");
    const topic = findLiveView(target);
    if (!topic || !action) return;

    // Collect form data as JSON
    const formData = new FormData(target);
    const data = {};
    formData.forEach(function (value, key) {
      data[key] = value;
    });

    sendMsg(topic, [action, data]);

    // Clear inputs after submit
    const inputs = target.querySelectorAll(
      'input:not([type="hidden"]):not([type="submit"])'
    );
    inputs.forEach(function (input) {
      input.value = "";
    });
  });

  // Event delegation — input change
  document.addEventListener("input", function (e) {
    const target = e.target.closest("[data-lv-change]");
    if (!target) return;
    const action = target.getAttribute("data-lv-change");
    const topic = findLiveView(target);
    if (topic && action) {
      sendMsg(topic, [action, e.target.value]);
    }
  });

  // Initialize on DOMContentLoaded
  document.addEventListener("DOMContentLoaded", function () {
    const elements = document.querySelectorAll("live-view");
    if (elements.length === 0) return;

    elements.forEach(function (el) {
      const endpoint = el.getAttribute("data-liveview");
      const topic =
        el.getAttribute("data-topic") || endpoint;
      let props = {};
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
