import { randomUUID, timingSafeEqual } from 'node:crypto';
import websocket from '@fastify/websocket';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import type { WebSocket } from 'ws';
import { ApiError } from '../auth.js';
import type { Config } from '../config.js';
import { DEV_CORS_HEADERS } from '../cors.js';
import { nowIso, type Db } from '../db.js';

interface NodeState {
  id: string;
  name: string;
  platform: string;
  capabilities: string[];
  /** 插件实例启动时间,用于在同机多实例时选最新 */
  since: number;
  ws: WebSocket;
  lastSeen: string;
}

type TaskStatus = 'running' | 'done' | 'error' | 'stopped';

interface StoredEvent {
  seq: number;
  ts: string;
  kind: string;
  payload: Record<string, unknown>;
}

interface TaskState {
  id: string;
  nodeId: string;
  sessionId: string;
  prompt: string;
  status: TaskStatus;
  createdAt: string;
  events: StoredEvent[];
  listeners: Set<(event: StoredEvent) => void>;
  confirms: Map<string, { resolve: (decision: 'allow' | 'reject') => void; timer: NodeJS.Timeout }>;
}

interface PendingRpc {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

const MAX_BUFFERED_EVENTS = 500;
/** 超过这个时间没收到任何消息的节点视为离线(插件 25s 心跳) */
const NODE_STALE_MS = 90_000;

const safeEqual = (a: string, b: string): boolean => {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
};

/**
 * dsh 远程开发桥的中继中心。
 * 插件(电脑)主动出站 WS 接入,手机通过 REST/SSE 操作;两者用不同的令牌鉴权。
 */
export class HarnessHub {
  private readonly nodes = new Map<string, NodeState>();
  private readonly tasks = new Map<string, TaskState>();
  private readonly rpcs = new Map<string, PendingRpc>();

  constructor(
    private readonly db: Db,
    private readonly config: Config,
  ) {}

  get enabled(): boolean {
    return this.config.bridgeToken !== '';
  }

  listNodes() {
    const now = Date.now();
    return [...this.nodes.values()].map((node) => ({
      node_id: node.id,
      name: node.name,
      platform: node.platform,
      capabilities: node.capabilities,
      online: node.ws.readyState === 1 && now - Date.parse(node.lastSeen) < NODE_STALE_MS,
      last_seen: node.lastSeen,
    }));
  }

  getTask(taskId: string): TaskState {
    const task = this.tasks.get(taskId);
    if (!task) throw new ApiError(404, 'task_not_found', '任务不存在');
    return task;
  }

  resolveNode(nodeId?: string): NodeState {
    if (nodeId) {
      const node = this.nodes.get(nodeId);
      if (!node) throw new ApiError(404, 'node_not_found', '节点不存在');
      return node;
    }
    const online = [...this.nodes.values()]
      .filter((node) => node.ws.readyState === 1 && Date.now() - Date.parse(node.lastSeen) < NODE_STALE_MS)
      .sort((a, b) => {
        // 优先选声明了 v2 能力的节点(支持 workspaces/sessions/tasks/approval 全量 RPC)
        const rank = (node: NodeState) => (node.capabilities.includes('v2') ? 1 : 0);
        if (rank(a) !== rank(b)) return rank(b) - rank(a);
        // 同能力时选「启动最晚」的实例,热重载残留的旧实例不会抢到任务
        if (a.since !== b.since) return b.since - a.since;
        return a.lastSeen < b.lastSeen ? 1 : -1;
      });
    const latest = online[0];
    if (!latest) throw new ApiError(409, 'node_offline', '没有在线的电脑节点,请确认桥接插件已连接');
    return latest;
  }

  async rpc(node: NodeState, method: string, params: Record<string, unknown>, timeoutMs = 15_000): Promise<unknown> {
    const id = randomUUID();
    const promise = new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.rpcs.delete(id);
        reject(new ApiError(504, 'node_timeout', `电脑节点响应超时(${method})`));
      }, timeoutMs);
      this.rpcs.set(id, { resolve, reject, timer });
    });
    node.ws.send(JSON.stringify({ type: 'rpc', id, method, params }));
    return promise;
  }

  /** 手机侧:创建任务并让插件开始 followup */
  async createTask(input: {
    sessionId: string;
    prompt: string;
    nodeId?: string;
    cwd?: string;
    requireApproval?: boolean;
    agentPreset?: string;
    permissionMode?: string;
  }) {
    const node = this.resolveNode(input.nodeId);
    const taskId = randomUUID();
    const task: TaskState = {
      id: taskId,
      nodeId: node.id,
      sessionId: input.sessionId,
      prompt: input.prompt,
      status: 'running',
      createdAt: nowIso(),
      events: [],
      listeners: new Set(),
      confirms: new Map(),
    };
    this.tasks.set(taskId, task);
    this.db
      .prepare(
        `INSERT INTO harness_task (id, node_id, workspace, prompt, status, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
      )
      .run(taskId, node.id, input.sessionId, input.prompt, 'running', task.createdAt);

    try {
      const started = (await this.rpc(node, 'tasks.start', {
        task_id: taskId,
        session_id: input.sessionId,
        prompt: input.prompt,
        ...(input.cwd === undefined ? {} : { cwd: input.cwd }),
        ...(input.requireApproval === true ? { require_approval: true } : {}),
        ...(input.agentPreset ? { agent_preset: input.agentPreset } : {}),
        ...(input.permissionMode ? { permission_mode: input.permissionMode } : {}),
      })) as Record<string, unknown> | undefined;
      if (started && typeof started.session_id === 'string' && started.session_id !== '') {
        task.sessionId = started.session_id;
        this.db.prepare('UPDATE harness_task SET workspace = ? WHERE id = ?').run(task.sessionId, task.id);
      }
    } catch (error) {
      this.setStatus(task, 'error');
      this.pushEvent(task, 'error', {
        message: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
    return { task_id: taskId, node_id: node.id, session_id: input.sessionId, status: task.status };
  }

  async confirm(taskId: string, approvalId: string, decision: 'allow' | 'reject') {
    const task = this.getTask(taskId);
    const pending = task.confirms.get(approvalId);
    if (!pending) throw new ApiError(404, 'confirm_not_found', '该确认请求已超时或不存在');
    clearTimeout(pending.timer);
    task.confirms.delete(approvalId);
    pending.resolve(decision);
    this.pushEvent(task, 'confirm_result', { approval_id: approvalId, decision });
    return { ok: true, decision };
  }

  async stopTask(taskId: string) {
    const task = this.getTask(taskId);
    const node = this.nodes.get(task.nodeId);
    if (node) {
      await this.rpc(node, 'tasks.stop', { task_id: taskId }).catch(() => undefined);
    }
    this.setStatus(task, 'stopped');
    return { ok: true };
  }

  subscribe(taskId: string, listener: (event: StoredEvent) => void): () => void {
    const task = this.getTask(taskId);
    task.listeners.add(listener);
    return () => task.listeners.delete(listener);
  }

  private pushEvent(task: TaskState, kind: string, payload: Record<string, unknown>): StoredEvent {
    const event: StoredEvent = { seq: task.events.length + 1, ts: nowIso(), kind, payload: { task_id: task.id, ...payload } };
    task.events.push(event);
    if (task.events.length > MAX_BUFFERED_EVENTS) task.events.shift();
    // 文本增量太碎,只持久化结构化事件
    if (kind !== 'output' && kind !== 'thinking') {
      try {
        this.db
          .prepare(
            `INSERT INTO harness_event (id, task_id, kind, payload_json, ts) VALUES (?, ?, ?, ?, ?)`,
          )
          .run(randomUUID(), task.id, kind, JSON.stringify(event.payload), event.ts);
      } catch {
        // 事件落库失败不影响实时流
      }
    }
    for (const listener of task.listeners) {
      try {
        listener(event);
      } catch {
        // 单个订阅者异常不影响其它
      }
    }
    return event;
  }

  private setStatus(task: TaskState, status: TaskStatus): void {
    if (task.status === status) return;
    task.status = status;
    this.db.prepare('UPDATE harness_task SET status = ? WHERE id = ?').run(status, task.id);
    this.pushEvent(task, 'status', { status });
  }

  /** 插件连上后的会话 */
  attach(ws: WebSocket, request: FastifyRequest, log?: { info: (msg: string) => void }): void {
    const token = String((request.query as Record<string, unknown>)?.token ?? '');
    if (!this.enabled) {
      ws.close(1013, 'bridge disabled');
      return;
    }
    if (!safeEqual(token, this.config.bridgeToken)) {
      ws.close(1008, 'invalid bridge token');
      return;
    }

    const nodeId = randomUUID();
    let registered = false;

    ws.on('message', (raw: Buffer) => {
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(raw.toString()) as Record<string, unknown>;
      } catch {
        return;
      }

      // 任何上行消息都刷新节点活跃时间(插件 25s 一次 ping)
      if (registered) {
        const node = this.nodes.get(nodeId);
        if (node) node.lastSeen = nowIso();
      }
      if (message.type !== 'ping') {
        log?.info(
          `桥接上行 ${String(message.type)}${message.type === 'rpc' ? ` ${String(message.method)}` : ''}` +
            `${message.type === 'confirm_request' ? ` tool=${String(message.tool)} approval=${String(message.approval_id)}` : ''}`,
        );
      }

      if (message.type === 'hello') {
        const info = (message.node ?? {}) as Record<string, unknown>;
        const name = String(info.name ?? 'dsh');
        const platform = String(info.platform ?? 'unknown');
        const capabilities = Array.isArray(info.capabilities) ? info.capabilities.map(String) : [];
        const isV2 = capabilities.includes('v2');

        // 同一台机器只保留一条连接;高能力节点优先,低版本重连不能顶掉 v2 节点
        for (const [existingId, existing] of this.nodes) {
          if (existing.name !== name || existing.platform !== platform) continue;
          const existingIsV2 = existing.capabilities.includes('v2');
          if (existingIsV2 && !isV2) {
            // 旧版本重连:不注册、也不关闭(关闭会让旧实例陷入重连风暴),让它静默挂着
            log?.info(`忽略旧版本桥接节点: ${name}(${platform})`);
            return;
          }
          // 新连接接管路由;旧 socket 保留但不关闭,避免旧实例反复重连
          this.nodes.delete(existingId);
        }
        const node: NodeState = {
          id: nodeId,
          name,
          platform,
          capabilities,
          since: Number(info.startedAt) || Date.now(),
          ws,
          lastSeen: nowIso(),
        };
        this.nodes.set(nodeId, node);
        registered = true;
        log?.info(`桥接节点上线: ${name}(${platform}) capabilities=[${capabilities.join(',')}]`);
        this.db
          .prepare(
            `INSERT INTO harness_node (id, name, platform, status, last_seen) VALUES (?, ?, ?, 'online', ?)
             ON CONFLICT(id) DO UPDATE SET name = excluded.name, platform = excluded.platform, status = 'online', last_seen = excluded.last_seen`,
          )
          .run(nodeId, name, platform, node.lastSeen);
        ws.send(JSON.stringify({ type: 'hello_ok', node_id: nodeId }));
        return;
      }

      if (message.type === 'rpc-result') {
        const pending = this.rpcs.get(String(message.id));
        if (!pending) return;
        clearTimeout(pending.timer);
        this.rpcs.delete(String(message.id));
        if (message.ok) pending.resolve(message.result);
        else pending.reject(new ApiError(502, 'node_error', String(message.error ?? '电脑节点执行失败')));
        return;
      }

      if (message.type === 'event') {
        const task = this.tasks.get(String(message.task_id));
        if (!task) return;
        const event = (message.event ?? {}) as Record<string, unknown>;
        const kind = String(event.type ?? 'unknown');
        if (kind === 'status') {
          const status = String(event.status ?? '');
          if (status === 'idle') {
            // error/stopped 是终态,不要被随后的 idle 覆盖成 done
            if (task.status === 'error' || task.status === 'stopped') return;
            this.setStatus(task, 'done');
          }
          return;
        }
        if (kind === 'error') {
          this.pushEvent(task, 'error', { message: event.message ?? '电脑节点报错' });
          this.setStatus(task, 'error');
          return;
        }
        this.pushEvent(task, kind, event);
        return;
      }

      if (message.type === 'confirm_request') {
        const task = this.tasks.get(String(message.task_id));
        if (!task) return;
        const approvalId = String(message.approval_id);
        const timeoutSec = Number(message.timeout_sec ?? 15) || 15;
        this.pushEvent(task, 'confirm_request', {
          approval_id: approvalId,
          tool: message.tool ?? 'tool',
          reason: message.reason ?? '',
          timeout_sec: timeoutSec,
        });
        const timer = setTimeout(() => {
          if (!task.confirms.has(approvalId)) return;
          task.confirms.delete(approvalId);
          this.sendToNode(task.nodeId, { type: 'confirm_result', approval_id: approvalId, decision: 'reject' });
          this.pushEvent(task, 'confirm_result', { approval_id: approvalId, decision: 'reject', timeout: true });
        }, timeoutSec * 1000);
        timer.unref();
        task.confirms.set(approvalId, {
          resolve: (decision) => {
            this.sendToNode(task.nodeId, { type: 'confirm_result', approval_id: approvalId, decision });
          },
          timer,
        });
        return;
      }

      if (message.type === 'ping') {
        ws.send(JSON.stringify({ type: 'pong' }));
      }
    });

    ws.on('close', () => {
      if (!registered) return;
      this.nodes.delete(nodeId);
      this.db.prepare('UPDATE harness_node SET status = ?, last_seen = ? WHERE id = ?').run('offline', nowIso(), nodeId);
      for (const task of this.tasks.values()) {
        if (task.nodeId !== nodeId) continue;
        for (const [approvalId, pending] of task.confirms) {
          clearTimeout(pending.timer);
          pending.resolve('reject');
          task.confirms.delete(approvalId);
          this.pushEvent(task, 'confirm_result', { approval_id: approvalId, decision: 'reject', node_offline: true });
        }
        if (task.status === 'running') {
          this.setStatus(task, 'error');
          this.pushEvent(task, 'error', { message: '电脑节点断开连接' });
        }
      }
    });
  }

  private sendToNode(nodeId: string, message: Record<string, unknown>): void {
    const node = this.nodes.get(nodeId);
    if (!node || node.ws.readyState !== 1) return;
    node.ws.send(JSON.stringify(message));
  }
}

const sseEncode = (kind: string, payload: unknown): string => `event: ${kind}\ndata: ${JSON.stringify(payload)}\n\n`;

/** 插件接入点:必须在设备鉴权作用域之外(用 bridge token) */
export function registerHarnessBridge(app: FastifyInstance, hub: HarnessHub): void {
  app.register(websocket);
  app.register(async (scope) => {
    scope.get('/v1/harness/bridge', { websocket: true }, (connection, request) => {
      hub.attach(connection as unknown as WebSocket, request, scope.log);
    });
  });
}

/** 手机侧 REST/SSE(走设备令牌,由外层 preHandler 保护) */
export function registerHarnessRoutes(
  secured: FastifyInstance,
  hub: HarnessHub,
  config: Config,
): void {
  secured.get('/v1/harness/nodes', async () => ({ nodes: hub.listNodes() }));

  secured.get('/v1/harness/workspaces', async (request) => {
    const nodeId = (request.query as Record<string, unknown>)?.node_id;
    const node = hub.resolveNode(typeof nodeId === 'string' ? nodeId : undefined);
    const result = (await hub.rpc(node, 'workspaces.list', {})) as Record<string, unknown>;
    return { node_id: node.id, ...result };
  });

  secured.post('/v1/harness/tasks', async (request) => {
    const body = (request.body ?? {}) as Record<string, unknown>;
    const sessionId = String(body.session_id ?? '');
    const prompt = String(body.prompt ?? '');
    if (!sessionId || !prompt) {
      throw new ApiError(400, 'validation_error', '需要 session_id 与 prompt');
    }
    return hub.createTask({
      sessionId,
      prompt,
      nodeId: typeof body.node_id === 'string' ? body.node_id : undefined,
      cwd: typeof body.cwd === 'string' ? body.cwd : undefined,
      requireApproval: body.require_approval === true,
      agentPreset: typeof body.agent_preset === 'string' ? body.agent_preset : undefined,
      permissionMode: typeof body.permission_mode === 'string' ? body.permission_mode : undefined,
    });
  });

  secured.get('/v1/harness/tasks/:id', async (request) => {
    const { id } = request.params as { id: string };
    const task = hub.getTask(id);
    return {
      task_id: task.id,
      node_id: task.nodeId,
      session_id: task.sessionId,
      status: task.status,
      prompt: task.prompt,
      created_at: task.createdAt,
      events: task.events.slice(-100),
    };
  });

  secured.post('/v1/harness/tasks/:id/confirm', async (request) => {
    const { id } = request.params as { id: string };
    const body = (request.body ?? {}) as Record<string, unknown>;
    const approvalId = String(body.approval_id ?? '');
    const decision = body.decision === 'allow' ? 'allow' : 'reject';
    if (!approvalId) throw new ApiError(400, 'validation_error', '需要 approval_id');
    return hub.confirm(id, approvalId, decision);
  });

  secured.get('/v1/harness/tasks/:id/permission', async (request) => {
    const { id } = request.params as { id: string };
    const task = hub.getTask(id);
    const node = hub.resolveNode(task.nodeId);
    return await hub.rpc(node, 'permission.get', { session_id: task.sessionId });
  });

  secured.post('/v1/harness/tasks/:id/permission', async (request) => {
    const { id } = request.params as { id: string };
    const body = (request.body ?? {}) as Record<string, unknown>;
    const mode = String(body.mode ?? '');
    if (mode === '') throw new ApiError(400, 'validation_error', '需要 mode');
    const task = hub.getTask(id);
    const node = hub.resolveNode(task.nodeId);
    return await hub.rpc(node, 'permission.set', { session_id: task.sessionId, mode });
  });

  secured.post('/v1/harness/tasks/:id/stop', async (request) => {
    const { id } = request.params as { id: string };
    return hub.stopTask(id);
  });

  secured.get('/v1/harness/tasks/:id/events', async (request, reply) => {
    const { id } = request.params as { id: string };
    const task = hub.getTask(id);

    reply.hijack();
    const raw = reply.raw;
    raw.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
      // hijack 之后 Fastify 的 CORS 钩子不会写入,开发期自己带上
      ...(config.devCors ? DEV_CORS_HEADERS : {}),
    });

    const write = (kind: string, payload: unknown): void => {
      if (raw.destroyed || raw.writableEnded) return;
      raw.write(sseEncode(kind, payload));
    };

    for (const event of task.events) write(`harness_${event.kind}`, event.payload);
    const unsubscribe = hub.subscribe(id, (event) => write(`harness_${event.kind}`, event.payload));

    const heartbeat = setInterval(() => {
      if (!raw.destroyed && !raw.writableEnded) raw.write(': ping\n\n');
    }, 15_000);
    heartbeat.unref();

    const close = (): void => {
      clearInterval(heartbeat);
      unsubscribe();
      if (!raw.writableEnded) raw.end();
    };
    raw.on('close', close);
    raw.on('error', close);
    return reply;
  });
}
