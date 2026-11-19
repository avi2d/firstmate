const fs = require('node:fs');
const path = require('node:path');
const yaml = require('yaml');

const names = ['captain.md', 'captain-shared.md', 'learnings.md', 'projects.md'];
const slug = /^[a-z0-9][a-z0-9-]*$/;

function records(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = entries.filter(e => e.name.endsWith('.md'));
  if (!files.length) throw Error('no decision records found');
  return files.map(entry => {
    if (!entry.isFile()) throw Error(`not a regular file: ${entry.name}`);
    const file = path.join(dir, entry.name);
    const text = fs.readFileSync(file, 'utf8');
    const match = /^---\r?\n([^]*?)\r?\n---\r?\n([^]*)$/.exec(text);
    if (!match) throw Error(`invalid front matter: ${file}`);
    const fields = yaml.parse(match[1]);
    if (!fields || typeof fields !== 'object' || Array.isArray(fields) ||
        !/^decision-[1-9][0-9]*$/.test(fields.id || '') || !slug.test(fields.title || '') || !slug.test(fields.topic || '') ||
        !['active', 'superseded'].includes(fields.status) ||
        typeof fields.date !== 'string' || typeof fields.scope !== 'string' ||
        typeof fields.provenance !== 'string' || !match[2].trim() ||
        (fields.status === 'active' && (typeof fields.summary !== 'string' || !fields.summary.trim() || fields.summary.length > 120 || /[\r\n]/.test(fields.summary))) ||
        !Array.isArray(fields.supersedes) ||
        fields.supersedes.some(id => typeof id !== 'string' || !slug.test(id)) ||
        !(fields.superseded_by === null || (typeof fields.superseded_by === 'string' && slug.test(fields.superseded_by)))) {
      throw Error(`invalid decision: ${file}`);
    }
    return { file, fields, body: match[2] };
  });
}

function validate(list) {
  const errors = [];
  const byId = new Map();
  const active = new Map();
  for (const r of list) {
    const d = r.fields;
    if (byId.has(d.id)) errors.push(`duplicate id: ${d.id}`);
    byId.set(d.id, d);
    if (d.status === 'active') {
      if (d.superseded_by !== null) errors.push(`${d.id}: active record has a successor`);
      const ids = active.get(d.topic) || [];
      ids.push(d.id);
      active.set(d.topic, ids);
    } else if (!d.superseded_by) errors.push(`${d.id}: superseded record has no successor`);
  }
  for (const [topic, ids] of active) {
    if (ids.length > 1) errors.push(`multiple active records for ${topic}: ${ids.join(', ')}`);
  }
  for (const { fields: d } of list) {
    if (d.superseded_by) {
      const next = byId.get(d.superseded_by);
      if (!next || next.topic !== d.topic || !next.supersedes.includes(d.id)) errors.push(`${d.id}: invalid successor link`);
    }
    for (const id of d.supersedes) {
      const prev = byId.get(id);
      if (!prev || prev.topic !== d.topic || prev.superseded_by !== d.id) errors.push(`${d.id}: invalid predecessor link ${id}`);
    }
    const visited = new Set([d.id]);
    let next = d;
    while (next?.superseded_by) {
      if (visited.has(next.superseded_by)) {
        errors.push(`${d.id}: successor cycle`);
        break;
      }
      visited.add(next.superseded_by);
      next = byId.get(next.superseded_by);
    }
  }
  if (errors.length) throw Error(errors.join('\n'));
}

function writeRecord(dir, fields, body) {
  fs.writeFileSync(path.join(dir, `${fields.id} - ${fields.title}.md`), `---\n${yaml.stringify(fields)}---\n${body}\n`, { flag: 'wx', mode: 0o600 });
}

function convert(source, dir, mapFile, summaryFile) {
  const mappings = JSON.parse(fs.readFileSync(mapFile, 'utf8'));
  const summaries = JSON.parse(fs.readFileSync(summaryFile, 'utf8'));
  if (!summaries || Array.isArray(summaries) || typeof summaries !== 'object') throw Error('invalid summaries');
  if (!mappings || Array.isArray(mappings) || typeof mappings !== 'object' ||
      Object.values(mappings).some(value => typeof value !== 'string' || !slug.test(value))) throw Error('invalid topic map');
  const prepared = [];
  for (const name of names) {
    const lines = fs.readFileSync(path.join(source, name), 'utf8').split(/\r?\n/);
    lines.forEach((line, index) => {
      if (!line.trim() || /^\s*#/.test(line) || /^\s*<!--/.test(line)) return;
      const sourceId = `${name.replace('.md', '')}-${index + 1}`;
      const id = `decision-${prepared.length + 1}`;
      const topic = mappings[sourceId] || sourceId;
      if (!slug.test(topic)) throw Error(`invalid topic for ${sourceId}`);
      const date = line.match(/\b\d{4}-\d{2}-\d{2}\b/)?.[0] || 'unknown';
      const scope = name === 'projects.md' ? line.match(/^- ([a-z0-9][a-z0-9-]*) \[/)?.[1] || 'global' : 'global';
      const summary = summaries[sourceId];
      if (typeof summary !== 'string' || !summary.trim() || summary.length > 120 || /[\r\n]/.test(summary)) throw Error(`invalid summary for ${sourceId}`);
      const fields = { id, title: sourceId, topic, summary, status: 'active', date, scope, provenance: 'unknown', supersedes: [], superseded_by: null, source: `${name}:${index + 1}` };
      prepared.push({ fields, body: line });
    });
  }
  const ids = new Set(prepared.map(r => r.fields.title));
  for (const id of Object.keys(mappings)) if (!ids.has(id)) throw Error(`topic map refers to missing entry: ${id}`);
  for (const id of Object.keys(summaries)) if (!ids.has(id)) throw Error(`summary refers to missing entry: ${id}`);
  if (!prepared.length) throw Error('no entries found');
  fs.mkdirSync(dir, { recursive: false, mode: 0o700 });
  for (const r of prepared) writeRecord(dir, r.fields, r.body);
  const unknown = prepared.filter(r => r.fields.date === 'unknown').length;
  console.log(`converted ${prepared.length} records; unknown date: ${unknown}`);
  for (const r of prepared.filter(r => r.fields.date === 'unknown')) console.log(`unknown date: ${r.fields.id}`);
}

function usage() {
  throw Error('usage: decisions.cjs convert SOURCE_DIR NEW_DECISIONS_DIR TOPIC_MAP.json SUMMARIES.json | check DECISIONS_DIR | activate DECISIONS_DIR | render DECISIONS_DIR [SCOPE] | render-full DECISIONS_DIR [SCOPE]');
}

try {
  const [command, ...args] = process.argv.slice(2);
  if (command === 'convert' && args.length === 4) convert(...args);
  else if (command === 'check' && args.length === 1) {
    const list = records(args[0]);
    validate(list);
    console.log(`ok: ${list.length} records`);
  } else if (command === 'activate' && args.length === 1) {
    validate(records(args[0]));
    fs.writeFileSync(path.join(args[0], '.fm-memory'), '', { flag: 'wx', mode: 0o600 });
    console.log('decision memory activated');
  } else if (['render', 'render-full'].includes(command) && (args.length === 1 || args.length === 2)) {
    const list = records(args[0]);
    validate(list);
    for (const r of list.filter(r => r.fields.status === 'active' && (r.fields.scope === 'global' || r.fields.scope === args[1])).sort((a, b) => a.fields.topic.localeCompare(b.fields.topic))) {
      const content = command === 'render' ? r.fields.summary : r.body.trim().replace(/\s+/g, ' ');
      console.log(`- [${r.fields.topic}] ${content}`);
    }
  } else usage();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
