import { existsSync } from 'fs';
import { join } from 'path';

/**
 * Finds a migrations folder in the runtime image (`<app>/<bundledName>`, beside `dist/`) or in
 * the source tree (`src/<...sourcePath>`), whether run compiled or through tsx.
 */
export function resolveMigrationsFolder(bundledName: string, sourcePath: readonly string[]): string {
  const candidates = [
    join(__dirname, '..', '..', bundledName),
    join(__dirname, '..', ...sourcePath),
    join(process.cwd(), bundledName),
    join(process.cwd(), 'src', ...sourcePath),
  ];

  const match = candidates.find((path) => existsSync(path));
  if (!match) {
    throw new Error(`Unable to locate ${bundledName} folder. Checked: ${candidates.join(', ')}`);
  }
  return match;
}
