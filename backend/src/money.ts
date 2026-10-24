/** Format integer cents as "$34,600.00". */
export function formatCents(cents: number): string {
  const sign = cents < 0 ? "-" : "";
  const abs = Math.abs(cents);
  const dollars = Math.floor(abs / 100).toLocaleString("en-US");
  const rem = String(abs % 100).padStart(2, "0");
  return `${sign}$${dollars}.${rem}`;
}

/** Short form for summaries: "$34,600" when whole dollars, else "$34,600.50". */
export function formatCentsShort(cents: number): string {
  return cents % 100 === 0 ? formatCents(cents).replace(/\.00$/, "") : formatCents(cents);
}
