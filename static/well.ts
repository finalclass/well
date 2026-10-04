export interface WellChannel {
  on(event: string, cb: (payload: unknown) => void): WellChannel;
  push(event: string, payload?: unknown): Promise<unknown>;
  leave(): void;
}

export class Well {
  private channelWs: WebSocket | null = null;
  private channelReconnectDelay = 500;
  private readonly maxReconnectDelay = 10000;
  private readonly channels = new Map<string, ChannelInstance>();
  private channelConnected = false;
  private wsPath: string;
  constructor(opts?: { wsPath?: string }) { this.wsPath = opts?.wsPath ?? "/ws"; }
  channel(topic: string): WellChannel {
    if (!this.channelWs || this.channelWs.readyState !== WebSocket.OPEN) {
      this.connectChannel();
    }
    const ch = new ChannelInstance(topic, this);
    this.channels.set(topic, ch);
    if (this.channelConnected) ch._join();
    return ch;
  }


  _sendChannel(data: unknown) {
    if (this.channelWs?.readyState === WebSocket.OPEN) {
      this.channelWs.send(JSON.stringify(data));
    }
  }


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
      } else if (type === "join_ok" && channel) {
        channel._dispatch("join_ok", msg.state);
      } else if (type === "reply" && channel) {
        const eventName = (msg.event as string) ?? "";
        channel._resolveReply(eventName, msg.payload);
      } else if (type === "error" && channel) {
        const eventName = (msg.event as string) ?? "";
        channel._rejectReply(eventName, msg.reason as string);
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

}

class ChannelInstance implements WellChannel {
  private listeners = new Map<string, ((payload: unknown) => void)[]>();
  private joined = false;
  private pendingReplies = new Map<string, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();

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

  push(event: string, payload?: unknown): Promise<unknown> {
    this.well._sendChannel({ type: "push", channel: this.topic, event, payload: payload ?? null });
    return new Promise((resolve, reject) => {
      this.pendingReplies.set(event, { resolve, reject });
    });
  }

  leave() {
    this.well._sendChannel({ type: "leave", channel: this.topic });
    this.well._removeChannel(this.topic);
    this.joined = false;
  }


  _join() {
    if (this.joined) return;
    this.joined = true;
    this.well._sendChannel({ type: "join", channel: this.topic });
  }


  _dispatch(event: string, payload: unknown) {
    const cbs = this.listeners.get(event);
    if (cbs) cbs.forEach((cb) => cb(payload));
    const wildcardCbs = this.listeners.get("*");
    if (wildcardCbs) wildcardCbs.forEach((cb) => cb(payload));
  }


  _resolveReply(event: string, payload: unknown) {
    const pending = this.pendingReplies.get(event);
    if (pending) {
      this.pendingReplies.delete(event);
      pending.resolve(payload);
    }
  }


  _rejectReply(event: string, reason: string) {
    const pending = this.pendingReplies.get(event);
    if (pending) {
      this.pendingReplies.delete(event);
      pending.reject(new Error(reason));
    }
  }
}

const well = new Well();
(window as unknown as Record<string, unknown>).Well = Well;
(window as unknown as Record<string, unknown>).well = well;
