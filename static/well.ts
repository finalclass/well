// well.ts — Unified client for LiveView + Channels
// Replaces well-live.js with full TypeScript types

// ── Types ──────────────────────────────────────────────────────────

export interface HookDef {
  mounted?: (this: HookInstance) => void;
  updated?: (this: HookInstance) => void;
  destroyed?: (this: HookInstance) => void;
}

export interface HookInstance {
  el: Element;
  _topic: string | null;
  _handlers: Record<string, ((payload: unknown) => void)[]>;
  pushEvent(event: string, payload?: unknown): void;
  handleEvent(event: string, cb: (payload: unknown) => void): void;
}

export interface WellChannel {
  on(event: string, cb: (payload: unknown) => void): WellChannel;
  push(event: string, payload?: unknown): void;
  leave(): void;
}

// ── Well client ────────────────────────────────────────────────────

export class Well {
  // ── LiveView state ──
  private liveWs: WebSocket | null = null;
  private liveReconnectDelay = 500;
  private readonly maxReconnectDelay = 10000;
  private readonly liveViews = new Map<string, { el: Element; endpoint: string; props: Record<string, unknown> }>();

  // ── Channel state ──
  private channelWs: WebSocket | null = null;
  private channelReconnectDelay = 500;
  private readonly channels = new Map<string, ChannelInstance>();
  private channelConnected = false;

  // ── Hooks ──
  static hooks: Record<string, HookDef> = {};
  private hookInstances = new Map<Element, HookInstance>();

  // ── Debounce / Throttle ──
  private debounceTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private throttleTimers = new Map<string, number>();

  // ── Options ──
  private livePath: string;
  private wsPath: string;

  constructor(opts?: { livePath?: string; wsPath?: string }) {
    this.livePath = opts?.livePath ?? "/live";
    this.wsPath = opts?.wsPath ?? "/ws";
  }

  // ── Debounce / Throttle helpers ──────────────────────────────────

  private debouncedSend(key: string, ms: number, fn: () => void) {
    const prev = this.debounceTimers.get(key);
    if (prev !== undefined) clearTimeout(prev);
    this.debounceTimers.set(key, setTimeout(fn, ms));
  }

  private throttledSend(key: string, ms: number, fn: () => void) {
    const now = Date.now();
    if (now - (this.throttleTimers.get(key) ?? 0) >= ms) {
      this.throttleTimers.set(key, now);
      fn();
    }
  }

  private maybeSend(el: Element, fn: () => void) {
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

  // ── Hooks ────────────────────────────────────────────────────────

  private mountHooks(container: Element) {
    const els = container.querySelectorAll("[data-lv-hook]");
    for (let i = 0; i < els.length; i++) {
      const el = els[i];
      if (this.hookInstances.has(el)) continue;
      const name = el.getAttribute("data-lv-hook");
      if (!name) continue;
      const hookDef = Well.hooks[name];
      if (!hookDef) continue;
      const topic = this.findLiveView(el);
      const self = this;
      const instance: HookInstance = {
        el,
        _topic: topic,
        _handlers: {},
        pushEvent(event: string, payload?: unknown) {
          if (this._topic) {
            self.sendLiveMsg(this._topic, ["HookEvent", { event, payload }]);
          }
        },
        handleEvent(event: string, cb: (payload: unknown) => void) {
          if (!this._handlers[event]) this._handlers[event] = [];
          this._handlers[event].push(cb);
        },
      };
      this.hookInstances.set(el, instance);
      if (hookDef.mounted) hookDef.mounted.call(instance);
    }
  }

  private updateHooks(container: Element) {
    this.hookInstances.forEach((instance, el) => {
      if (!container.contains(el)) {
        const name = el.getAttribute("data-lv-hook");
        if (name) {
          const hookDef = Well.hooks[name];
          if (hookDef?.destroyed) hookDef.destroyed.call(instance);
        }
        this.hookInstances.delete(el);
      }
    });
    this.hookInstances.forEach((instance, el) => {
      if (container.contains(el)) {
        const name = el.getAttribute("data-lv-hook");
        if (name) {
          const hookDef = Well.hooks[name];
          if (hookDef?.updated) hookDef.updated.call(instance);
        }
      }
    });
    this.mountHooks(container);
  }

  private dispatchHookEvent(topic: string, event: string, payload: unknown) {
    this.hookInstances.forEach((instance) => {
      if (instance._topic === topic && instance._handlers[event]) {
        instance._handlers[event].forEach((cb) => cb(payload));
      }
    });
  }

  // ── LiveView helpers ─────────────────────────────────────────────

  private findLiveView(el: Element): string | null {
    let node: Element | null = el;
    while (node) {
      if (node.tagName === "LIVE-VIEW") {
        return node.getAttribute("data-topic") ?? node.getAttribute("data-liveview");
      }
      node = node.parentElement;
    }
    return null;
  }

  private sendLiveMsg(topic: string, msg: unknown) {
    if (this.liveWs?.readyState === WebSocket.OPEN) {
      this.liveWs.send(JSON.stringify({ type: "msg", topic, msg }));
    }
  }

  private parseQueryParams(search: string): Record<string, string> {
    const params: Record<string, string> = {};
    if (!search || search.length <= 1) return params;
    const qs = search.charAt(0) === "?" ? search.substring(1) : search;
    const pairs = qs.split("&");
    for (const pair of pairs) {
      const [k, v] = pair.split("=");
      if (k) params[decodeURIComponent(k)] = v ? decodeURIComponent(v) : "";
    }
    return params;
  }

  // ── LiveView connection ──────────────────────────────────────────

  private connectLive() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = `${proto}//${location.host}${this.livePath}`;
    this.liveWs = new WebSocket(url);

    this.liveWs.onopen = () => {
      this.liveReconnectDelay = 500;
      const queryParams = this.parseQueryParams(location.search);
      this.liveViews.forEach((lv, topic) => {
        lv.el.classList.add("lv-loading");
        const joinProps = { ...lv.props, _query: queryParams };
        this.liveWs!.send(JSON.stringify({
          type: "join", topic, endpoint: lv.endpoint, props: joinProps,
        }));
      });
    };

    this.liveWs.onmessage = (event: MessageEvent) => {
      let msg: Record<string, unknown>;
      try { msg = JSON.parse(event.data as string); } catch { return; }

      const topic = msg.topic as string;
      const lv = this.liveViews.get(topic);

      switch (msg.type) {
        case "full":
        case "restored":
          if (lv) {
            lv.el.innerHTML = msg.html as string;
            lv.el.classList.remove("lv-loading");
            this.mountHooks(lv.el);
          }
          break;

        case "patch":
          if (!lv) break;
          if (msg.changes) {
            const changes = msg.changes as Record<string, string>;
            for (const id of Object.keys(changes)) {
              const el = lv.el.querySelector(`[data-lv="${id}"]`);
              if (el) el.innerHTML = changes[id];
            }
          }
          if (msg.list_ops) {
            const listOps = msg.list_ops as Record<string, { order?: string[]; inserts?: Record<string, string> }>;
            for (const listId of Object.keys(listOps)) {
              const ops = listOps[listId];
              const container = lv.el.querySelector(`[data-lv-each="${listId}"]`);
              if (!container) continue;
              const existing = new Map<string, Element>();
              for (let j = 0; j < container.children.length; j++) {
                const key = container.children[j].getAttribute("data-lv-key");
                if (key) existing.set(key, container.children[j]);
              }
              if (ops.inserts) {
                for (const [ikey, html] of Object.entries(ops.inserts)) {
                  const tmp = document.createElement("div");
                  tmp.innerHTML = html;
                  const newEl = tmp.firstElementChild;
                  if (newEl) existing.set(ikey, newEl);
                }
              }
              if (ops.order) {
                while (container.firstChild) container.removeChild(container.firstChild);
                for (const okey of ops.order) {
                  const oel = existing.get(okey);
                  if (oel) container.appendChild(oel);
                }
              }
            }
          }
          this.updateHooks(lv.el);
          break;

        case "event":
          if (msg.event) {
            this.dispatchHookEvent(topic, msg.event as string, msg.payload ?? null);
          }
          break;

        case "navigate":
          if (msg.url && msg.html) {
            history.pushState({ wellNav: true }, "", msg.url as string);
            this.applyNavigationHtml(msg.html as string);
          }
          break;
      }
    };

    this.liveWs.onclose = () => {
      this.liveViews.forEach((lv) => lv.el.classList.add("lv-loading"));
      setTimeout(() => {
        this.liveReconnectDelay = Math.min(this.liveReconnectDelay * 2, this.maxReconnectDelay);
        this.connectLive();
      }, this.liveReconnectDelay);
    };

    this.liveWs.onerror = () => this.liveWs?.close();
  }

  // ── LiveView navigation ──────────────────────────────────────────

  private patchParams(url: string) {
    if (!this.liveWs || this.liveWs.readyState !== WebSocket.OPEN) {
      window.location.href = url;
      return;
    }
    history.replaceState({ wellNav: true }, "", url);
    const qmark = url.indexOf("?");
    const params = qmark >= 0 ? this.parseQueryParams(url.substring(qmark)) : {};
    this.liveViews.forEach((_lv, topic) => {
      this.liveWs!.send(JSON.stringify({ type: "params", topic, params }));
    });
  }

  private navigateTo(url: string) {
    if (!this.liveWs || this.liveWs.readyState !== WebSocket.OPEN) {
      window.location.href = url;
      return;
    }
    this.liveViews.forEach((_lv, topic) => {
      this.liveWs!.send(JSON.stringify({ type: "leave", topic }));
    });
    this.liveWs.send(JSON.stringify({ type: "navigate", url }));
  }

  private applyNavigationHtml(html: string) {
    this.hookInstances.forEach((instance, el) => {
      const name = el.getAttribute("data-lv-hook");
      if (name) {
        const hookDef = Well.hooks[name];
        if (hookDef?.destroyed) hookDef.destroyed.call(instance);
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
      if (newTitle) document.title = newTitle.textContent ?? "";
    } else {
      const newBody = tmp.querySelector("body");
      if (newBody) document.body.innerHTML = newBody.innerHTML;
    }
    this.discoverAndJoin();
  }

  private discoverAndJoin() {
    const elements = document.querySelectorAll("live-view");
    if (elements.length === 0) return;

    elements.forEach((el) => {
      const endpoint = el.getAttribute("data-liveview") ?? "";
      const topic = el.getAttribute("data-topic") ?? endpoint;
      let props: Record<string, unknown> = {};
      try { props = JSON.parse(el.getAttribute("data-props") ?? "{}"); } catch { /* ignore */ }
      this.liveViews.set(topic, { el, endpoint, props });
    });

    if (this.liveWs?.readyState === WebSocket.OPEN) {
      const queryParams = this.parseQueryParams(location.search);
      this.liveViews.forEach((lv, topic) => {
        lv.el.classList.add("lv-loading");
        const joinProps = { ...lv.props, _query: queryParams };
        this.liveWs!.send(JSON.stringify({
          type: "join", topic, endpoint: lv.endpoint, props: joinProps,
        }));
      });
    }
  }

  // ── File Upload ──────────────────────────────────────────────────

  private uploadFile(topic: string, file: File) {
    const CHUNK_SIZE = 64 * 1024;
    const uploadId = Math.random().toString(36).substring(2) + Date.now().toString(36);
    const chunkCount = Math.ceil(file.size / CHUNK_SIZE);
    let chunkIndex = 0;

    const sendChunk = () => {
      if (chunkIndex >= chunkCount) return;
      const start = chunkIndex * CHUNK_SIZE;
      const end = Math.min(start + CHUNK_SIZE, file.size);
      const slice = file.slice(start, end);
      const reader = new FileReader();
      reader.onload = () => {
        const base64 = (reader.result as string).split(",")[1] ?? "";
        if (this.liveWs?.readyState === WebSocket.OPEN) {
          this.liveWs.send(JSON.stringify({
            type: "upload", topic, upload_id: uploadId,
            filename: file.name, content_type: file.type || "application/octet-stream",
            size: file.size, chunk_index: chunkIndex, chunk_count: chunkCount,
            chunk_data: base64,
          }));
        }
        chunkIndex++;
        sendChunk();
      };
      reader.readAsDataURL(slice);
    };
    sendChunk();
  }

  // ── Event delegation ─────────────────────────────────────────────

  private setupEventDelegation() {
    document.addEventListener("click", (e: MouseEvent) => {
      const target = e.target as Element;

      // Live navigation
      const navTarget = target.closest("[data-lv-navigate]");
      if (navTarget) {
        e.preventDefault();
        const url = navTarget.getAttribute("href") ?? navTarget.getAttribute("data-lv-navigate") ?? "";
        if (url) this.navigateTo(url);
        return;
      }

      // Patch navigation
      const patchTarget = target.closest("[data-lv-patch]");
      if (patchTarget) {
        e.preventDefault();
        const patchUrl = patchTarget.getAttribute("href") ?? patchTarget.getAttribute("data-lv-patch") ?? "";
        if (patchUrl) this.patchParams(patchUrl);
        return;
      }

      // Click action
      const clickTarget = target.closest("[data-lv-click]");
      if (!clickTarget) return;
      const action = clickTarget.getAttribute("data-lv-click");
      const topic = this.findLiveView(clickTarget);
      if (topic && action) {
        let msg: unknown;
        try {
          const parsed = JSON.parse(action);
          msg = Array.isArray(parsed) ? parsed : [action];
        } catch {
          msg = [action];
        }
        this.maybeSend(clickTarget, () => this.sendLiveMsg(topic, msg));
      }
    });

    document.addEventListener("submit", (e: SubmitEvent) => {
      const form = (e.target as Element).closest("[data-lv-submit]") as HTMLFormElement | null;
      if (!form) return;
      e.preventDefault();
      const action = form.getAttribute("data-lv-submit");
      const topic = this.findLiveView(form);
      if (!topic || !action) return;

      const formData = new FormData(form);
      const data: Record<string, unknown> = {};
      formData.forEach((value, key) => { data[key] = value; });

      this.maybeSend(form, () => this.sendLiveMsg(topic, [action, data]));

      form.querySelectorAll('input:not([type="hidden"]):not([type="submit"])').forEach((input) => {
        (input as HTMLInputElement).value = "";
      });
    });

    document.addEventListener("input", (e: Event) => {
      const target = (e.target as Element).closest("[data-lv-change]");
      if (!target) return;
      const action = target.getAttribute("data-lv-change");
      const topic = this.findLiveView(target);
      if (topic && action) {
        this.maybeSend(e.target as Element, () => {
          this.sendLiveMsg(topic, [action, (e.target as HTMLInputElement).value]);
        });
      }
    });

    // Browser back/forward
    window.addEventListener("popstate", () => {
      if (this.liveWs?.readyState === WebSocket.OPEN) {
        this.liveViews.forEach((_lv, topic) => {
          this.liveWs!.send(JSON.stringify({ type: "leave", topic }));
        });
        this.liveWs.send(JSON.stringify({ type: "navigate", url: location.pathname + location.search }));
      } else {
        window.location.reload();
      }
    });
  }

  // ── Channel API ──────────────────────────────────────────────────

  channel(topic: string): WellChannel {
    if (!this.channelWs || this.channelWs.readyState !== WebSocket.OPEN) {
      this.connectChannel();
    }
    const ch = new ChannelInstance(topic, this);
    this.channels.set(topic, ch);
    if (this.channelConnected) ch._join();
    return ch;
  }

  /** @internal */
  _sendChannel(data: unknown) {
    if (this.channelWs?.readyState === WebSocket.OPEN) {
      this.channelWs.send(JSON.stringify(data));
    }
  }

  /** @internal */
  _removeChannel(topic: string) {
    this.channels.delete(topic);
  }

  private connectChannel() {
    if (this.channelWs && this.channelWs.readyState <= WebSocket.OPEN) return;

    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = `${proto}//${location.host}${this.wsPath}`;
    this.channelWs = new WebSocket(url);

    this.channelWs.onopen = () => {
      this.channelReconnectDelay = 500;
      this.channelConnected = true;
      this.channels.forEach((ch) => ch._join());
    };

    this.channelWs.onmessage = (event: MessageEvent) => {
      let msg: Record<string, unknown>;
      try { msg = JSON.parse(event.data as string); } catch { return; }

      const ch = msg.channel as string;
      const type = msg.type as string;
      const channel = this.channels.get(ch);

      if (type === "event" && channel) {
        const eventName = (msg.event as string) ?? "message";
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

  // ── Connect (entry point) ────────────────────────────────────────

  connect() {
    this.setupEventDelegation();

    // Built-in FileUpload hook
    const self = this;
    Well.hooks.FileUpload = {
      mounted(this: HookInstance) {
        const input = this.el.querySelector('input[type="file"]') ?? this.el;
        if ((input as HTMLElement).tagName !== "INPUT") return;
        const hookTopic = this._topic;
        input.addEventListener("change", (e: Event) => {
          const files = (e.target as HTMLInputElement).files;
          if (!files || !hookTopic) return;
          for (let i = 0; i < files.length; i++) {
            self.uploadFile(hookTopic, files[i]);
          }
        });
      },
    };

    // Discover LiveViews and connect
    document.addEventListener("DOMContentLoaded", () => {
      const elements = document.querySelectorAll("live-view");
      if (elements.length === 0) return;
      elements.forEach((el) => {
        const endpoint = el.getAttribute("data-liveview") ?? "";
        const topic = el.getAttribute("data-topic") ?? endpoint;
        let props: Record<string, unknown> = {};
        try { props = JSON.parse(el.getAttribute("data-props") ?? "{}"); } catch { /* ignore */ }
        this.liveViews.set(topic, { el, endpoint, props });
      });
      this.connectLive();
    });
  }
}

// ── Channel instance ─────────────────────────────────────────────

class ChannelInstance implements WellChannel {
  private listeners = new Map<string, ((payload: unknown) => void)[]>();
  private joined = false;

  constructor(
    private topic: string,
    private well: Well,
  ) {}

  on(event: string, cb: (payload: unknown) => void): WellChannel {
    const cbs = this.listeners.get(event) ?? [];
    cbs.push(cb);
    this.listeners.set(event, cbs);
    return this;
  }

  push(event: string, payload?: unknown) {
    this.well._sendChannel({ type: "push", channel: this.topic, event, payload: payload ?? null });
  }

  leave() {
    this.well._sendChannel({ type: "leave", channel: this.topic });
    this.well._removeChannel(this.topic);
    this.joined = false;
  }

  /** @internal */
  _join() {
    if (this.joined) return;
    this.joined = true;
    this.well._sendChannel({ type: "join", channel: this.topic });
  }

  /** @internal */
  _dispatch(event: string, payload: unknown) {
    const cbs = this.listeners.get(event);
    if (cbs) cbs.forEach((cb) => cb(payload));
    // Also dispatch to "*" wildcard listeners
    const wildcardCbs = this.listeners.get("*");
    if (wildcardCbs) wildcardCbs.forEach((cb) => cb(payload));
  }
}

// ── Auto-initialize ────────────────────────────────────────────────
// For script tag usage: automatically connect LiveViews

const well = new Well();
well.connect();

// Expose globally for hooks and channels
(window as unknown as Record<string, unknown>).Well = Well;
(window as unknown as Record<string, unknown>).well = well;
