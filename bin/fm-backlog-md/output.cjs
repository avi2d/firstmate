const BASE = ['id', 'state', 'kind', 'repo', 'title'];
const HOLD = ['hold_reason', 'hold_kind', 'hold_until'];
const EXTRA = ['blocked', 'blocked_by', 'body', 'closed', 'created', 'delivery_state', 'deps', 'held', ...HOLD, 'links', 'priority'];
const SHOW = ['id', 'title', 'state', 'blocked', 'blocked_by', 'held', ...HOLD, 'kind', 'repo', 'priority', 'created', 'closed', 'deps', 'links', 'body'];

function scalar(value) {
  if (typeof value === 'number') return String(value);
  if (!value || value === '-' || value !== value.trim() || /[,:\[\]{}"\\\x00-\x1f]/.test(value) ||
      /^-?\d+(?:\.\d+)?$|^(?:true|false|null)$/.test(value)) return JSON.stringify(value);
  return value;
}

function help(lines, inline = false) {
  if (inline && lines.length === 1) return [`help[1]: ${scalar(lines[0])}`];
  return [`help[${lines.length}]:`, ...lines.map(line => `  - ${scalar(line)}`)];
}

function shorten(text, limit, fullCommand) {
  if (text.length <= limit) return text;
  return `${text.slice(0, limit)}\n... (truncated, ${text.length} chars total - use ${fullCommand} to see complete text)`;
}

function field(task, key, full = false, fullCommand = `show ${task.id} --full`) {
  switch (key) {
    case 'title': return full ? task.title : shorten(task.title, 80, fullCommand);
    case 'body': return task.body === null ? '' : full ? task.body : shorten(task.body, 500, fullCommand);
    case 'held':
    case 'blocked': return task[key] ? 'yes' : 'no';
    case 'hold_reason': return task.hold?.reason || '-';
    case 'hold_kind': return task.hold?.kind ?? '-';
    case 'hold_until': return task.hold?.until ?? '-';
    case 'blocked_by': return task.blocked_by.join(',') || 'none';
    case 'deps': return task.deps.map(dep => `${dep.type}:${dep.id}`).join(',') || 'none';
    case 'links': return task.links.map(link => `${link.kind}:${link.url}`).join(',') || 'none';
    case 'kind': return task.kind ?? 'task';
    default: return task[key] ?? '-';
  }
}

function show(task, full, fullCommand) {
  return ['task:', ...SHOW.map(key => `  ${key}: ${scalar(field(task, key, full, fullCommand))}`)];
}

function table(name, tasks, fields) {
  const keys = [...BASE, ...fields];
  if (tasks.length === 0) return [`${name}: []`];
  return [
    `${name}[${tasks.length}]{${keys.join(',')}}:`,
    ...tasks.map(task => `  ${keys.map(key => scalar(field(task, key))).join(',')}`),
  ];
}

function mutation(action, task, options, { message, hints, showTask = false, ...details }) {
  if (options.json) return JSON.stringify({ ok: true, action, ...details, task }, null, 2);
  return [
    `ok: ${message}`,
    ...(details.already ? ['already: true'] : []),
    ...(showTask ? show(task, false) : []),
    ...help(hints),
  ].join('\n');
}

module.exports = { scalar, help, show, table, mutation, EXTRA, HOLD };
