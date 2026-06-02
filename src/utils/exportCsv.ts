const BOM = '\uFEFF'

function escapeCsv(val: unknown): string {
  if (val === null || val === undefined) return ''
  const str = String(val)
  if (str.includes(',') || str.includes('"') || str.includes('\n') || str.includes('\r')) {
    return '"' + str.replace(/"/g, '""') + '"'
  }
  return str
}

export function downloadCSV(
  data: Record<string, unknown>[],
  filename: string,
  columns: { key: string; label: string }[],
) {
  const header = columns.map((c) => c.label).join(',')
  const rows = data.map((row) => columns.map((c) => escapeCsv(row[c.key])).join(','))
  const csv = BOM + header + '\n' + rows.join('\n')

  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename.endsWith('.csv') ? filename : `${filename}.csv`
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}
