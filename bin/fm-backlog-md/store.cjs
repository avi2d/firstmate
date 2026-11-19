const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const yaml = (() => {
  try {
    return require('yaml');
  } catch (error) {
    if (error.code !== 'MODULE_NOT_FOUND') throw error;
    console.error('fm-tasks-axi: install Backlog.md dependencies with npm ci --prefix bin/fm-backlog-md');
    process.exit(2);
  }
})();

const STATUSES = ['Queued', 'Waiting', 'In Flight', 'Done'];
const SLUG = /^[A-Za-z0-9._-]+$/;
const PR = /^https:\/\/(?:github\.com\/[^/\s]+\/[^/\s]+\/pull\/[1-9]\d*|[^/\s]+\/[^/\s]+\/[^/\s]+\/pulls\/[1-9]\d*|[^/\s]+\/(?:[^/\s]+\/)+-\/merge_requests\/[1-9]\d*)$/;
const WAITING = 'waiting-on:';
const sections = {
  description: ['Description', 'DESCRIPTION'],
  finalSummary: ['Final Summary', 'FINAL_SUMMARY'],
  notes: ['Implementation Notes', 'NOTES'],
};

function configError(file, message) {
  return new Error(`${file}: ${message}`);
}

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function stringList(value) {
  return Array.isArray(value) && value.every(item => typeof item === 'string');
}

function boardConfig(file) {
  if (!fs.lstatSync(file, { throwIfNoEntry: false })?.isFile()) {
    throw configError(file, 'initialize a local Backlog.md board first');
  }
  const config = yaml.parse(fs.readFileSync(file, 'utf8'));
  if (!object(config) || config.filesystem_only !== true ||
      !Array.isArray(config.statuses) || !STATUSES.every(status => config.statuses.includes(status))) {
    throw configError(file, 'configure filesystem-only storage and the Queued, Waiting, In Flight, and Done statuses');
  }
  const prefix = config.task_prefix ?? 'task';
  if (typeof prefix !== 'string' || !/^[A-Za-z]+$/.test(prefix)) {
    throw configError(file, 'task_prefix must be letters');
  }
  return prefix.toLowerCase();
}

function regularDirectory(dir, optional = false) {
  const stat = fs.lstatSync(dir, { throwIfNoEntry: false });
  if (!stat && optional) return false;
  if (!stat?.isDirectory()) throw configError(dir, 'expected a real directory, not a symlink');
  return true;
}

function readTicket(file, archived) {
  const content = fs.readFileSync(file, 'utf8');
  const parsed = /^---\r?\n([^]*?)\r?\n---\r?\n([^]*)$/.exec(content);
  if (!parsed) throw configError(file, 'missing YAML front matter');

  const fields = yaml.parse(parsed[1]);
  if (!object(fields) || typeof fields.id !== 'string' || !SLUG.test(fields.id) ||
      typeof fields.title !== 'string' || !STATUSES.includes(fields.status) ||
      ['labels', 'dependencies', 'references'].some(key => fields[key] != null && !stringList(fields[key])) ||
      ['type', 'project', 'priority', 'created_date', 'updated_date', 'closed_date', 'hold_until', 'hold_reason']
        .some(key => fields[key] != null && typeof fields[key] !== 'string') ||
      (fields.ordinal != null && !Number.isSafeInteger(fields.ordinal))) {
    throw configError(file, 'invalid ticket fields');
  }
  return { file, fields, markdown: parsed[2], archived };
}

function markers(section) {
  const [heading, key] = sections[section];
  return [heading, `<!-- SECTION:${key}:BEGIN -->`, `<!-- SECTION:${key}:END -->`];
}

function sectionPattern(begin, end) {
  return new RegExp(`^${begin}\\r?\\n(?:([^]*?)\\n)?${end}\\r?$`, 'm');
}

function sectionBody(ticket, section) {
  const [, begin, end] = markers(section);
  return ticket.markdown.match(sectionPattern(begin, end))?.[1] ?? '';
}

function setSection(ticket, section, body) {
  const [heading, begin, end] = markers(section);
  if (/^<!-- SECTION:[A-Z_]+:(?:BEGIN|END) -->\r?$/m.test(body)) {
    throw new Error('body cannot contain Backlog.md section delimiters on their own line');
  }
  const block = `${begin}\n${body}\n${end}`;
  const pattern = sectionPattern(begin, end);
  ticket.markdown = pattern.test(ticket.markdown)
    ? ticket.markdown.replace(pattern, () => block)
    : `${ticket.markdown.trimEnd()}\n\n## ${heading}\n\n${block}\n`;
}

function atomicWrite(file, content) {
  const temp = path.join(path.dirname(file), `.${randomUUID()}.tmp`);
  const fd = fs.openSync(temp, 'wx', 0o600);
  try {
    try {
      fs.writeFileSync(fd, content);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temp, file);
  } finally {
    fs.rmSync(temp, { force: true });
  }
}

function board(root) {
  const backlog = path.join(root, 'backlog');
  const active = path.join(backlog, 'tasks');
  const archive = path.join(backlog, 'archive');
  const archived = path.join(archive, 'tasks');
  regularDirectory(backlog);
  const prefix = boardConfig(path.join(backlog, 'config.yml'));
  regularDirectory(active);
  const directories = [active];
  if (regularDirectory(archive, true) && regularDirectory(archived, true)) directories.push(archived);

  const tickets = new Map();
  const boardIds = new Set();
  for (const directory of directories) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (!entry.name.startsWith(`${prefix}-`) || !entry.name.endsWith('.md')) continue;
      const file = path.join(directory, entry.name);
      if (!entry.isFile()) throw configError(file, 'expected a regular ticket file, not a symlink');
      const ticket = readTicket(file, directory === archived);
      const id = ticket.fields.id;
      if (boardIds.has(id.toUpperCase())) throw configError(file, `duplicate ticket ID: ${id}`);
      boardIds.add(id.toUpperCase());
      tickets.set(id, ticket);
    }
  }

  return {
    tickets,
    add(fields, description) {
      if (boardIds.has(fields.id.toUpperCase())) {
        throw new Error(`Backlog.md treats ticket IDs case-insensitively: ${fields.id} already exists`);
      }
      // Backlog.md lists by filename prefix even when the front matter uses another prefix.
      const file = path.join(active, `${prefix}-${fields.id.toLowerCase()} - ticket.md`);
      if (fs.existsSync(file)) throw configError(file, 'ticket filename already exists');
      const ordinal = Math.max(0, ...Array.from(tickets.values(), ticket => ticket.fields.ordinal ?? 0)) + 1000;
      const ticket = { file, fields: { ...fields, ordinal }, markdown: '', archived: false };
      if (description !== null) setSection(ticket, 'description', description);
      this.save(ticket);
      tickets.set(fields.id, ticket);
      return ticket;
    },
    save(ticket) {
      const fields = yaml.stringify(ticket.fields, { lineWidth: 0 });
      atomicWrite(ticket.file, `---\n${fields}---\n${ticket.markdown || '\n'}`);
    },
    archive(ticket) {
      if (!regularDirectory(archive, true)) fs.mkdirSync(archive);
      if (!regularDirectory(archived, true)) fs.mkdirSync(archived);
      const destination = path.join(archived, path.basename(ticket.file));
      if (fs.existsSync(destination)) throw configError(destination, 'archived ticket already exists');
      fs.renameSync(ticket.file, destination);
      ticket.file = destination;
      ticket.archived = true;
    },
  };
}

function taskState(fields) {
  const previous = fields.labels?.includes('firstmate-in-flight') ? 'in_flight' : 'queued';
  if (fields.status === 'Done') return 'done';
  if (fields.status === 'In Flight') return 'in_flight';
  return previous;
}

function holdRecord(fields) {
  const label = fields.labels?.find(value => value.startsWith(WAITING));
  if (!label && fields.hold_reason == null && fields.hold_until == null && fields.status !== 'Waiting') return null;
  const kind = label?.slice(WAITING.length);
  return { reason: fields.hold_reason ?? '', kind: !kind || kind === 'unspecified' ? null : kind, until: fields.hold_until ?? null };
}

function saveHold(ticket, hold) {
  const { fields } = ticket;
  const state = taskState(fields);
  fields.labels = (fields.labels ?? []).filter(label => !label.startsWith(WAITING) && label !== 'firstmate-in-flight');
  delete fields.hold_reason;
  delete fields.hold_until;
  if (state !== 'done') fields.status = state === 'in_flight' ? 'In Flight' : 'Queued';
  if (hold) {
    fields.labels.push(`${WAITING}${hold.kind ?? 'unspecified'}`);
    fields.hold_reason = hold.reason;
    if (hold.until) fields.hold_until = hold.until;
    if (state !== 'done') {
      fields.status = 'Waiting';
      if (state === 'in_flight') fields.labels.push('firstmate-in-flight');
    }
  }
}

function projectTask(ticket, tickets, now) {
  const { fields } = ticket;
  const state = taskState(fields);
  const hold = holdRecord(fields);
  const refs = fields.references ?? [];
  const links = refs.filter(ref => PR.test(ref)).map(url => ({ kind: 'pr', url }))
    .concat(refs.filter(ref => !PR.test(ref)).map(url => ({ kind: 'report', url })));
  const blocked_by = (fields.dependencies ?? []).filter(id => taskState(tickets.get(id)?.fields ?? {}) !== 'done');
  const body = ['description', 'finalSummary'].map(section => sectionBody(ticket, section)).filter(Boolean).join('\n');
  return {
    id: fields.id,
    title: [fields.title, ...refs].join(' '),
    state,
    kind: fields.type ?? null,
    repo: fields.project ?? null,
    priority: /^p[0-4]$/.test(fields.priority ?? '') ? Number(fields.priority[1]) : null,
    created: state === 'done' ? null : fields.created_date?.slice(0, 10) || null,
    closed: state === 'done' ? (fields.closed_date || fields.updated_date)?.slice(0, 10) || null : null,
    deps: (fields.dependencies ?? []).map(id => ({ type: 'blocked-by', id })),
    hold,
    links,
    body: body || null,
    blocked: blocked_by.length > 0,
    blocked_by,
    held: state !== 'done' && hold !== null && (!hold.until || hold.until > now.slice(0, 10)),
  };
}

function taskOrder(left, right) {
  const rank = { in_flight: 0, queued: 1, done: 2 };
  const order = rank[taskState(left.fields)] - rank[taskState(right.fields)];
  if (order !== 0) return order;
  if (left.fields.status === 'Done') {
    const close = ticket => ticket.fields.closed_date ?? ticket.fields.updated_date ?? '';
    return close(right).localeCompare(close(left)) || (right.fields.ordinal ?? 0) - (left.fields.ordinal ?? 0);
  }
  return (left.fields.ordinal ?? 0) - (right.fields.ordinal ?? 0) || left.fields.id.localeCompare(right.fields.id);
}

module.exports = { board, PR, SLUG, projectTask, holdRecord, saveHold, taskOrder, sectionBody, setSection };
