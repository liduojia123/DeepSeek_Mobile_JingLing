/**
 * 鲸灵 JingLing 远程开发桥(Host 插件)
 *
 * 职责:主动出站 WebSocket 连到鲸灵服务器,让手机可以:
 *   1. 枚举本机工作区/会话      → workspaceRegistry / sessionQuery
 *   2. 订阅任务实时输出          → agent/assistant-stream
 *   3. 派任务/追问/停止          → agent.followup / steer / cancel
 *   4. 逐条确认工具调用          → approval/request answerer(超时按拒绝,fail-closed)
 *
 * 设计约束:
 * - 电脑不开入站端口;只出不进。
 * - 只拦截「手机正在管理的会话」的审批请求,本机正常使用不受影响;未订阅的请求委托给 next()。
 * - 断线指数退避重连;断开期间审批一律委托(没有 answerer 时 dsh 自身会 fail-closed)。
 */

import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'jingling-bridge'

const DEFAULTS = {
  serverUrl: 'http://127.0.0.1:3000',
  bridgeToken: '',
  nodeName: '',
  confirmTimeoutSec: 15,
}

const log = (...args) => console.log('[jingling-bridge]', ...args)

/**
 * 令牌可以写在插件配置里,也可以放在 ~/.dsh/jingling-bridge.json(推荐):
 * 这样 bundle 里不用带密钥,换令牌只改一个文件。
 * 文件格式: {"serverUrl":"https://…/jingling","bridgeToken":"…","nodeName":"我的电脑"}
 */
function readLocalConfig() {
  try {
    const raw = readFileSync(join(homedir(), '.dsh', 'jingling-bridge.json'), 'utf8')
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch {
    return {}
  }
}

export function apply(ctx, config = {}) {
  // 进程级单例:热重载/重复启用时先释放上一个实例,避免多条桥接连接同时在线
  const GUARD = Symbol.for('jingling.bridge.instance')
  const previous = globalThis[GUARD]
  if (typeof previous === 'function') {
    try {
      previous()
      log('已释放上一个桥接实例')
    } catch {
      // ignore
    }
  }

  const local = readLocalConfig()
  const cfg = { ...DEFAULTS, ...pickDefined(local), ...pickDefined(config) }
  if (!cfg.bridgeToken) {
    log('未配置 bridgeToken(插件配置或 ~/.dsh/jingling-bridge.json),桥接不启动')
    return () => {}
  }
  if (!String(cfg.serverUrl).startsWith('http')) {
    log('serverUrl 必须以 http(s):// 开头,当前:', cfg.serverUrl)
    return () => {}
  }

  function pickDefined(source) {
    const out = {}
    for (const [key, value] of Object.entries(source ?? {})) {
      if (value !== undefined && value !== null && value !== '') out[key] = value
    }
    return out
  }

  /** @type {WebSocket | null} */
  let socket = null
  let stopped = false
  let reconnectDelay = 1000
  let reconnectTimer = null
  let heartbeat = null
  let nodeId = null
  let selfCleanup = null

  /** task_id -> { sessionId, agent } 手机正在跟踪的任务 */
  const tasks = new Map()
  /** session_id -> Set<task_id>:只有被手机订阅的会话才转发事件与拦截审批 */
  const sessionSubs = new Map()
  /** approval_id -> resolve('allow'|'reject'|'cancelled'|'timeout') */
  const pendingApprovals = new Map()

  /** Cordis 服务必须声明 inject 才能用 ctx.xxx 访问;可选依赖用 ctx.get(name) 直接读 */
  const svc = (name) => {
    try {
      return typeof ctx.get === 'function' ? ctx.get(name) : undefined
    } catch {
      return undefined
    }
  }

  const isOpen = () => socket !== null && socket.readyState === 1

  const send = (message) => {
    if (!isOpen()) return false
    try {
      socket.send(JSON.stringify(message))
      return true
    } catch (error) {
      log('发送失败:', error?.message ?? error)
      return false
    }
  }

  const taskIdOfSession = (sessionId) => {
    const ids = sessionSubs.get(sessionId)
    if (!ids || ids.size === 0) return null
    return [...ids][0]
  }

  const sendEvent = (sessionId, event) => {
    const taskId = taskIdOfSession(sessionId)
    if (!taskId) return
    send({ type: 'event', task_id: taskId, session_id: sessionId, event })
  }

  // ---------- 上行:agent 事件 ----------

  const disposeStream = ctx.on('agent/assistant-stream', ({ agent, frame }) => {
    const sessionId = agent?.session?.id
    if (!sessionId || !taskIdOfSession(sessionId)) return
    if (frame.type !== 'chunk') return
    const chunk = frame.chunk
    if (chunk?.type === 'text-delta' && typeof chunk.text === 'string' && chunk.text !== '') {
      sendEvent(sessionId, { type: 'output', text: chunk.text })
    } else if (chunk?.type === 'reasoning-delta' && typeof chunk.text === 'string' && chunk.text !== '') {
      sendEvent(sessionId, { type: 'thinking', text: chunk.text })
    } else if (chunk?.type === 'block-end' && chunk.block?.type === 'tool-call') {
      sendEvent(sessionId, { type: 'tool', tool: chunk.block.name ?? 'tool' })
    }
  })

  const disposeStatus = ctx.on('agent/status', ({ agent, status }) => {
    const sessionId = agent?.session?.id
    if (!sessionId || !taskIdOfSession(sessionId)) return
    sendEvent(sessionId, { type: 'status', status })
  })

  const disposeError = ctx.on('agent/error', ({ agent, error }) => {
    const sessionId = agent?.session?.id
    if (!sessionId || !taskIdOfSession(sessionId)) return
    sendEvent(sessionId, { type: 'error', message: error instanceof Error ? error.message : String(error) })
  })

  // ---------- 审批:转发到手机,超时按拒绝 ----------

  const disposeApproval = ctx.on('approval/request', async (req, next) => {
    const sessionId = req?.agent?.session?.id
    // 只接管手机正在管理的会话;其余交还给原有 answerer 链
    if (!sessionId || !taskIdOfSession(sessionId)) return next()
    if (!isOpen()) return next()

    const approvalId = randomUUID()
    const timeoutMs = Math.max(5, Number(cfg.confirmTimeoutSec) || 15) * 1000
    const sent = send({
      type: 'confirm_request',
      approval_id: approvalId,
      session_id: sessionId,
      task_id: taskIdOfSession(sessionId),
      tool: req.toolName ?? 'unknown',
      reason: req.reason ?? '',
      timeout_sec: Math.round(timeoutMs / 1000),
    })
    if (!sent) return 'rejected'

    const decision = await new Promise((resolve) => {
      const timer = setTimeout(() => {
        pendingApprovals.delete(approvalId)
        resolve('timeout')
      }, timeoutMs)
      pendingApprovals.set(approvalId, (value) => {
        clearTimeout(timer)
        pendingApprovals.delete(approvalId)
        resolve(value)
      })
      req.signal?.addEventListener(
        'abort',
        () => {
          clearTimeout(timer)
          pendingApprovals.delete(approvalId)
          resolve('cancelled')
        },
        { once: true },
      )
    })

    if (decision === 'allow') return 'allowed-once'
    if (decision === 'cancelled') return 'cancelled'
    // 拒绝与超时都按 fail-closed 的 rejected 处理
    return 'rejected'
  })

  // ---------- RPC ----------

  async function listWorkspaces() {
    const result = { workspaces: [], sessions: [], diagnostics: {} }
    result.diagnostics.available = {
      workspaceRegistry: typeof svc('workspaceRegistry')?.list === 'function',
      sessionQuery: typeof svc('sessionQuery')?.listSessions === 'function',
      agents: typeof svc('agents')?.list === 'function',
      sessions: typeof svc('sessions')?.list === 'function',
    }

    try {
      let list = svc('workspaceRegistry')?.list?.()
      if (list && typeof list.then === 'function') list = await list
      result.workspaces = (list ?? []).map((workspace) => ({
        id: String(workspace.id),
        title: workspace.title,
        path: workspace.path,
        session_ids: (workspace.sessionIds ?? []).map(String),
        updated_at: workspace.updatedAt,
      }))
    } catch (error) {
      result.diagnostics.workspacesError = String(error?.message ?? error)
    }

    try {
      let rows = svc('sessionQuery')?.listSessions?.()
      if (rows && typeof rows.then === 'function') rows = await rows
      if (!Array.isArray(rows)) throw new Error(`listSessions 返回了非数组: ${typeof rows}`)
      result.diagnostics.sessionsSample = rows[0] ? Object.keys(rows[0]) : []
      result.diagnostics.sessionsHeaderSample = rows[0]?.header ? Object.keys(rows[0].header) : []
      // 真实形状:{ header: SessionHeader, live, persisted }(listSessions 是 async)
      result.sessions = rows.map((row) => {
        const header = row?.header ?? row ?? {}
        return {
          id: String(header.id ?? ''),
          title: header.title ?? null,
          cwd: header.cwd ?? null,
          created_at: header.createdAt ?? header.created_at ?? null,
          parent: header.parent ?? null,
          live: Boolean(row?.live),
          persisted: Boolean(row?.persisted),
        }
      })
    } catch (error) {
      result.diagnostics.sessionsError = String(error?.message ?? error)
      // 兜底:至少把当前在跑的会话报上去
      try {
        result.sessions = (svc('agents')?.list?.() ?? []).map((agent) => ({
          id: String(agent.session?.id ?? ''),
          title: null,
          cwd: agent.session?.cwd ?? null,
          created_at: null,
          live: true,
          persisted: true,
        }))
      } catch {
        // ignore
      }
    }

    return result
  }

  async function ensureAgent(sessionId) {
    const agents = svc('agents')
    const existing = agents?.get?.(sessionId)
    if (existing) return existing
    if (typeof agents?.resume !== 'function') throw new Error('agents.resume 不可用')
    const handle = await agents.resume({ resumeSessionId: sessionId })
    return handle?.agent ?? handle
  }

  async function startTask({ task_id: taskId, session_id: sessionId, prompt, cwd }) {
    // session_id 传 '__new__' + cwd = 新建一个会话(默认审批策略 ask,便于手机测试确认卡片)
    let agent
    if (sessionId === '__new__') {
      const agents = svc('agents')
      if (typeof agents?.create !== 'function') throw new Error('agents.create 不可用')
      // 新会话必须带模型路由:优先继承当前任一 live agent 的 provider/model
      const live = agents.list?.() ?? []
      const sample = live.find((a) => a?.options?.provider && a?.options?.model)?.options
      const agentOptions = sample
        ? { provider: sample.provider, model: sample.model }
        : cfg.agentProvider && cfg.agentModel
          ? { provider: cfg.agentProvider, model: cfg.agentModel }
          : undefined
      if (!agentOptions) {
        throw new Error('无法确定模型路由:请先在本机打开一个会话,或在插件配置里填 agentProvider/agentModel')
      }
      const created = await agents.create({
        sessionId: `session-${randomUUID()}`,
        agentOptions,
        meta: cwd ? { cwd: String(cwd) } : {},
      })
      agent = created?.agent ?? created
      sessionId = String(agent?.session?.id ?? '')
    } else {
      agent = await ensureAgent(sessionId)
    }
    if (!agent) throw new Error('找不到该会话')
    ensureSubscription(sessionId, taskId)
    tasks.set(taskId, { sessionId, agent })
    // 需要逐条确认时,把该会话的策略切到 ask(否则历史里的 never 会直接放行/拒绝)
    if (params.require_approval) {
      try {
        svc('approval')?.setPolicy?.(agent, 'ask')
      } catch (error) {
        log('切换审批策略失败:', error?.message ?? error)
      }
    }
    agent.followup({ content: [{ type: 'text', text: String(prompt ?? '') }], source: { kind: 'jingling' } })
    return { task_id: taskId, session_id: sessionId }
  }

  async function steerTask({ task_id: taskId, prompt }) {
    const task = tasks.get(taskId)
    const agent = task?.agent ?? svc('agents')?.get?.(task?.sessionId)
    if (!agent) throw new Error('任务对应会话已不在运行')
    agent.steer({ content: [{ type: 'text', text: String(prompt ?? '') }], source: { kind: 'jingling' } })
    return { ok: true }
  }

  async function stopTask({ task_id: taskId }) {
    const task = tasks.get(taskId)
    const agent = task?.agent ?? svc('agents')?.get?.(task?.sessionId)
    if (!agent) return { ok: true }
    agent.cancel({ kind: 'user' })
    return { ok: true }
  }

  function ensureSubscription(sessionId, taskId) {
    const ids = sessionSubs.get(sessionId) ?? new Set()
    ids.add(taskId)
    sessionSubs.set(sessionId, ids)
  }

  function dropSubscription(sessionId, taskId) {
    const ids = sessionSubs.get(sessionId)
    if (!ids) return
    if (taskId) ids.delete(taskId)
    else ids.clear()
    if (ids.size === 0) sessionSubs.delete(sessionId)
  }

  async function handleRpc(method, params = {}) {
    switch (method) {
      case 'ping':
        return { pong: true }
      case 'workspaces.list':
        return await listWorkspaces()
      case 'sessions.list':
        return { sessions: (await listWorkspaces()).sessions }
      case 'tasks.start':
        return startTask(params)
      case 'tasks.steer':
        return steerTask(params)
      case 'tasks.stop':
        return stopTask(params)
      case 'subscribe':
        ensureSubscription(String(params.session_id), String(params.task_id))
        return { ok: true }
      case 'unsubscribe':
        dropSubscription(String(params.session_id), params.task_id ? String(params.task_id) : null)
        return { ok: true }
      case 'node.info':
        return {
          node_id: nodeId,
          name: cfg.nodeName || 'dsh',
          platform: process.platform,
          versions: { electron: process.versions.electron, node: process.versions.node },
          agents: (svc('agents')?.list?.() ?? []).length,
        }
      default:
        throw new Error(`未知方法: ${method}`)
    }
  }

  async function onMessage(raw) {
    let message
    try {
      message = JSON.parse(typeof raw === 'string' ? raw : raw.toString())
    } catch {
      return
    }

    if (message.type === 'rpc') {
      try {
        const result = await handleRpc(message.method, message.params ?? {})
        send({ type: 'rpc-result', id: message.id, ok: true, result })
      } catch (error) {
        send({ type: 'rpc-result', id: message.id, ok: false, error: error instanceof Error ? error.message : String(error) })
      }
      return
    }

    if (message.type === 'confirm_result') {
      const resolve = pendingApprovals.get(message.approval_id)
      if (resolve) resolve(message.decision === 'allow' ? 'allow' : message.decision === 'cancelled' ? 'cancelled' : 'reject')
      return
    }

    if (message.type === 'hello_ok') {
      nodeId = message.node_id ?? nodeId
      log('桥接已注册,node_id =', nodeId)
      return
    }

    if (message.type === 'stand_down') {
      log('收到 stand_down(同机有更新的桥接连接),当前实例停止')
      try {
        selfCleanup?.()
      } catch {
        // ignore
      }
      return
    }

    if (message.type === 'pong') return
  }

  // ---------- 连接与重连 ----------

  function connect() {
    if (stopped) return
    const base = String(cfg.serverUrl).replace(/\/+$/, '').replace(/^http/, 'ws')
    const url = `${base}/v1/harness/bridge?token=${encodeURIComponent(cfg.bridgeToken)}`
    let ws
    try {
      ws = new WebSocket(url)
    } catch (error) {
      log('连接失败:', error?.message ?? error)
      scheduleReconnect()
      return
    }
    socket = ws

    ws.addEventListener('open', () => {
      reconnectDelay = 1000
      log('已连接鲸灵服务器:', base)
      send({
        type: 'hello',
        node: {
          name: cfg.nodeName || 'dsh',
          platform: process.platform,
          capabilities: ['workspaces', 'sessions', 'tasks', 'approval', 'events', 'v2'],
          versions: { electron: process.versions.electron, node: process.versions.node },
        },
      })
      heartbeat = setInterval(() => send({ type: 'ping' }), 25_000)
    })

    ws.addEventListener('message', (event) => {
      void onMessage(event.data)
    })

    ws.addEventListener('close', () => {
      if (heartbeat) {
        clearInterval(heartbeat)
        heartbeat = null
      }
      socket = null
      if (!stopped) scheduleReconnect()
    })

    ws.addEventListener('error', () => {
      // close 事件会随后到达并触发重连,这里只避免未捕获异常
    })
  }

  function scheduleReconnect() {
    if (stopped) return
    if (reconnectTimer) return
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null
      connect()
    }, reconnectDelay)
    reconnectDelay = Math.min(reconnectDelay * 2, 30_000)
  }

  connect()

  const cleanup = () => {
    stopped = true
    if (selfCleanup === cleanup) selfCleanup = null
    if (reconnectTimer) clearTimeout(reconnectTimer)
    if (heartbeat) clearInterval(heartbeat)
    for (const resolve of pendingApprovals.values()) resolve('cancelled')
    pendingApprovals.clear()
    tasks.clear()
    sessionSubs.clear()
    disposeStream?.()
    disposeStatus?.()
    disposeError?.()
    disposeApproval?.()
    try {
      socket?.close()
    } catch {
      // ignore
    }
    socket = null
    if (globalThis[GUARD] === cleanup) delete globalThis[GUARD]
    log('桥接已停止')
  }
  selfCleanup = cleanup
  globalThis[GUARD] = cleanup
  return cleanup
}
