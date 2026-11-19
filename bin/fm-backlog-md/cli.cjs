const fs = require('node:fs');
const { randomBytes } = require('node:crypto');
const { board, PR, SLUG, projectTask, holdRecord, saveHold, taskOrder, sectionBody, setSection } = require('./store.cjs');
const { scalar, help, show, table, mutation, EXTRA, HOLD } = require('./output.cjs');

const states = ['queued', 'in_flight', 'done', 'held'];
const holdKinds = ['captain', 'external', 'load', 'parked', 'future'];
const baseFields = ['repo', 'kind'];
const patchFields = [...baseFields, 'priority', 'body', 'body-file', 'pr', 'report'];
const commands = {
  show: { args: '<id> [--full]', flags: [], switches: ['full'], count: 1 },
  add: { args: '<id> "<title>" [flags]', flags: [...patchFields, 'blocked-by', 'prefix'], switches: ['queue', 'mint', 'json'], count: 2 },
  list: { args: '[flags]', flags: [...baseFields, 'state', 'limit', 'fields'], switches: ['blocked'], count: 0 },
  ready: { args: '[--repo <name>] [--include-held]', flags: ['repo'], switches: ['include-held'], count: 0 },
  update: { args: '<id> [flags]', flags: ['title', ...patchFields], switches: ['archive-body', 'json'], count: 1 },
  done: { args: '<id> [flags]', flags: ['pr', 'report', 'note', 'keep'], switches: ['no-prune', 'json'], count: 1 },
  block: { args: '<id> --by <other>', flags: ['by'], switches: ['json'], count: 1 },
  unblock: { args: '<id> --by <other>', flags: ['by'], switches: ['json'], count: 1 },
  hold: { args: '<id> --reason "<text>" [flags]', flags: ['reason', 'until', 'kind'], switches: ['json'], count: 1 },
  unhold: { args: '<id>', flags: [], switches: ['json'], count: 1 },
};
const aliases = { view: 'show', create: 'add', edit: 'update', close: 'done' };
const commandHelp = 'Run the command with --help to see supported flags';
const unknownHelp = 'Run `--help` to see available commands';
const listHint = 'Run `tasks-axi show <id>` for full notes on a task';
const dayPattern = /^\d{4}-\d{2}-\d{2}$/;

class CliFailure extends Error {
  constructor(message, hints, code = 'VALIDATION_ERROR') {
    super(message);
    this.hints = hints;
    this.code = code;
  }
}

function reject(message, ...hints) {
  throw new CliFailure(message, hints);
}

function usage(command) {
  return `usage: tasks-axi ${command} ${commands[command].args}`;
}

function argumentsFor(command, args) {
  const { flags, switches, count } = commands[command];
  const options = Object.create(null);
  const positionals = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--') {
      positionals.push(...args.slice(i + 1));
      break;
    }
    if (!arg.startsWith('--')) {
      if (arg.startsWith('-') && arg !== '-') reject(`Unknown flag: ${arg}`, commandHelp);
      positionals.push(arg);
      continue;
    }
    const flag = arg.slice(2).split('=')[0];
    const inline = arg.length > flag.length + 2;
    if (switches.includes(flag) && !inline) {
      options[flag] = true;
    } else if (flags.includes(flag)) {
      const value = inline ? arg.slice(flag.length + 3) : args[++i];
      if (!value || value.startsWith('--') && !inline) {
        reject(`--${flag} requires a value`, `Pass --${flag}=... with a non-empty value`);
      }
      if (flag === 'blocked-by') (options[flag] ??= []).push(value);
      else options[flag] = value;
    } else {
      reject(`Unknown flag: --${flag}`, commandHelp);
    }
  }

  const expected = command === 'add' && options.mint ? 1 : count;
  if (positionals.length !== expected) {
    const label = expected === 0 ? 'no positional arguments' : `${expected} positional argument${expected === 1 ? '' : 's'}`;
    reject(`Expected ${label}, got ${positionals.length}`, usage(command));
  }
  return { positionals, options };
}

function lookup(tickets, id) {
  const ticket = tickets.get(id);
  if (!ticket || ticket.archived) {
    throw new CliFailure(`Task "${id}" not found in this backlog`, ['Run `tasks-axi list` to see existing tasks'], 'NOT_FOUND');
  }
  return ticket;
}

function checkBlocker(tickets, id, by) {
  if (id === by) reject('A task cannot block itself');
  if (!tickets.has(by) || tickets.get(by).archived) {
    reject(`blocker "${by}" not found`, 'Create the blocker task first, or choose an existing task id');
  }
}

function isCanonicalPriority(value) {
  return /^[0-4]$/.test(value);
}

function requestedBody(options) {
  if (options.body && options['body-file']) reject('Pass either --body or --body-file, not both');
  if (!options['body-file']) return options.body ?? null;
  const input = options['body-file'] === '-' ? 0 : options['body-file'];
  const text = fs.readFileSync(input, 'utf8');
  if (text === '') reject('--body requires a value', 'Pass --body=... with a non-empty value');
  return text;
}

function requestedReferences(options) {
  if (options.pr && !PR.test(options.pr)) {
    reject('Task pr link must be a canonical pull request URL: https://github.com/<owner>/<repo>/pull/<n> (GitHub) or https://<host>/<owner>/<repo>/pulls/<n> (Forgejo)');
  }
  return [options.pr, options.report].filter(Boolean);
}

function unique(values) {
  return Array.from(new Set(values));
}

function mintedId(title, prefix) {
  const slug = [prefix, title].filter(Boolean).join('-').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  return `${slug.slice(0, 48) || 'task'}-${randomBytes(2).toString('hex')}`;
}

function add(book, positionals, options, now, project) {
  const title = (options.mint ? positionals[0] : positionals[1]).trim();
  const id = options.mint ? mintedId(title, options.prefix) : positionals[0];
  if (!SLUG.test(id)) {
    reject(`Invalid id "${id}" - ids must be slug-shaped (letters, digits, "._-") with no spaces`,
      'Use a slug like `homemux-h7`, or pass --mint to generate one');
  }
  if (!title || /[\r\n]/.test(title)) reject('Title must be a non-empty single line');
  if (options.priority && !isCanonicalPriority(options.priority)) reject('--priority must be an integer from 0 to 4');
  const dependencies = unique(options['blocked-by'] ?? []);
  const existing = book.tickets.get(id);
  const already = Boolean(existing && !existing.archived);
  let ticket = existing;
  if (!already) {
    dependencies.forEach(by => checkBlocker(book.tickets, id, by));
    const references = requestedReferences(options);
    ticket = book.add({
      id, title, status: 'Queued',
      ...(options.kind ? { type: options.kind } : {}),
      ...(options.repo ? { project: options.repo } : {}),
      ...(options.priority ? { priority: `p${options.priority}` } : {}),
      assignee: [], labels: [], dependencies,
      ...(references.length > 0 ? { references } : {}),
      created_date: now,
    }, requestedBody(options));
  }

  const task = project(ticket);
  const kind = options.kind && options.kind !== 'task' ? options.kind : null;
  const attributes = [kind, options.repo ? `repo ${options.repo}` : null].filter(Boolean);
  const status = { queued: 'Queued', in_flight: 'In flight', done: 'Done' }[task.state];
  const message = already ? `add ${id} already exists -> ${status}`
    : `added ${id}${attributes.length ? ` (${attributes.join(', ')})` : ''} -> ${status}`;
  return mutation('add', task, options, {
    message, showTask: true, ...(already ? { already } : {}),
    hints: [`Run \`tasks-axi start ${id}\` to move it to in flight`, `Run \`tasks-axi block ${id} --by <other>\` to record a dependency`],
  });
}

function describeTasks(tasks, options) {
  const state = options.state;
  if (state && !states.includes(state)) reject(`--state must be one of ${states.join(', ')}`);
  const fields = unique(options.fields?.split(',').map(field => field.trim()).filter(Boolean) ?? []);
  const unknown = fields.filter(field => !EXTRA.includes(field));
  if (unknown.length) reject(`Unknown field(s): ${unknown.join(', ')}. Available: ${EXTRA.join(', ')}`);
  if (options.limit && !/^\d+$/.test(options.limit)) reject('--limit must be a non-negative integer');

  const matching = tasks.filter(task =>
    (!state || (state === 'held' ? task.held : state === task.state)) &&
    (!options.kind || options.kind === (task.kind ?? 'task')) &&
    (!options.repo || options.repo === task.repo) && (!options.blocked || task.blocked));
  const shown = options.limit === undefined ? matching : matching.slice(0, Number(options.limit));
  const detail = [options.blocked ? 'blocked' : null, state, options.kind ? `kind=${options.kind}` : null,
    options.repo ? `repo=${options.repo}` : null].filter(Boolean);
  if (!matching.length) {
    const filters = [options.repo ? `--repo=${options.repo}` : null, options.kind ? `--kind=${options.kind}` : null].filter(Boolean).join(' ');
    return [
      'count: 0',
      `tasks: 0 ${detail.length ? `${detail.join(' ')} ` : ''}tasks in this backlog`,
      ...(filters && !state ? help([`Run \`tasks-axi add <id> "<title>" ${filters}\` to add a task`,
        `Run \`tasks-axi list --state done ${filters}\` to see completed work`]) : []),
    ].join('\n');
  }
  return [
    `count: ${shown.length}${shown.length === matching.length ? '' : ` of ${matching.length} total`}`,
    ...table('tasks', shown, fields),
    ...help(state || options.kind || options.repo || options.blocked ? [listHint] : [listHint, 'Run `tasks-axi ready` to see unblocked queued work']),
  ].join('\n');
}

function ready(tasks, options) {
  const queued = tasks.filter(task => task.state === 'queued' && !task.blocked && (!options.repo || task.repo === options.repo));
  const dispatchable = queued.filter(task => !task.held);
  const held = queued.filter(task => task.held);
  return [
    `count: ${dispatchable.length}`,
    ...(dispatchable.length ? table('ready', dispatchable, []) : ['ready: 0 unblocked queued tasks']),
    'ready_public_followups: 0 delivery-ready obligations',
    ...(options['include-held'] && held.length ? table('held', held, HOLD) : []),
    ...help([dispatchable.length ? 'Run `tasks-axi start <id>` to dispatch one of these'
      : `Run \`tasks-axi list --state queued${options.repo ? ` --repo=${options.repo}` : ''}\` to see all queued work (incl. blocked)`]),
  ].join('\n');
}

function update(book, ticket, options, now, project) {
  const { fields } = ticket;
  const body = requestedBody(options);
  const references = requestedReferences(options);
  if (options.priority && !isCanonicalPriority(options.priority)) reject('--priority must be an integer from 0 to 4');
  if (options.title && /[\r\n]/.test(options.title)) reject('Title must be a non-empty single line');
  if (options['archive-body'] && body === null) reject('--archive-body needs --body or --body-file');
  if (![options.title, options.repo, options.kind, options.priority].some(Boolean) && body === null && !references.length) {
    reject('Nothing to update', 'Pass a field, e.g. --title, --body, --body-file, --repo, or --kind');
  }
  const changed = [];
  const patch = [['title', 'title', options.title], ['repo', 'project', options.repo], ['kind', 'type', options.kind],
    ['priority', 'priority', options.priority == null ? null : `p${options.priority}`]];
  for (const [key, field, value] of patch) {
    if (value != null && fields[field] !== value) {
      fields[field] = value;
      if (field === 'title') delete fields.references;
      changed.push(key);
    }
  }
  const oldBody = project(ticket).body;
  if (body !== null && oldBody !== body) {
    setSection(ticket, 'description', body);
    if (fields.status === 'Done') setSection(ticket, 'finalSummary', '');
    changed.push('body');
    if (options['archive-body'] && oldBody) {
      const history = sectionBody(ticket, 'notes');
      setSection(ticket, 'notes', [history, `### Previous description (${now.slice(0, 10)})\n\n${oldBody}`].filter(Boolean).join('\n\n'));
      changed.push('archive');
    }
  }
  const next = unique([...(fields.references ?? []), ...references]);
  if (next.length !== (fields.references ?? []).length) {
    fields.references = next;
    changed.push('links');
  }
  if (changed.length) {
    fields.updated_date = now;
    book.save(ticket);
  }
  return mutation('update', project(ticket), options, {
    message: changed.length ? `updated ${fields.id} (${changed.join(', ')})` : `updated ${fields.id} already`,
    ...(changed.length ? { changed } : { already: true, changed }),
    showTask: true, hints: [`Run \`tasks-axi show ${fields.id} --full\` to see the result`],
  });
}

function edge(action, book, ticket, options, now, project) {
  const { fields } = ticket;
  const by = options.by;
  if (!by) reject('--by <id> is required', 'Name the other task, e.g. `--by treehouse-lease-t4`');
  const remove = action === 'unblock';
  if (!remove) checkBlocker(book.tickets, fields.id, by);
  const dependencies = fields.dependencies ?? [];
  const already = dependencies.includes(by) !== remove;
  if (!already) {
    fields.dependencies = remove ? dependencies.filter(id => id !== by) : [...dependencies, by];
    fields.updated_date = now;
    book.save(ticket);
  }
  const hints = remove ? ['Run `tasks-axi ready` to see newly unblocked work']
    : [`Run \`tasks-axi unblock ${fields.id} --by <other>\` to clear it`, 'Run `tasks-axi ready` to see what is still dispatchable'];
  const result = remove ? (already ? 'already not blocked-by' : '-> cleared') : (already ? 'already blocked-by' : '-> blocked-by');
  return mutation(action, project(ticket), options, { message: `${action} ${fields.id} ${result} ${by}`, hints,
    ...(already ? { already } : {}), blocked_by: by });
}

function hold(action, book, ticket, options, now, project) {
  const existing = holdRecord(ticket.fields);
  let next = null;
  if (action === 'hold') {
    const reason = options.reason?.trim();
    if (!reason) reject('--reason <text> is required', 'Pass a reason, e.g. --reason "captain decision pending"');
    if (/[\r\n]/.test(reason)) reject('--reason must be a single line');
    if (/[()]/.test(reason)) reject('--reason must not contain parentheses', 'Parentheses are reserved for markdown hold tags');
    if (options.kind && !holdKinds.includes(options.kind)) reject(`--kind must be one of ${holdKinds.join(', ')}`);
    if (options.until && !dayPattern.test(options.until)) reject('--until must be YYYY-MM-DD');
    next = { reason, kind: options.kind ?? null, until: options.until ?? null };
  }
  const already = JSON.stringify(existing) === JSON.stringify(next);
  if (!already) {
    saveHold(ticket, next);
    ticket.fields.updated_date = now;
    book.save(ticket);
  }
  const id = ticket.fields.id;
  const detail = [next?.kind, next?.until ? `until ${next.until}` : null].filter(Boolean);
  const message = next
    ? `hold ${id} ${already ? 'already held' : '-> held'}${detail.length ? ` (${detail.join(', ')})` : ''}`
    : `unhold ${id} ${already ? 'already not held' : '-> cleared'}`;
  const hints = next ? [`Run \`tasks-axi unhold ${id}\` to resume dispatch`, 'Run `tasks-axi ready --include-held` to review paused work']
    : ['Run `tasks-axi ready` to see dispatchable work'];
  return mutation(action, project(ticket), options, { message, hints, showTask: true, ...(already ? { already } : {}) });
}

function done(book, ticket, options, now, project) {
  const { fields } = ticket;
  const already = fields.status === 'Done';
  if (options.keep && !/^\d+$/.test(options.keep)) reject('--keep must be a non-negative integer');
  const keep = options['no-prune'] ? Infinity : Number(options.keep ?? 10);
  const refs = unique([...(fields.references ?? []), ...requestedReferences(options)]);
  const summary = sectionBody(ticket, 'finalSummary');
  const appendNote = options.note && !(project(ticket).body ?? '').split('\n').includes(options.note);
  if (!already || refs.length !== (fields.references ?? []).length || appendNote) {
    if (!already) {
      fields.status = 'Done';
      fields.closed_date = now;
    }
    if (refs.length) fields.references = refs;
    if (appendNote) setSection(ticket, 'finalSummary', [summary, options.note].filter(Boolean).join('\n'));
    fields.updated_date = now;
    book.save(ticket);
  }

  const overflow = Array.from(book.tickets.values()).filter(item => !item.archived && item.fields.status === 'Done')
    .sort(taskOrder).slice(keep);
  overflow.forEach(item => book.archive(item));
  return mutation('done', { ...project(ticket), ...(already ? {} : { created: fields.created_date?.slice(0, 10) ?? null }) }, options, {
    message: `done ${fields.id} ${already ? 'already -> Done' : '-> Done'}${overflow.length ? `; pruned ${overflow.length}` : ''}`,
    hints: ['Run `tasks-axi ready` to dispatch work unblocked by this'],
    ...(already ? { already } : {}), pruned: overflow.length,
  });
}

function main(root, verb, args) {
  const command = Object.hasOwn(aliases, verb ?? '') ? aliases[verb] : verb;
  if (!command || command === '--help' || command === '-h') {
    return `usage: fm-tasks-axi.sh <command> [args]\ncommands: ${Object.keys(commands).join(', ')}, edit`;
  }
  if (!Object.hasOwn(commands, command)) reject(`Unknown command: ${verb}`, unknownHelp);
  if (args.includes('--help') || args.includes('-h')) {
    const { flags, switches } = commands[command];
    return [usage(command), 'flags:', ...flags.map(flag => `  --${flag} <value>`), ...switches.map(flag => `  --${flag}`)].join('\n');
  }

  const { positionals, options } = argumentsFor(command, args);
  const book = board(root);
  const now = new Date().toISOString();
  const project = ticket => projectTask(ticket, book.tickets, now);
  if (command === 'add') return add(book, positionals, options, now, project);
  if (command === 'list' || command === 'ready') {
    const tasks = Array.from(book.tickets.values()).filter(ticket => !ticket.archived).sort(taskOrder).map(project);
    return command === 'ready' ? ready(tasks, options) : describeTasks(tasks, options);
  }

  const ticket = lookup(book.tickets, positionals[0]);
  switch (command) {
    case 'show': return show(project(ticket), options.full, '--full').join('\n');
    case 'update': return update(book, ticket, options, now, project);
    case 'done': return done(book, ticket, options, now, project);
    case 'hold':
    case 'unhold': return hold(command, book, ticket, options, now, project);
    case 'block':
    case 'unblock': return edge(command, book, ticket, options, now, project);
    default: throw new Error(`Unhandled command: ${command}`);
  }
}

try {
  const [root, verb, ...args] = process.argv.slice(2);
  console.log(main(root, verb, args));
} catch (error) {
  if (error instanceof CliFailure) {
    console.log([`error: ${scalar(error.message)}`, `code: ${error.code}`, ...(error.hints.length ? help(error.hints, true) : [])].join('\n'));
    process.exitCode = error.code === 'NOT_FOUND' ? 1 : 2;
  } else {
    console.error(`fm-tasks-axi: ${error.message}`);
    process.exitCode = 2;
  }
}
