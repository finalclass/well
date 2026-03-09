// static/well.ts
class Well {
  liveWs = null;
  liveReconnectDelay = 500;
  maxReconnectDelay = 1e4;
  liveViews = new Map;
  channelWs = null;
  channelReconnectDelay = 500;
  channels = new Map;
  channelConnected = false;
  static hooks = {};
  hookInstances = new Map;
  debounceTimers = new Map;
  throttleTimers = new Map;
  livePath;
  wsPath;
  constructor(opts) {
    this.livePath = opts?.livePath ?? "/live";
    this.wsPath = opts?.wsPath ?? "/ws";
  }
  debouncedSend(key, ms, fn) {
    const prev = this.debounceTimers.get(key);
    if (prev !== undefined)
      clearTimeout(prev);
    this.debounceTimers.set(key, setTimeout(fn, ms));
  }
  throttledSend(key, ms, fn) {
    const now = Date.now();
    if (now - (this.throttleTimers.get(key) ?? 0) >= ms) {
      this.throttleTimers.set(key, now);
      fn();
    }
  }
  maybeSend(el, fn) {
    const debounce = el.closest("[data-lv-debounce]");
    const throttle = el.closest("[data-lv-throttle]");
    if (debounce) {
      const ms = parseInt(debounce.getAttribute("data-lv-debounce") ?? "300", 10) || 300;
      const key = debounce.getAttribute("id") ?? debounce.getAttribute("data-lv-change") ?? "d";
      this.debouncedSend(key, ms, fn);
    } else if (throttle) {
      const ms = parseInt(throttle.getAttribute("data-lv-throttle") ?? "300", 10) || 300;
      const key = throttle.getAttribute("id") ?? throttle.getAttribute("data-lv-click") ?? "t";
      this.throttledSend(key, ms, fn);
    } else {
      fn();
    }
  }
  mountHooks(container) {
    const els = container.querySelectorAll("[data-lv-hook]");
    for (let i = 0;i < els.length; i++) {
      const el = els[i];
      if (this.hookInstances.has(el))
        continue;
      const name = el.getAttribute("data-lv-hook");
      if (!name)
        continue;
      const hookDef = Well.hooks[name];
      if (!hookDef)
        continue;
      const topic = this.findLiveView(el);
      const self = this;
      const instance = {
        el,
        _topic: topic,
        _handlers: {},
        pushEvent(event, payload) {
          if (this._topic) {
            self.sendLiveMsg(this._topic, ["HookEvent", { event, payload }]);
          }
        },
        handleEvent(event, cb) {
          if (!this._handlers[event])
            this._handlers[event] = [];
          this._handlers[event].push(cb);
        }
      };
      this.hookInstances.set(el, instance);
      if (hookDef.mounted)
        hookDef.mounted.call(instance);
    }
  }
  updateHooks(container) {
    this.hookInstances.forEach((instance, el) => {
      if (!container.contains(el)) {
        const name = el.getAttribute("data-lv-hook");
        if (name) {
          const hookDef = Well.hooks[name];
          if (hookDef?.destroyed)
            hookDef.destroyed.call(instance);
        }
        this.hookInstances.delete(el);
      }
    });
    this.hookInstances.forEach((instance, el) => {
      if (container.contains(el)) {
        const name = el.getAttribute("data-lv-hook");
        if (name) {
          const hookDef = Well.hooks[name];
          if (hookDef?.updated)
            hookDef.updated.call(instance);
        }
      }
    });
    this.mountHooks(container);
  }
  dispatchHookEvent(topic, event, payload) {
    this.hookInstances.forEach((instance) => {
      if (instance._topic === topic && instance._handlers[event]) {
        instance._handlers[event].forEach((cb) => cb(payload));
      }
    });
  }
  morph(container, newHtml) {
    const template = document.createElement("template");
    template.innerHTML = newHtml;
    const newRoot = template.content;
    this.morphChildren(container, newRoot);
  }
  morphChildren(oldParent, newParent) {
    const oldChildren = Array.from(oldParent.childNodes);
    const newChildren = Array.from(newParent.childNodes);
    const oldKeyed = new Map;
    for (const child of oldChildren) {
      if (child.nodeType === Node.ELEMENT_NODE) {
        const el = child;
        const key = el.getAttribute("data-lv-key") ?? el.getAttribute("id");
        if (key)
          oldKeyed.set(key, el);
      }
    }
    let oldIdx = 0;
    for (let newIdx = 0;newIdx < newChildren.length; newIdx++) {
      const newChild = newChildren[newIdx];
      if (newChild.nodeType === Node.TEXT_NODE) {
        if (oldIdx < oldChildren.length && oldChildren[oldIdx].nodeType === Node.TEXT_NODE) {
          if (oldChildren[oldIdx].textContent !== newChild.textContent) {
            oldChildren[oldIdx].textContent = newChild.textContent;
          }
          oldIdx++;
        } else {
          oldParent.insertBefore(document.createTextNode(newChild.textContent ?? ""), oldChildren[oldIdx] ?? null);
        }
        continue;
      }
      if (newChild.nodeType !== Node.ELEMENT_NODE) {
        oldIdx++;
        continue;
      }
      const newEl = newChild;
      const newKey = newEl.getAttribute("data-lv-key") ?? newEl.getAttribute("id");
      let match = null;
      if (newKey && oldKeyed.has(newKey)) {
        match = oldKeyed.get(newKey);
        oldKeyed.delete(newKey);
        const ref = oldChildren[oldIdx] ?? null;
        if (match !== ref) {
          oldParent.insertBefore(match, ref);
        } else {
          oldIdx++;
        }
      } else if (oldIdx < oldChildren.length) {
        const oldChild = oldChildren[oldIdx];
        if (oldChild.nodeType === Node.ELEMENT_NODE) {
          const oldEl = oldChild;
          const oldKey = oldEl.getAttribute("data-lv-key") ?? oldEl.getAttribute("id");
          if (!oldKey && oldEl.tagName === newEl.tagName) {
            match = oldEl;
            oldIdx++;
          }
        }
        if (!match) {
          oldParent.insertBefore(newEl.cloneNode(true), oldChildren[oldIdx] ?? null);
          continue;
        }
      }
      if (!match) {
        oldParent.appendChild(newEl.cloneNode(true));
        continue;
      }
      if (match.hasAttribute("data-lv-ignore"))
        continue;
      this.syncAttrs(match, newEl);
      const active = document.activeElement;
      if (match === active && this.isFormInput(match)) {} else if (this.isFormInput(match) && this.isFormInput(newEl)) {
        match.value = newEl.value;
      } else {
        this.morphChildren(match, newEl);
      }
    }
    const currentChildren = Array.from(oldParent.childNodes);
    for (let i = newChildren.length;i < currentChildren.length; i++) {}
    while (oldParent.childNodes.length > newChildren.length) {
      const last = oldParent.lastChild;
      if (last)
        oldParent.removeChild(last);
      else
        break;
    }
  }
  syncAttrs(oldEl, newEl) {
    const oldAttrs = Array.from(oldEl.attributes);
    for (const attr of oldAttrs) {
      if (!newEl.hasAttribute(attr.name)) {
        oldEl.removeAttribute(attr.name);
      }
    }
    const newAttrs = Array.from(newEl.attributes);
    for (const attr of newAttrs) {
      if (oldEl.getAttribute(attr.name) !== attr.value) {
        oldEl.setAttribute(attr.name, attr.value);
      }
    }
  }
  isFormInput(el) {
    const tag = el.tagName;
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
  }
  findLiveView(el) {
    let node = el;
    while (node) {
      if (node.tagName === "LIVE-VIEW") {
        return node.getAttribute("data-topic") ?? node.getAttribute("data-liveview");
      }
      node = node.parentElement;
    }
    return null;
  }
  sendLiveMsg(topic, msg) {
    if (this.liveWs?.readyState === WebSocket.OPEN) {
      this.liveWs.send(JSON.stringify({ type: "msg", topic, msg }));
    }
  }
  parseQueryParams(search) {
    const params = {};
    if (!search || search.length <= 1)
      return params;
    const qs = search.charAt(0) === "?" ? search.substring(1) : search;
    const pairs = qs.split("&");
    for (const pair of pairs) {
      const [k, v] = pair.split("=");
      if (k)
        params[decodeURIComponent(k)] = v ? decodeURIComponent(v) : "";
    }
    return params;
  }
  connectLive() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = `${proto}//${location.host}${this.livePath}`;
    const preWs = window.__wellPreWs;
    delete window.__wellPreWs;
    if (preWs && (preWs.readyState === WebSocket.CONNECTING || preWs.readyState === WebSocket.OPEN)) {
      this.liveWs = preWs;
    } else {
      this.liveWs = new WebSocket(url);
    }
    const onOpen = () => {
      console.log("[well] WS open", performance.now().toFixed(0) + "ms");
      this.liveReconnectDelay = 500;
      const queryParams = this.parseQueryParams(location.search);
      this.liveViews.forEach((lv, topic) => {
        lv.el.classList.add("lv-loading");
        const joinProps = { ...lv.props, _query: queryParams };
        console.log("[well] sending join for", topic);
        this.liveWs.send(JSON.stringify({
          type: "join",
          topic,
          endpoint: lv.endpoint,
          props: joinProps
        }));
      });
    };
    if (this.liveWs.readyState === WebSocket.OPEN) {
      onOpen();
    } else {
      this.liveWs.onopen = onOpen;
    }
    this.liveWs.onmessage = (event) => {
      let msg;
      try {
        msg = JSON.parse(event.data);
      } catch {
        return;
      }
      const topic = msg.topic;
      const lv = this.liveViews.get(topic);
      switch (msg.type) {
        case "full":
        case "restored":
          console.log("[well]", msg.type, "received for", topic, performance.now().toFixed(0) + "ms");
          if (lv) {
            const html = msg.html;
            lv.cachedHtml = html;
            lv.el.innerHTML = html;
            lv.el.classList.remove("lv-loading");
            this.mountHooks(lv.el);
          }
          break;
        case "morph":
          if (!lv)
            break;
          {
            const patches = msg.patches;
            let html = lv.cachedHtml;
            for (let i = patches.length - 1;i >= 0; i--) {
              const [offset, len, content] = patches[i];
              html = html.substring(0, offset) + content + html.substring(offset + len);
            }
            lv.cachedHtml = html;
            this.morph(lv.el, html);
            this.updateHooks(lv.el);
          }
          break;
        case "patch":
          if (!lv)
            break;
          if (msg.changes) {
            const changes = msg.changes;
            for (const id of Object.keys(changes)) {
              const el = lv.el.querySelector(`[data-lv="${id}"]`);
              if (el)
                el.innerHTML = changes[id];
            }
          }
          if (msg.list_ops) {
            const listOps = msg.list_ops;
            for (const listId of Object.keys(listOps)) {
              const ops = listOps[listId];
              const container = lv.el.querySelector(`[data-lv-each="${listId}"]`);
              if (!container)
                continue;
              const existing = new Map;
              for (let j = 0;j < container.children.length; j++) {
                const key = container.children[j].getAttribute("data-lv-key");
                if (key)
                  existing.set(key, container.children[j]);
              }
              if (ops.inserts) {
                for (const [ikey, html] of Object.entries(ops.inserts)) {
                  const tmp = document.createElement("div");
                  tmp.innerHTML = html;
                  const newEl = tmp.firstElementChild;
                  if (newEl)
                    existing.set(ikey, newEl);
                }
              }
              if (ops.order) {
                while (container.firstChild)
                  container.removeChild(container.firstChild);
                for (const okey of ops.order) {
                  const oel = existing.get(okey);
                  if (oel)
                    container.appendChild(oel);
                }
              }
            }
          }
          this.updateHooks(lv.el);
          break;
        case "event":
          if (msg.event) {
            this.dispatchHookEvent(topic, msg.event, msg.payload ?? null);
          }
          break;
        case "navigate":
          if (msg.url && msg.html) {
            history.pushState({ wellNav: true }, "", msg.url);
            this.applyNavigationHtml(msg.html);
          }
          break;
      }
    };
    this.liveWs.onclose = (ev) => {
      console.log("[well] WS closed", ev.code, ev.reason, performance.now().toFixed(0) + "ms");
      this.liveViews.forEach((lv) => lv.el.classList.add("lv-loading"));
      setTimeout(() => {
        this.liveReconnectDelay = Math.min(this.liveReconnectDelay * 2, this.maxReconnectDelay);
        this.connectLive();
      }, this.liveReconnectDelay);
    };
    this.liveWs.onerror = () => this.liveWs?.close();
  }
  patchParams(url) {
    if (!this.liveWs || this.liveWs.readyState !== WebSocket.OPEN) {
      window.location.href = url;
      return;
    }
    history.replaceState({ wellNav: true }, "", url);
    const qmark = url.indexOf("?");
    const params = qmark >= 0 ? this.parseQueryParams(url.substring(qmark)) : {};
    this.liveViews.forEach((_lv, topic) => {
      this.liveWs.send(JSON.stringify({ type: "params", topic, params }));
    });
  }
  navigateTo(url) {
    if (!this.liveWs || this.liveWs.readyState !== WebSocket.OPEN) {
      window.location.href = url;
      return;
    }
    this.liveViews.forEach((_lv, topic) => {
      this.liveWs.send(JSON.stringify({ type: "leave", topic }));
    });
    this.liveWs.send(JSON.stringify({ type: "navigate", url }));
  }
  applyNavigationHtml(html) {
    this.hookInstances.forEach((instance, el) => {
      const name = el.getAttribute("data-lv-hook");
      if (name) {
        const hookDef = Well.hooks[name];
        if (hookDef?.destroyed)
          hookDef.destroyed.call(instance);
      }
    });
    this.hookInstances.clear();
    this.liveViews.clear();
    const tmp = document.createElement("html");
    tmp.innerHTML = html;
    const newMain = tmp.querySelector("main");
    const oldMain = document.querySelector("main");
    if (newMain && oldMain) {
      oldMain.innerHTML = newMain.innerHTML;
      const newTitle = tmp.querySelector("title");
      if (newTitle)
        document.title = newTitle.textContent ?? "";
    } else {
      const newBody = tmp.querySelector("body");
      if (newBody)
        document.body.innerHTML = newBody.innerHTML;
    }
    this.discoverAndJoin();
  }
  discoverAndJoin() {
    const elements = document.querySelectorAll("live-view");
    if (elements.length === 0)
      return;
    elements.forEach((el) => {
      const endpoint = el.getAttribute("data-liveview") ?? "";
      const topic = el.getAttribute("data-topic") ?? endpoint;
      let props = {};
      try {
        props = JSON.parse(el.getAttribute("data-props") ?? "{}");
      } catch {}
      this.liveViews.set(topic, { el, endpoint, props });
    });
    if (this.liveWs?.readyState === WebSocket.OPEN) {
      const queryParams = this.parseQueryParams(location.search);
      this.liveViews.forEach((lv, topic) => {
        lv.el.classList.add("lv-loading");
        const joinProps = { ...lv.props, _query: queryParams };
        this.liveWs.send(JSON.stringify({
          type: "join",
          topic,
          endpoint: lv.endpoint,
          props: joinProps
        }));
      });
    }
  }
  uploadFile(topic, file) {
    const CHUNK_SIZE = 64 * 1024;
    const uploadId = Math.random().toString(36).substring(2) + Date.now().toString(36);
    const chunkCount = Math.ceil(file.size / CHUNK_SIZE);
    let chunkIndex = 0;
    const sendChunk = () => {
      if (chunkIndex >= chunkCount)
        return;
      const start = chunkIndex * CHUNK_SIZE;
      const end = Math.min(start + CHUNK_SIZE, file.size);
      const slice = file.slice(start, end);
      const reader = new FileReader;
      reader.onload = () => {
        const base64 = reader.result.split(",")[1] ?? "";
        if (this.liveWs?.readyState === WebSocket.OPEN) {
          this.liveWs.send(JSON.stringify({
            type: "upload",
            topic,
            upload_id: uploadId,
            filename: file.name,
            content_type: file.type || "application/octet-stream",
            size: file.size,
            chunk_index: chunkIndex,
            chunk_count: chunkCount,
            chunk_data: base64
          }));
        }
        chunkIndex++;
        sendChunk();
      };
      reader.readAsDataURL(slice);
    };
    sendChunk();
  }
  setupEventDelegation() {
    document.addEventListener("click", (e) => {
      const target = e.target;
      const navTarget = target.closest("[data-lv-navigate]");
      if (navTarget) {
        e.preventDefault();
        const url = navTarget.getAttribute("href") ?? navTarget.getAttribute("data-lv-navigate") ?? "";
        if (url)
          this.navigateTo(url);
        return;
      }
      const patchTarget = target.closest("[data-lv-patch]");
      if (patchTarget) {
        e.preventDefault();
        const patchUrl = patchTarget.getAttribute("href") ?? patchTarget.getAttribute("data-lv-patch") ?? "";
        if (patchUrl)
          this.patchParams(patchUrl);
        return;
      }
      const clickTarget = target.closest("[data-lv-click]");
      if (!clickTarget)
        return;
      const confirmMsg = clickTarget.getAttribute("data-lv-confirm");
      if (confirmMsg && !window.confirm(confirmMsg))
        return;
      const action = clickTarget.getAttribute("data-lv-click");
      const topic = this.findLiveView(clickTarget);
      if (topic && action) {
        let msg;
        try {
          const parsed = JSON.parse(action);
          msg = Array.isArray(parsed) ? parsed : [action];
        } catch {
          msg = [action];
        }
        this.maybeSend(clickTarget, () => this.sendLiveMsg(topic, msg));
      }
    });
    document.addEventListener("submit", (e) => {
      const form = e.target.closest("[data-lv-submit]");
      if (!form)
        return;
      e.preventDefault();
      const action = form.getAttribute("data-lv-submit");
      const topic = this.findLiveView(form);
      if (!topic || !action)
        return;
      const formData = new FormData(form);
      const data = {};
      formData.forEach((value, key) => {
        data[key] = value;
      });
      this.maybeSend(form, () => this.sendLiveMsg(topic, [action, data]));
      form.querySelectorAll('input:not([type="hidden"]):not([type="submit"])').forEach((input) => {
        input.value = "";
      });
    });
    document.addEventListener("input", (e) => {
      const target = e.target.closest("[data-lv-change]");
      if (!target)
        return;
      const action = target.getAttribute("data-lv-change");
      const topic = this.findLiveView(target);
      if (topic && action) {
        this.maybeSend(e.target, () => {
          this.sendLiveMsg(topic, [action, e.target.value]);
        });
      }
    });
    window.addEventListener("popstate", () => {
      if (this.liveWs?.readyState === WebSocket.OPEN) {
        this.liveViews.forEach((_lv, topic) => {
          this.liveWs.send(JSON.stringify({ type: "leave", topic }));
        });
        this.liveWs.send(JSON.stringify({ type: "navigate", url: location.pathname + location.search }));
      } else {
        window.location.reload();
      }
    });
  }
  pushLive(msg, topic) {
    const t = topic ?? this.liveViews.keys().next().value;
    if (t)
      this.sendLiveMsg(t, msg);
  }
  channel(topic) {
    if (!this.channelWs || this.channelWs.readyState !== WebSocket.OPEN) {
      this.connectChannel();
    }
    const ch = new ChannelInstance(topic, this);
    this.channels.set(topic, ch);
    if (this.channelConnected)
      ch._join();
    return ch;
  }
  _sendChannel(data) {
    if (this.channelWs?.readyState === WebSocket.OPEN) {
      this.channelWs.send(JSON.stringify(data));
    }
  }
  _removeChannel(topic) {
    this.channels.delete(topic);
  }
  connectChannel() {
    if (this.channelWs && this.channelWs.readyState <= WebSocket.OPEN)
      return;
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = `${proto}//${location.host}${this.wsPath}`;
    this.channelWs = new WebSocket(url);
    this.channelWs.onopen = () => {
      this.channelReconnectDelay = 500;
      this.channelConnected = true;
      this.channels.forEach((ch) => ch._join());
    };
    this.channelWs.onmessage = (event) => {
      let msg;
      try {
        msg = JSON.parse(event.data);
      } catch {
        return;
      }
      const ch = msg.channel;
      const type = msg.type;
      const channel = this.channels.get(ch);
      if (type === "event" && channel) {
        const eventName = msg.event ?? "message";
        channel._dispatch(eventName, msg.payload);
      }
    };
    this.channelWs.onclose = () => {
      this.channelConnected = false;
      if (this.channels.size > 0) {
        setTimeout(() => {
          this.channelReconnectDelay = Math.min(this.channelReconnectDelay * 2, this.maxReconnectDelay);
          this.connectChannel();
        }, this.channelReconnectDelay);
      }
    };
    this.channelWs.onerror = () => this.channelWs?.close();
  }
  connect() {
    this.setupEventDelegation();
    const self = this;
    Well.hooks.FileUpload = {
      mounted() {
        const input = this.el.querySelector('input[type="file"]') ?? this.el;
        if (input.tagName !== "INPUT")
          return;
        const hookTopic = this._topic;
        input.addEventListener("change", (e) => {
          const files = e.target.files;
          if (!files || !hookTopic)
            return;
          for (let i = 0;i < files.length; i++) {
            self.uploadFile(hookTopic, files[i]);
          }
        });
      }
    };
    const discoverAndConnect = () => {
      console.log("[well] discover LiveViews", performance.now().toFixed(0) + "ms");
      const elements = document.querySelectorAll("live-view");
      if (elements.length === 0)
        return;
      elements.forEach((el) => {
        const endpoint = el.getAttribute("data-liveview") ?? "";
        const topic = el.getAttribute("data-topic") ?? endpoint;
        let props = {};
        try {
          props = JSON.parse(el.getAttribute("data-props") ?? "{}");
        } catch {}
        this.liveViews.set(topic, { el, endpoint, props, cachedHtml: "" });
      });
      console.log("[well] connectLive() called, liveViews:", this.liveViews.size);
      this.connectLive();
    };
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", discoverAndConnect);
    } else {
      discoverAndConnect();
    }
  }
}

class ChannelInstance {
  topic;
  well;
  listeners = new Map;
  joined = false;
  constructor(topic, well) {
    this.topic = topic;
    this.well = well;
  }
  on(event, cb) {
    const cbs = this.listeners.get(event) ?? [];
    cbs.push(cb);
    this.listeners.set(event, cbs);
    return this;
  }
  push(event, payload) {
    this.well._sendChannel({ type: "push", channel: this.topic, event, payload: payload ?? null });
  }
  leave() {
    this.well._sendChannel({ type: "leave", channel: this.topic });
    this.well._removeChannel(this.topic);
    this.joined = false;
  }
  _join() {
    if (this.joined)
      return;
    this.joined = true;
    this.well._sendChannel({ type: "join", channel: this.topic });
  }
  _dispatch(event, payload) {
    const cbs = this.listeners.get(event);
    if (cbs)
      cbs.forEach((cb) => cb(payload));
    const wildcardCbs = this.listeners.get("*");
    if (wildcardCbs)
      wildcardCbs.forEach((cb) => cb(payload));
  }
}
console.log("[well] module loaded", performance.now().toFixed(0) + "ms");
var well = new Well;
well.connect();
window.Well = Well;
window.well = well;
export {
  Well
};
