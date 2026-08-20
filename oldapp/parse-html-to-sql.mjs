import { readFileSync, mkdirSync, writeFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(__dirname, 'import-sql');
mkdirSync(OUT_DIR, { recursive: true });

function esc(val) {
  if (val === null || val === undefined || val === 'null') return 'NULL';
  const s = String(val).replace(/'/g, "''");
  return `'${s}'`;
}

function escNum(val) {
  if (val === null || val === undefined || val === '' || val === 'null') return 'NULL';
  const n = String(val).replace(',', '.').trim();
  return n;
}

function escInt(val) {
  if (val === null || val === undefined || val === '' || val === 'null') return 'NULL';
  const n = parseInt(val, 10);
  return isNaN(n) ? 'NULL' : String(n);
}

function escTS(val) {
  if (!val || val === 'null' || val === '') return 'NULL';
  return esc(val);
}

// ─── Parse clients.html ───────────────────────────────────────────────
const clientsHtml = readFileSync(join(__dirname, 'clients.html'), 'utf-8');

// Extract all detail({...}) JSON objects from onclick attributes by counting braces
function extractJSONObjects(text) {
  const results = [];
  const searchStr = 'detail(';
  let idx = 0;
  while ((idx = text.indexOf(searchStr, idx)) !== -1) {
    const start = idx + searchStr.length;
    // skip whitespace
    let pos = start;
    while (pos < text.length && (text[pos] === ' ' || text[pos] === '\t' || text[pos] === '\n' || text[pos] === '\r')) pos++;
    if (text[pos] !== '{') { idx = pos; continue; }
    let depth = 0;
    let inString = false;
    let stringChar = null;
    let escape = false;
    let end = pos;
    for (let i = pos; i < text.length; i++) {
      const ch = text[i];
      if (escape) { escape = false; continue; }
      if (inString) {
        if (ch === '\\') { escape = true; continue; }
        if (ch === stringChar) inString = false;
        continue;
      }
      if (ch === '"' || ch === "'") { inString = true; stringChar = ch; continue; }
      if (ch === '{') depth++;
      if (ch === '}') depth--;
      if (depth === 0) { end = i; break; }
    }
    const raw = text.slice(pos, end + 1);
    try {
      results.push(JSON.parse(raw));
    } catch (e) {
      // skip malformed
    }
    idx = end + 1;
  }
  return results;
}

const clientObjects = extractJSONObjects(clientsHtml);
const clientRows = [];
const rechargeRows = [];
const seenRechargeIds = new Set();

for (const obj of clientObjects) {
  try {
    
    // Extract client
    clientRows.push({
      id: escInt(obj.id),
      name: esc(obj.name || ''),
      phone: esc(obj.phone || ''),
      documentID: esc(obj.documentID || ''),
      email: esc(obj.email || ''),
      creditLimit: esc(obj.creditLimit || ''),
      status: esc(obj.status ?? '0'),
      createAt: escTS(obj.createAt),
      createBy: esc(obj.createBy || ''),
      carrer: esc(obj.carrer || ''),
      balance: escNum(obj.balance),
      uid: esc(obj.uid || ''),
    });

    // Extract nested recharges
    if (Array.isArray(obj.recharge)) {
      for (const r of obj.recharge) {
        if (!r.id || seenRechargeIds.has(r.id)) continue;
        seenRechargeIds.add(r.id);
        rechargeRows.push({
          id: escInt(r.id),
          idclient: escInt(r.idclient || obj.id),
          method: esc(r.method || ''),
          ref: esc(r.ref || ''),
          picture: esc(r.picture || ''),
          amount: escNum(r.amount),
          tasa: escNum(r.tasa),
          date: r.date ? esc(r.date) : 'NULL',
          status: escInt(r.status),
          createBy: r.createBy === null || r.createBy === undefined || r.createBy === '' ? 'NULL' : escInt(r.createBy),
          createAt: escTS(r.createAt),
          updateAprobate: r.updateAprobate === null || r.updateAprobate === undefined || r.updateAprobate === '' || r.updateAprobate === 'null' ? 'NULL' : escTS(r.updateAprobate),
        });
      }
    }
  } catch (e) {
    console.warn('Skipping malformed JSON block');
  }
}

// Generate clients SQL
let sql = `-- GENERATED: clients import
-- Source: oldapp/clients.html
-- Rows: ${clientRows.length}

TRUNCATE TABLE public.clients RESTART IDENTITY CASCADE;

INSERT INTO public.clients (id, name, phone, "documentID", email, "creditLimit", status, "createAt", "createBy", carrer, balance, uid) VALUES
`;
const clientCols = ['id', 'name', 'phone', 'documentID', 'email', 'creditLimit', 'status', 'createAt', 'createBy', 'carrer', 'balance', 'uid'];
const clientPartials = clientRows.map(r => {
  const vals = clientCols.map(c => r[c] !== undefined ? r[c] : 'NULL');
  return `(${vals.join(', ')})`;
});
sql += clientPartials.join(',\n') + ';\n\n';

// Generate recharge SQL (only if recharges exist)
if (rechargeRows.length > 0) {
  sql += `-- GENERATED: recharge import
-- Rows: ${rechargeRows.length}

TRUNCATE TABLE public.recharge RESTART IDENTITY CASCADE;

INSERT INTO public.recharge (id, idclient, method, ref, picture, amount, tasa, date, status, "createBy", "createAt", "updateAprobate") VALUES
`;
  const rCols = ['id', 'idclient', 'method', 'ref', 'picture', 'amount', 'tasa', 'date', 'status', 'createBy', 'createAt', 'updateAprobate'];
  const rPartials = rechargeRows.map(r => {
    const vals = rCols.map(c => r[c] !== undefined ? r[c] : 'NULL');
    return `(${vals.join(', ')})`;
  });
  sql += rPartials.join(',\n') + ';\n\n';
}

writeFileSync(join(OUT_DIR, '01_import_clients.sql'), sql, 'utf-8');
console.log(`✓ clients: ${clientRows.length} rows, recharge: ${rechargeRows.length} rows`);

// ─── Parse transactions.html ──────────────────────────────────────────
const txHtml = readFileSync(join(__dirname, 'transactions.html'), 'utf-8');

// Helper: extract text content from a td (strip inner HTML)
function tdText(tdHtml) {
  return tdHtml.replace(/<[^>]*>/g, '').trim();
}

// Match table rows in tbody — capture all td inner HTML
const trRegex = /<tr>[\s\S]*?<td>(\d+)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td[^>]*>([\s\S]*?)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td[^>]*>([\s\S]*?)<\/td>[\s\S]*?<\/tr>/gi;

const txRows = [];
let txMatch;
while ((txMatch = trRegex.exec(txHtml)) !== null) {
  const id = txMatch[1]?.trim();
  const createdAt = txMatch[2]?.trim();
  const shedule = txMatch[3]?.trim();
  const clientName = tdText(txMatch[4] || '');
  const unitName = txMatch[5]?.trim();
  const amount = txMatch[6]?.trim();
  const newBalance = txMatch[7]?.trim();
  const statusHtmlRaw = tdText(txMatch[8] || '');

  const status = statusHtmlRaw?.includes('APROBADA') ? 1 : statusHtmlRaw?.includes('RECHAZADO') ? 2 : 0;

  txRows.push({ id: escInt(id), created_at: escTS(createdAt), shedule: esc(shedule), amount: escNum(amount), new_balance: escNum(newBalance), status: escInt(status) });
}

let txSql = `-- GENERATED: transactions import (from oldapp/transactions.html)
-- Note: client_name and unit_name are NOT stored; they require FK resolution.
-- This script inserts raw data. You must map client_name → idclient and unit_name → idunit manually,
-- OR run the companion script that resolves names to IDs.
-- Rows: ${txRows.length}

-- TRUNCATE TABLE public.transactions RESTART IDENTITY CASCADE;

-- INSERT INTO public.transactions (id, created_at, shedule, amount, "newBalanceClient", status) VALUES
`;

const txPartials = txRows.map(r => `(${r.id}, ${r.created_at}, ${r.shedule}, ${r.amount}, ${r.new_balance}, ${r.status})`);
txSql += txPartials.join(',\n') + ';\n';

writeFileSync(join(OUT_DIR, '02_import_transactions.sql'), txSql, 'utf-8');
console.log(`✓ transactions: ${txRows.length} rows`);

// ─── Generate a second pass script that resolves names → IDs ──────────
// First we need the unit name mapping from transactions.html
const unitSelectRegex = /<option\s+value="(\d+)">([^<]+)<\/option>/g;
const unitMap = {};
let um;
while ((um = unitSelectRegex.exec(txHtml)) !== null) {
  const id = um[1]?.trim();
  const name = um[2]?.trim();
  if (id && name) unitMap[name] = id;
}

// And client name mapping
const clientSelectRegex = /<option\s+value="(\d+)">([^<]+)<\/option>/g;
const clientNameMap = {};
let cm;
while ((cm = clientSelectRegex.exec(txHtml)) !== null) {
  const id = cm[1]?.trim();
  const name = cm[2]?.trim();
  if (id && name) clientNameMap[name] = id;
}

const resolvedTxRows = [];
const trRegex2 = /<tr>[\s\S]*?<td>(\d+)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td[^>]*>([\s\S]*?)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td>([^<]*)<\/td>[\s\S]*?<td[^>]*>([\s\S]*?)<\/td>[\s\S]*?<\/tr>/gi;
let txMatch2;
while ((txMatch2 = trRegex2.exec(txHtml)) !== null) {
  const id = txMatch2[1]?.trim();
  const createdAt = txMatch2[2]?.trim();
  const shedule = txMatch2[3]?.trim();
  const clientName = tdText(txMatch2[4] || '');
  const unitName = txMatch2[5]?.trim();
  const amount = txMatch2[6]?.trim();
  const newBalance = txMatch2[7]?.trim();
  const statusHtmlRaw = tdText(txMatch2[8] || '');
  const status = statusHtmlRaw?.includes('APROBADA') ? 1 : statusHtmlRaw?.includes('RECHAZADO') ? 2 : 0;

  const idclient = clientNameMap[clientName] || 'NULL';
  const idunit = unitMap[unitName] || 'NULL';

  resolvedTxRows.push({
    id: escInt(id),
    idclient: escInt(idclient),
    idunit: escInt(idunit),
    uid: 'NULL',
    createBy: 'NULL',
    amount: escNum(amount),
    newBalanceClient: escNum(newBalance),
    shedule: esc(shedule),
    status: escInt(status),
    created_at: escTS(createdAt),
  });
}

let resolvedSql = `-- GENERATED: transactions import with name→ID resolution
-- Rows: ${resolvedTxRows.length}
-- Resolved client_name → idclient and unit_name → idunit

TRUNCATE TABLE public.transactions RESTART IDENTITY CASCADE;

INSERT INTO public.transactions (id, uid, idclient, "createBy", amount, status, created_at, idunit, shedule, "newBalanceClient") VALUES
`;
const txCols = ['id', 'uid', 'idclient', 'createBy', 'amount', 'status', 'created_at', 'idunit', 'shedule', 'newBalanceClient'];
const txPartials2 = resolvedTxRows.map(r => {
  const vals = txCols.map(c => r[c] !== undefined ? r[c] : 'NULL');
  return `(${vals.join(', ')})`;
});
resolvedSql += txPartials2.join(',\n') + ';\n';

writeFileSync(join(OUT_DIR, '03_import_transactions_resolved.sql'), resolvedSql, 'utf-8');
console.log(`✓ transactions resolved: ${resolvedTxRows.length} rows`);

console.log('\nDone. Files written to:', OUT_DIR);
