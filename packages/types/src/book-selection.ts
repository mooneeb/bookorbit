import type { GroupRule, SortSpec } from "./query";

export type BookSelectionQuery = {
  libraryId?: number;
  filter?: GroupRule;
  q?: string;
  sort?: SortSpec[];
};

export type BookIdsSelection = { bookIds: number[]; query?: never };

export type BookSelectionPayload = BookIdsSelection | { query: BookSelectionQuery; bookIds?: never };
