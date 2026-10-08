const DECIMAL = '[0-9]+(?:\\.[0-9]+)?';
const SEGMENT = new RegExp(`^((?:/[0-9]+)+)(?::([0-9]+))?(?:~(${DECIMAL}))?(?:@(${DECIMAL}):(${DECIMAL}))?$`);

export function bookmarkLocationLabel(cfi: string | null): string | null {
  const body = cfi?.match(/epubcfi\(([^)]+)\)/i)?.[1];
  if (!body) return null;
  const step = body.match(/\/6\/(\d+)/)?.[1];
  if (step) {
    const value = Number(step);
    if (Number.isFinite(value) && value > 0) return `Loc ${Math.max(1, Math.round(value / 2))}`;
  }
  const compact = body.replace(/\s+/g, '');
  return compact ? `CFI ${compact.slice(0, 24)}${compact.length > 24 ? '...' : ''}` : null;
}

function withoutAssertions(body: string): string | null {
  let result = '';
  let assertion = false;
  let escaped = false;
  for (const character of body) {
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === '^') {
      if (!assertion) return null;
      escaped = true;
      continue;
    }
    if (character === '[' && !assertion) {
      assertion = true;
      continue;
    }
    if (character === ']' && assertion) {
      assertion = false;
      continue;
    }
    if (!assertion) result += character;
  }
  return assertion || escaped ? null : result.replace(/;s=[ab]/g, '');
}

function pointKey(point: string): string[] | null {
  const result: string[] = [];
  for (const segment of point.split('!')) {
    const match = segment.match(SEGMENT);
    if (!match) return null;
    result.push(...match[1].slice(1).split('/'), '-1', match[2] ?? '0', '-1', match[3] ?? '0', '-1', match[4] ?? '0', '-1', match[5] ?? '0', '-2');
  }
  return result;
}

export function bookmarkCfiKey(cfi: string): string[] | null {
  if (!cfi.startsWith('epubcfi(') || !cfi.endsWith(')') || cfi.length > 4000 || Array.from(cfi).length > 2000) return null;
  const body = withoutAssertions(cfi.slice(8, -1));
  if (body == null) return null;
  const parts = body.split(',');
  if (![1, 3].includes(parts.length)) return null;
  const start = pointKey(parts[0] + (parts[1] ?? ''));
  const end = pointKey(parts[0] + (parts[2] ?? ''));
  return start && end ? ['0', ...start, '-3', ...end] : null;
}

function compareDecimal(a: string, b: string): number {
  const negativeA = a.startsWith('-');
  const negativeB = b.startsWith('-');
  if (negativeA !== negativeB) return negativeA ? -1 : 1;
  const [integerA, fractionA = ''] = a.replace(/^-/, '').split('.');
  const [integerB, fractionB = ''] = b.replace(/^-/, '').split('.');
  const left = integerA.replace(/^0+(?=\d)/, '');
  const right = integerB.replace(/^0+(?=\d)/, '');
  const width = Math.max(fractionA.length, fractionB.length);
  const first = fractionA.padEnd(width, '0');
  const second = fractionB.padEnd(width, '0');
  const result = left.length - right.length || (left < right ? -1 : left > right ? 1 : first < second ? -1 : first > second ? 1 : 0);
  return negativeA ? -result : result;
}

export function compareBookmarkCfiKeys(a: string[], b: string[]): number {
  for (let index = 0; index < Math.min(a.length, b.length); index += 1) {
    const difference = compareDecimal(a[index], b[index]);
    if (difference) return difference;
  }
  return a.length - b.length;
}
