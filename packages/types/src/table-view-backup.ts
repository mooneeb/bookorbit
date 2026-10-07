import type { SavedView, TablePreset } from "./table-layout";

export type TableViewBackup = {
  version: 1;
  presets: TablePreset[];
  savedViews: SavedView[];
};
