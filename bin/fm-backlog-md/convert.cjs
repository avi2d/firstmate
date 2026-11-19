const fs = require('node:fs');
const { board, draftTicket, saveHold, setSection } = require('./store.cjs');

const archiveHeading = /^## Archived \d{4}-\d{2}-\d{2}[ \t]*(?=\r?$)/gm;
const taskBullet = /^- (?:\[[ x]\] [A-Za-z0-9][A-Za-z0-9._-]*|\*\*[A-Za-z0-9][A-Za-z0-9._-]*\*\*) - /;

function readSource(file, archived, parseBacklog) {
  if (!fs.lstatSync(file, { throwIfNoEntry: false })?.isFile()) {
    throw new Error(`${file}: expected a regular source file, not a symlink`);
  }
  const source = fs.readFileSync(file, 'utf8');
  const markdown = archived ? source.replace(archiveHeading, '## Done') : source;
  try {
    const { sections, preamble } = parseBacklog(markdown);
    if (archived && preamble.some(line => taskBullet.test(line))) {
      throw new Error('archive has a task before the first Done section');
    }
    return sections.flatMap(section => section.entries.flatMap(entry => {
      if (entry.kind === 'task') {
        if (archived && entry.task.state !== 'done') {
          throw new Error(`archive contains an open task: ${entry.task.id}`);
        }
        return [{ task: entry.task, file, archived }];
      }
      if (archived && entry.lines.some(line => taskBullet.test(line))) {
        throw new Error(`archive has a task bullet that does not parse as Done under ${section.headerLine}`);
      }
      return [];
    }));
  } catch (error) {
    throw new Error(`${file}: ${error.message}`);
  }
}

function toDraft(task) {
  const { id, title, state, kind, repo, priority, deps, links, created, closed, body, hold } = task;
  const fields = {
    id, title,
    status: { queued: 'Queued', in_flight: 'In Flight', done: 'Done' }[state],
    ...(kind ? { type: kind } : {}),
    ...(repo ? { project: repo } : {}),
    ...(priority !== undefined ? { priority: `p${priority}` } : {}),
    assignee: [], labels: [],
    dependencies: deps.filter(dep => dep.type === 'blocked-by').map(dep => dep.id),
    ...(links.length ? { references: links.map(link => link.url) } : {}),
    ...(created ? { created_date: created } : {}),
    ...(closed ? { closed_date: closed } : {}),
  };
  const draft = draftTicket(fields, body ?? null);
  if (hold) saveHold(draft, hold);
  const relationNotes = deps.filter(dep => dep.type !== 'blocked-by' || dep.reason)
    .map(({ type, id, reason }) => `- ${type}: ${id}${reason ? ` - ${reason}` : ''}`);
  if (relationNotes.length) setSection(draft, 'notes', relationNotes.join('\n'));
  return draft;
}

function prepare(sources) {
  const counts = { open: 0, done: 0, dependencies: 0, waiting: 0 };
  const open = [];
  const done = [];
  const ids = new Map();
  for (const { task, file, archived } of sources) {
    const { id, state, deps, hold } = task;
    const key = id.toUpperCase();
    if (ids.has(key)) throw new Error(`${file}: duplicate ticket ID ${id} (also in ${ids.get(key)})`);
    ids.set(key, file);
    let draft;
    try {
      draft = toDraft(task);
    } catch (error) {
      throw new Error(`${file}: ${id}: ${error.message}`);
    }
    if (state === 'done') {
      counts.done++;
      done.push({ draft, archived });
    } else {
      counts.open++;
      if (hold) counts.waiting++;
      open.push({ draft, archived });
    }
    counts.dependencies += deps.length;
  }
  return { counts, tickets: [...open, ...done.reverse()] };
}

function writeTickets(destination, tickets) {
  const book = board(destination);
  if (book.tickets.size > 0) throw new Error(`${destination}: import requires an empty board, including its archive`);
  for (const { draft, archived } of tickets) {
    const ticket = book.add(draft);
    if (archived) book.archive(ticket);
  }
}

async function main([destination, backlog, archive]) {
  const { parseBacklog } = await import('tasks-axi/dist/src/backends/markdown-grammar.js');
  const active = readSource(backlog, false, parseBacklog);
  const history = archive === undefined ? [] : readSource(archive, true, parseBacklog);
  const { counts, tickets } = prepare(active.concat(history));
  if (destination) writeTickets(destination, tickets);

  console.log(destination ? 'imported:' : 'dry run (no files written):');
  for (const [name, count] of Object.entries(counts)) console.log(`  ${name}: ${count}`);
}

main(process.argv.slice(2)).catch(error => {
  console.error(`fm-backlog-md-convert: ${error.message}`);
  process.exitCode = 2;
});
