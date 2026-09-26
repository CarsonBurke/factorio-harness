/** Human/agent display only; JSON remains the machine-readable protocol. */
function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function atom(value: unknown): string {
  if (typeof value === 'string' && /^[A-Za-z_][A-Za-z0-9_./:-]*$/.test(value)
      && !['true','false','null'].includes(value)) return value;
  return JSON.stringify(value) ?? 'undefined';
}
function keyLabel(key: string): string {
  return /^[A-Za-z_][A-Za-z0-9_-]*$/.test(key) ? key : JSON.stringify(key);
}
function flatten(value: Record<string, unknown>, prefix = ''): Record<string, unknown> {
  const cells: Record<string, unknown> = Object.create(null);
  for (const [key, entry] of Object.entries(value)) {
    const path = prefix ? `${prefix}.${keyLabel(key)}` : keyLabel(key);
    if (record(entry) && Object.keys(entry).length) Object.assign(cells, flatten(entry, path));
    else cells[path] = entry;
  }
  return cells;
}
export function formatCompact(value: unknown): string {
  const lines: string[] = [];
  function render(entry: unknown, label: string, depth: number) {
    const indent = '  '.repeat(depth);
    if (Array.isArray(entry) && entry.length > 1 && entry.every(record)) {
      const rows = entry.map(row => flatten(row));
      const columns = [...new Set(rows.flatMap(row => Object.keys(row)))];
      // Very heterogeneous records are clearer as individually labelled objects.
      if (columns.length && columns.length <= 24 && rows.every(row => Object.keys(row).length >= columns.length / 2)) {
        lines.push(`${indent}${label}[${rows.length}]: ${columns.join(' | ')}`);
        for (const row of rows) lines.push(`${indent}  ${columns.map(key => Object.hasOwn(row, key) ? atom(row[key]) : '<absent>').join(' | ')}`);
        return;
      }
    }
    if (record(entry) && Object.keys(entry).length) {
      if (label) lines.push(`${indent}${label}:`);
      for (const [key, child] of Object.entries(entry)) render(child, keyLabel(key), depth + (label ? 1 : 0));
    } else if (Array.isArray(entry) && entry.length && entry.some(item => typeof item === 'object' && item !== null)) {
      lines.push(`${indent}${label}[${entry.length}]:`);
      entry.forEach((child, index) => render(child, String(index), depth + 1));
    } else lines.push(`${indent}${label ? `${label}: ` : ''}${atom(entry)}`);
  }
  render(value, '', 0);
  return lines.join('\n') + '\n';
}
