import { sql, type SQL, type SQLWrapper } from 'drizzle-orm';

const NUMBER = '[0-9]+(?:\\.[0-9]+)?';
const SEGMENT = `(?:/[0-9]+)+(?::[0-9]+)?(?:~${NUMBER})?(?:@${NUMBER}:${NUMBER})?`;
const POINT = `${SEGMENT}(?:!${SEGMENT})*`;
const POINT_BODY = `^${POINT}$`;

function pointOrder(point: SQL): SQL {
  const terminal = sql.raw(`$cfi$((?:/[0-9]+)+)(?::([0-9]+))?(?:~(${NUMBER}))?(?:@(${NUMBER}):(${NUMBER}))?(!|$)$cfi$`);
  const replacement = sql.raw(String.raw`$cfi$\1:-1:\2:-1:\3:-1:\4:-1:\5:-2\6$cfi$`);
  const encoded = sql`regexp_replace(${point}, ${terminal}, ${replacement}, 'g')`;
  const defaults = sql`replace(replace(replace(${encoded}, ':-1::-1', ':-1:0:-1'), ':-1::-1', ':-1:0:-1'), ':-1::-2', ':-1:0:-2')`;
  return sql`string_to_array(trim(both ':' from regexp_replace(${defaults}, '[/!]+', ':', 'g')), ':')::numeric[]`;
}

// Assertions and side bias identify a destination but do not change its reading order.
// Negative separators keep path prefixes, indirections and offsets distinct. Ranges
// compare their collapsed start, then their end, instead of digits inside assertions.
export function epubBookmarkCfiOrder(cfi: SQLWrapper): SQL {
  const assertions = sql.raw(String.raw`$cfi$\[(\^.|[^\]^])*\]$cfi$`);
  const body = sql`regexp_replace(regexp_replace(substring(${cfi} from 9 for greatest(0, length(${cfi}) - 9)), ${assertions}, '', 'g'), ';s=[ab]', '', 'g')`;
  const parent = sql`split_part(${body}, ',', 1)`;
  const start = sql`(${parent} || split_part(${body}, ',', 2))`;
  const end = sql`(${parent} || split_part(${body}, ',', 3))`;
  const wrapper = sql.raw(String.raw`$cfi$^epubcfi\(.*\)$$cfi$`);
  const validPoint = sql.raw(`$cfi$${POINT_BODY}$cfi$`);
  return sql`case when ${cfi} ~ ${wrapper} and array_length(string_to_array(${body}, ','), 1) in (1, 3)
    and ${start} ~ ${validPoint} and ${end} ~ ${validPoint}
    then array[0]::numeric[] || ${pointOrder(start)} || array[-3]::numeric[] || ${pointOrder(end)}
    else array[1]::numeric[] end`;
}
